import Foundation

/// Measures text with the platform's text engine (CoreText on Apple platforms).
public protocol TextMeasurer {
    /// Width and height of `runs` set in `font`, wrapped at `maxWidth` (nil: no wrapping, one line per `\n`).
    func measure(_ runs: [TextLogic.Run], font: FontSpec, maxWidth: Double?) -> (width: Double, height: Double)
}

/// Everything a screen renders from that does not change while it is shown.
public struct ScreenContext {
    public var componentsConfig: JSONValue
    public var localizations: [String: [String: String]]
    public var defaultLocale: String
    public var locale: String
    public var dark: Bool
    public var variablesPerPackage: [String: [String: String]] = [:]
    /// Global and `custom.*` variables, under every package's own.
    public var baseVariables: [String: String] = [:]
    public var infoPerPackage: [String: PackageInfo] = [:]
    /// App stores require a Restore button on mobile; shown when the host handles restore.
    public var showRestoreButton = true
    public var hideBackButtons = false
    public var enforceRequiredInputs = true
    /// The user's text size setting (Dynamic Type / font scale) as a multiplier on every font size; 1 = as designed.
    public var fontScale = 1.0
    public var measurer: TextMeasurer

    var colors: [String: String] { (componentsConfig.obj("colors")?.objectValue ?? [:]).compactMapValues(\.stringValue) }
    var fonts: [String: JSONValue] { componentsConfig.obj("fonts")?.objectValue ?? [:] }

    /// `getLocalizedString`: the selected locale, else the default; a present empty string stays empty.
    func localized(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return "" }
        return localizations[locale]?[id] ?? localizations[defaultLocale]?[id]
    }
}

/// What changes while a screen is shown: the visitor's choices. Owned by ``ScreenController``.
public struct ScreenState {
    public var selectedPackageId: String?
    /// Tabs node key -> selected tab index.
    public var tabs: [String: Int] = [:]
    /// Carousel node key -> current page.
    public var carouselPages: [String: Int] = [:]
    /// Choice question field id -> chosen option ids, in tap order.
    public var choices: [String: [String]] = [:]
    /// Text question field id -> current text.
    public var texts: [String: String] = [:]
    /// Text fields whose value is invalid for their keyboard type (shown after leaving the field).
    public var textErrors: Set<String> = []
    public var focusedField: String?
    /// The open sheet (`navigate_to` -> `sheet`), with the package selected when it opened.
    public var sheet: JSONValue?
    public var sheetRootPackageId: String?
    public var nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
}

/// Turns a screen's JSON and state into a ``RenderNode`` tree, the way the web components do.
final class Resolver {
    private let ctx: ScreenContext
    private let state: ScreenState
    private let colors: [String: String]
    /// Field id -> satisfied, for required questions on screen (filled while resolving).
    private(set) var fieldSatisfaction: [String: Bool] = [:]
    private var inputsSatisfied = true

    private struct Scope {
        var variables: [String: String]
        var packageInfo: PackageInfo?
        var selected = false
        var choice: Choice?
        var tabs: Tabs?
    }

    private struct Choice {
        let fieldId: String
        let multiple: Bool
        let atMax: Bool
    }

    private struct Tabs {
        let key: String
        let control: JSONValue?
        let selectedIndex: Int
        let tabIds: [String?]
    }

    init(_ ctx: ScreenContext, _ state: ScreenState) {
        self.ctx = ctx
        self.state = state
        self.colors = ctx.colors
    }

    private func rootScope() -> Scope {
        let pkg = state.selectedPackageId ?? ""
        return Scope(variables: ctx.baseVariables.merging(ctx.variablesPerPackage[pkg] ?? [:]) { $1 }, packageInfo: ctx.infoPerPackage[pkg])
    }

    /// Resolves several roots (root stack, header, footer, sheet); a second pass disables buttons while required answers are missing.
    func resolveAll(_ roots: [(JSONValue, String)]) -> [RenderNode?] {
        fieldSatisfaction = [:]
        inputsSatisfied = true
        let first = roots.map { resolve($0.0, $0.1, rootScope()) }
        if fieldSatisfaction.values.allSatisfy({ $0 }) || !ctx.enforceRequiredInputs { return first }
        inputsSatisfied = false
        return roots.map { resolve($0.0, $0.1, rootScope()) }
    }

    // MARK: Dispatch

    private func resolve(_ json: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        switch json.str("type") {
        case "stack": return stack(json, key, scope)
        case "text": return text(json, key, scope)
        case "image": return image(json, key, scope)
        case "icon": return icon(json, key, scope)
        case "video": return video(json, key, scope)
        case "button": return button(json, key, scope)
        case "purchase_button": return wrapped(json, key, scope, .purchase(actionId: json.obj("triggers")?.str("on_purchase_press")), "purchase_button")
        case "redemption_button": return redemption(json, key, scope)
        case "package": return pkg(json, key, scope)
        case "input_single_choice", "input_multiple_choice": return choice(json, key, scope)
        case "input_option": return option(json, key, scope)
        case "input_text": return textField(json, key, scope)
        case "carousel": return carousel(json, key, scope)
        case "tabs": return tabs(json, key, scope)
        case "tab_control": return scope.tabs?.control?.obj("stack").flatMap { stack($0, "\(key)/c", scope) }
        case "tab_control_button": return tabButton(json, key, scope)
        case "tab_control_toggle": return toggle(json, key, scope)
        case "timeline": return timeline(json, key, scope)
        case "countdown": return countdown(json, key, scope)
        case "header", "footer": return json.obj("stack").flatMap { stack($0, "\(key)/s", scope) }
        // Web payment buttons (Apple Pay / Google Pay on the web) never show in an app.
        case "wallet_button", "express_purchase_button", "skeleton_loader": return nil
        default: return json.obj("fallback").flatMap { resolve($0, "\(key)/f", scope) }
        }
    }

    private func children(_ list: [JSONValue]?, _ key: String, _ scope: Scope) -> [RenderNode] {
        (list ?? []).enumerated().compactMap { i, e in e.isObject ? resolve(e, "\(key)/\(i)", scope) : nil }
    }

    // MARK: Stack

    private func stack(_ raw: JSONValue, _ key: String, _ scope: Scope, action: Action? = nil, disabled: Bool = false, semantics: Semantics = Semantics()) -> RenderNode? {
        let json = Overrides.apply(raw, Overrides.State(selected: scope.selected))
        if json.bool("visible") == false { return nil }
        let kids = children(json.arr("components"), key, scope)
        let badgeJSON = json.obj("badge")
        let badgeStyle = badgeJSON?.str("style")
        let badgeAlignment = badgeJSON?.str("alignment") ?? "top"
        let badgeNode = (badgeStyle == "overlay" || badgeStyle == "nested") ? badgeJSON?.obj("stack").flatMap { stack($0, "\(key)/badge", scope) } : nil
        let layout = LayoutNode(
            id: json.str("id"),
            width: SizeSpec.decode(json.obj("size")?["width"]),
            height: SizeSpec.decode(json.obj("size")?["height"]),
            dimension: StackDimension.decode(json["dimension"]),
            spacing: json.num("spacing") ?? 0,
            padding: Spacing.decode(json["padding"]),
            margin: Spacing.decode(json["margin"]),
            border: json.obj("border")?.num("width") ?? 0,
            children: kids.map(\.layout),
            key: key,
            badge: badgeNode.map {
                LayoutNode.Badge(
                    node: $0.layout,
                    overlay: badgeStyle == "overlay",
                    top: badgeAlignment.hasPrefix("top"),
                    horizontal: badgeAlignment.hasSuffix("leading") ? .start : badgeAlignment.hasSuffix("trailing") ? .end : .center
                )
            }
        )
        var sem = semantics
        sem.isButton = sem.isButton || action != nil
        return RenderNode(
            key: key, jsonId: json.str("id"), type: "stack", layout: layout,
            paint: boxPaint(json, json["background_color"], json["background"], disabled: disabled),
            action: action, disabled: disabled, semantics: sem, children: kids, badge: badgeNode
        )
    }

    // MARK: Text

    static let fontSizes: [String: Double] = [
        "body_s": 13, "body_m": 14, "body_l": 15, "body_xl": 16,
        "heading_xs": 14, "heading_s": 16, "heading_m": 18, "heading_l": 20, "heading_xl": 26, "heading_xxl": 32,
    ]
    static let fontWeights: [String: Int] = [
        "extra_light": 100, "thin": 200, "light": 300, "regular": 400, "medium": 500,
        "semibold": 600, "bold": 700, "extra_bold": 800, "black": 900,
    ]

    private func fontSize(_ v: JSONValue?) -> Double {
        switch v {
        case let .number(n)?: return n == n.rounded() && n.isFinite ? n : 14
        case let .string(s)?:
            if let n = Double(s), n == n.rounded(), n.isFinite { return n }
            return Self.fontSizes[s] ?? 14
        default: return 14
        }
    }

    private func font(_ json: JSONValue, name nameKey: String = "font_name", weightInt: String = "font_weight_int", size: String = "font_size", weight: String? = "font_weight") -> FontSpec {
        let name = json.str(nameKey)
        let declared = name.map { ctx.fonts[$0] != nil } ?? false
        let family = declared ? TextLogic.parseFontName(name!)?.family : nil
        let w = json.num(weightInt).map(\.clampedInt) ?? weight.flatMap { Self.fontWeights[json.str($0) ?? ""] } ?? 400
        return FontSpec(name: declared ? name : nil, family: family, size: fontSize(json[size]) * ctx.fontScale, weight: w)
    }

    private func align(_ v: String?) -> TextAlign { v == "center" ? .center : v == "trailing" ? .end : .start }

    private func text(_ raw: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        let info = scope.packageInfo
        let json = Overrides.apply(raw, Overrides.State(
            selected: scope.selected,
            introOffer: info?.hasIntroOffer == true || info?.hasTrial == true,
            promoOffer: info?.hasPromoOffer == true
        ))
        guard Overrides.isVisible(raw["overrides"], baseVisible: raw.bool("visible"), selectedPackageId: state.selectedPackageId, packageInfo: info, variables: scope.variables) else { return nil }
        let label = TextLogic.replaceVariables(ctx.localized(json.str("text_lid")), scope.variables)
        let runs = TextLogic.runs(label)
        let f = font(json)
        let content = TextContent(runs: runs, font: f, color: fill(json["color"]) ?? .solid(.black), align: align(json.str("horizontal_alignment")))
        let padding = Spacing.decode(json["padding"])
        let margin = Spacing.decode(json["margin"])
        let layout = LayoutNode(
            id: json.str("id"),
            width: SizeSpec.decode(json.obj("size")?["width"]),
            height: SizeSpec.decode(json.obj("size")?["height"]),
            dimension: .vertical(alignment: .start, distribution: .start),
            // The web wraps the text in a block whose margin sits inside the sized wrapper.
            padding: Spacing(top: padding.top + margin.top, bottom: padding.bottom + margin.bottom, leading: padding.leading + margin.leading, trailing: padding.trailing + margin.trailing),
            measurable: TextMeasurable(runs: runs, font: f, measurer: ctx.measurer),
            key: key
        )
        return RenderNode(key: key, jsonId: json.str("id"), type: "text", layout: layout, paint: Paint(background: fill(json["background_color"])),
                          content: .text(content), semantics: Semantics(label: content.plain))
    }

    // MARK: Media

    private func imageFiles(_ info: JSONValue?) -> JSONValue? {
        guard let info else { return nil }
        return (ctx.dark ? info.obj("dark") : nil) ?? info.obj("light")
    }

    private func mask(_ json: JSONValue?) -> Mask {
        switch json?.str("type") {
        case "circle": return .circle
        case "concave": return .concave
        case "convex": return .convex
        case "rectangle": return .rect(corners(json?.obj("corners")))
        default: return .rect(.none)
        }
    }

    private func mediaLayout(_ json: JSONValue, _ key: String, naturalWidth w: Double, naturalHeight h: Double) -> LayoutNode {
        let width = SizeSpec.decode(json.obj("size")?["width"])
        var fixedWidth = false
        if case .fixed = width { fixedWidth = true }
        return LayoutNode(
            id: json.str("id"),
            width: width,
            height: SizeSpec.decode(json.obj("size")?["height"]),
            dimension: .vertical(alignment: .start, distribution: .start),
            padding: Spacing.decode(json["padding"]),
            margin: Spacing.decode(json["margin"]),
            measurable: MediaMeasurable(naturalWidth: w),
            key: key,
            shrink: !fixedWidth,
            aspectRatio: w > 0 && h > 0 ? h / w : 0
        )
    }

    private func image(_ raw: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        let json = Overrides.apply(raw, Overrides.State(selected: scope.selected))
        guard let files = imageFiles(json.obj("source")), let url = files.str("original") ?? files.str("webp") else { return nil }
        let border = json.obj("border")
        let content = ImageContent(
            url: url, cover: json.str("fit_mode") == "fill", overlay: fill(json["color_overlay"]), mask: mask(json.obj("mask_shape")),
            borderWidth: border?.num("width") ?? 0, borderFill: fill(border?["color"]), shadow: shadow(json.obj("shadow"))
        )
        return RenderNode(key: key, jsonId: json.str("id"), type: "image",
                          layout: mediaLayout(json, key, naturalWidth: files.num("width") ?? 0, naturalHeight: files.num("height") ?? 0),
                          content: .image(content), semantics: Semantics(hidden: true))
    }

    private func video(_ raw: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        let json = Overrides.apply(raw, Overrides.State(selected: scope.selected))
        let fallback = imageFiles(json.obj("fallback_source"))
        guard let files = imageFiles(json.obj("source")), let url = files.str("url") else { return nil }
        let content = VideoContent(
            url: url, fallbackImageURL: fallback?.str("original"), cover: json.str("fit_mode") == "fill",
            autoPlay: json.bool("auto_play") ?? true, loop: json.bool("loop") ?? true, muted: json.bool("mute_audio") ?? true,
            showControls: json.bool("show_controls") ?? false, mask: mask(json.obj("mask_shape")), overlay: fill(json["color_overlay"])
        )
        let w = files.num("width") ?? fallback?.num("width") ?? 0
        let h = files.num("height") ?? fallback?.num("height") ?? 0
        return RenderNode(key: key, jsonId: json.str("id"), type: "video", layout: mediaLayout(json, key, naturalWidth: w, naturalHeight: h),
                          content: .video(content), semantics: Semantics(hidden: true))
    }

    private func icon(_ raw: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        let json = Overrides.apply(raw, Overrides.State(selected: scope.selected))
        guard let base = json.str("base_url"), let formats = json.obj("formats"),
              let file = formats.str("webp") ?? formats.str("png") ?? formats.str("svg") else { return nil }
        let background = json.obj("icon_background")
        let border = background?.obj("border")
        let layout = LayoutNode(
            id: json.str("id"),
            width: SizeSpec.decode(json.obj("size")?["width"]),
            height: SizeSpec.decode(json.obj("size")?["height"]),
            dimension: .vertical(alignment: .start, distribution: .start),
            padding: Spacing.decode(json["padding"]),
            margin: Spacing.decode(json["margin"]),
            border: border?.num("width") ?? 0,
            key: key,
            shrink: false
        )
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let trimmedFile = file.hasPrefix("/") ? String(file.dropFirst()) : file
        return RenderNode(
            key: key, jsonId: json.str("id"), type: "icon", layout: layout,
            paint: Paint(background: fill(background?["color"]), borderWidth: border?.num("width") ?? 0, borderFill: fill(border?["color"]),
                         corners: shapeCorners(background?.obj("shape")), shadow: shadow(background?.obj("shadow"))),
            content: .icon(url: "\(trimmedBase)/\(trimmedFile)", color: fill(json["color"])),
            semantics: Semantics(hidden: true)
        )
    }

    // MARK: Buttons and packages

    private func hasText(_ e: JSONValue?) -> Bool {
        switch e {
        case let .object(o)?: return o["type"]?.stringValue == "text" || hasText(o["components"]) || hasText(o["stack"])
        case let .array(a)?: return a.contains { hasText($0) }
        default: return false
        }
    }

    private func wrapped(_ json: JSONValue, _ key: String, _ scope: Scope, _ action: Action, _ type: String, disabled: Bool = false) -> RenderNode? {
        guard let stackJSON = json.obj("stack") else { return nil }
        let label = hasText(stackJSON) ? nil : json.str("name")
        let sem = Semantics(isButton: true, label: label, disabled: disabled)
        guard let node = stack(stackJSON, key, scope, action: disabled ? nil : action, disabled: disabled, semantics: sem) else { return nil }
        return node.retyped(type, action: disabled ? nil : action, disabled: disabled, semantics: node.semantics)
    }

    private func button(_ raw: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        let json = Overrides.apply(raw, Overrides.State(selected: scope.selected))
        guard let action = json.obj("action") else { return nil }
        let type = action.str("type")
        let visible: Bool
        switch type {
        case "restore_purchases": visible = ctx.showRestoreButton
        case "navigate_back": visible = !ctx.hideBackButtons
        case "navigate_to": visible = action.str("destination") != "web_paywall_link"
        default: visible = true
        }
        guard visible else { return nil }
        let actionId = raw.obj("triggers")?.str("on_press")
        let disabled = (type == "workflow" || type == "complete_workflow") && actionId != "screen:back" && !inputsSatisfied
        return wrapped(raw, key, scope, .button(action: action, actionId: actionId), "button", disabled: disabled)
    }

    private func redemption(_ json: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        guard let url = scope.variables["success.redemption_url"], !url.isEmpty else { return nil }
        return wrapped(json, key, scope, .openURL(url), "redemption_button")
    }

    private func pkg(_ json: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        guard let id = json.str("package_id"), let stackJSON = json.obj("stack") else { return nil }
        var inner = scope
        if let own = ctx.variablesPerPackage[id] { inner.variables = ctx.baseVariables.merging(own) { $1 } }
        inner.packageInfo = ctx.infoPerPackage[id] ?? scope.packageInfo
        inner.selected = state.selectedPackageId == id
        guard let node = stack(stackJSON, key, inner, action: .selectPackage(id), semantics: Semantics(isButton: true, selected: inner.selected)) else { return nil }
        return node.retyped("package", action: node.action, disabled: false, semantics: node.semantics)
    }

    // MARK: Questions

    private func choice(_ json: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        let fieldId = json.str("field_id") ?? ""
        let multiple = json.str("type") == "input_multiple_choice"
        let required = json.bool("required") ?? false
        let range = json.obj("selection_range")
        let minCount = range?.num("min").map(\.clampedInt)
        let maxCount = range?.num("max").map(\.clampedInt)
        let count = state.choices[fieldId]?.count ?? 0
        let satisfied: Bool
        if !required && range == nil { satisfied = true }
        else if required && range == nil { satisfied = count >= 1 }
        else if required { satisfied = minCount == maxCount ? count == minCount : count >= (minCount ?? 0) && count <= (maxCount ?? Int.max) }
        else { satisfied = true }
        if !fieldId.isEmpty { fieldSatisfaction[fieldId] = satisfied }
        var inner = scope
        inner.choice = Choice(fieldId: fieldId, multiple: multiple, atMax: maxCount.map { count >= $0 } ?? false)
        return json.obj("stack").flatMap { resolve($0, "\(key)/s", inner) }
    }

    private func option(_ json: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        guard let optionId = json.str("option_id"), let stackJSON = json.obj("stack") else { return nil }
        let choice = scope.choice
        let chosen = choice.map { state.choices[$0.fieldId]?.contains(optionId) == true } ?? false
        let disabled = choice.map { !chosen && $0.atMax } ?? false
        let actionId = json.obj("triggers")?.str("on_press")
        var inner = scope
        inner.selected = chosen
        let action = choice.map { Action.selectOption(fieldId: $0.fieldId, optionId: optionId, multiple: $0.multiple, actionId: actionId) }
        guard let node = stack(stackJSON, key, inner, action: disabled ? nil : action, disabled: disabled, semantics: Semantics(isButton: true, selected: chosen)) else { return nil }
        return node.retyped("input_option", action: node.action, disabled: disabled, semantics: node.semantics)
    }

    private func textField(_ raw: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        let fieldId = raw.str("field_id") ?? ""
        let json = Overrides.apply(raw, Overrides.State(focus: state.focusedField == fieldId, error: state.textErrors.contains(fieldId)))
        if raw.bool("visible") == false { return nil }
        let required = json.bool("required") ?? false
        let value = state.texts[fieldId] ?? ""
        let valid = !state.textErrors.contains(fieldId)
        if !fieldId.isEmpty { fieldSatisfaction[fieldId] = !required || (valid && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        let f = font(json, weight: nil)
        let placeholderFont = font(json, name: "placeholder_font_name", weightInt: "placeholder_font_weight_int", size: "placeholder_font_size", weight: nil)
        let border = json.obj("border")
        let layout = LayoutNode(
            id: json.str("id"),
            width: SizeSpec.decode(json.obj("size")?["width"]),
            height: SizeSpec.decode(json.obj("size")?["height"]),
            dimension: .vertical(alignment: .start, distribution: .start),
            padding: Spacing.decode(json["padding"]),
            margin: Spacing.decode(json["margin"]),
            border: border?.num("width") ?? 0,
            measurable: FieldMeasurable(font: f),
            key: key
        )
        let content = TextFieldContent(
            fieldId: fieldId,
            placeholder: TextLogic.replaceVariables(ctx.localized(json.str("placeholder_lid")), scope.variables),
            keyboard: json.str("keyboard_type") ?? "text",
            capitalize: json.str("capitalize") ?? "none",
            required: required,
            value: value,
            font: f,
            color: fill(json["color"]) ?? .solid(.black),
            align: align(json.str("horizontal_alignment")),
            placeholderFont: placeholderFont,
            placeholderColor: fill(json["placeholder_color"]) ?? .solid(Rgba(0, 0, 0, 0.5)),
            placeholderAlign: align(json.str("placeholder_horizontal_alignment"))
        )
        return RenderNode(
            key: key, jsonId: json.str("id"), type: "input_text", layout: layout,
            paint: Paint(background: fill(json["background_color"]), borderWidth: border?.num("width") ?? 0, borderFill: fill(border?["color"]),
                         corners: shapeCorners(json.obj("shape")), shadow: shadow(json.obj("shadow"))),
            content: .textField(content)
        )
    }

    // MARK: Carousel

    private func carousel(_ raw: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        let json = Overrides.apply(raw, Overrides.State(selected: scope.selected))
        let pagesJSON = (json.arr("pages") ?? []).filter(\.isObject)
        guard !pagesJSON.isEmpty else { return nil }
        let initial = json.num("initial_page_index").map(\.clampedInt).flatMap { pagesJSON.indices.contains($0) ? $0 : nil } ?? 0
        let current = state.carouselPages[key].flatMap { pagesJSON.indices.contains($0) ? $0 : nil } ?? initial
        let peek = json.num("page_peek") ?? 0
        let pageSpacing = json.num("page_spacing") ?? 0
        let pages: [RenderNode] = pagesJSON.enumerated().compactMap { i, page in
            guard let node = stack(page, "\(key)/p\(i)", scope) else { return nil }
            // Each page is exactly one slider width (flex: 0 0 100%).
            let l = node.layout
            let sized = LayoutNode(id: l.id, width: .relative(1), height: l.height, dimension: l.dimension, spacing: l.spacing, padding: l.padding,
                                   margin: l.margin, border: l.border, children: l.children, key: l.key, shrink: false, badge: l.badge)
            return RenderNode(key: node.key, jsonId: node.jsonId, type: node.type, layout: sized, paint: node.paint, action: node.action,
                              semantics: node.semantics, children: node.children, badge: node.badge)
        }
        let slider = LayoutNode(
            id: nil, width: .fill, height: .fit,
            dimension: .horizontal(alignment: Align.decode(json.str("page_alignment")), distribution: .start),
            spacing: pageSpacing,
            padding: Spacing(top: 0, bottom: 0, leading: peek + pageSpacing, trailing: peek + pageSpacing),
            children: pages.map(\.layout), key: "\(key)/slider"
        )
        let auto = json.obj("auto_advance")
        let sliderNode = RenderNode(
            key: "\(key)/slider", jsonId: nil, type: "carousel_slider", layout: slider, children: pages,
            carousel: RenderNode.CarouselInfo(
                key: key, pageCount: pages.count, currentPage: current, loop: json.bool("loop") ?? false, pageSpacing: pageSpacing,
                autoAdvanceMs: auto?.num("ms_time_per_page").map(\.clampedInt), transitionMs: auto?.num("ms_transition_time").map(\.clampedInt) ?? 500
            )
        )
        let controlJSON = json.obj("page_control")
        let control = controlJSON.map { pageControl($0, "\(key)/dots", count: pages.count, current: current) }
        let top = controlJSON?.str("position") == "top"
        let parts = [top ? control : nil, sliderNode, top ? nil : control].compactMap { $0 }
        let border = json.obj("border")
        let layout = LayoutNode(
            id: json.str("id"), width: .fill, height: .fit, dimension: .vertical(alignment: .center, distribution: .start),
            padding: Spacing.decode(json["padding"]), margin: Spacing.decode(json["margin"]), border: border?.num("width") ?? 0,
            children: parts.map(\.layout), key: key, shrink: false
        )
        return RenderNode(
            key: key, jsonId: json.str("id"), type: "carousel", layout: layout,
            paint: Paint(background: backgroundFill(nil, json["background"]), borderWidth: border?.num("width") ?? 0, borderFill: fill(border?["color"]),
                         corners: shapeCorners(json.obj("shape")), shadow: shadow(json.obj("shadow"))),
            children: parts, clipsChildren: true
        )
    }

    private func pageControl(_ json: JSONValue, _ key: String, count: Int, current: Int) -> RenderNode {
        let dots: [RenderNode] = (0..<count).map { i in
            let indicator = json.obj(i == current ? "active" : "default")
            let strokeWidth = indicator?.num("stroke_width")
            let strokeColor = indicator?["stroke_color"]
            let hasStroke = strokeWidth != nil && strokeColor != nil && strokeColor?.isNull == false
            return RenderNode(
                key: "\(key)/\(i)", jsonId: nil, type: "page_indicator",
                layout: LayoutNode(id: nil, width: .fixed(indicator?.num("width") ?? 8), height: .fixed(indicator?.num("height") ?? 8),
                                   dimension: .vertical(alignment: .start, distribution: .start), border: hasStroke ? strokeWidth! : 0, key: "\(key)/\(i)"),
                paint: Paint(background: fill(indicator?["color"]), borderWidth: hasStroke ? strokeWidth! : 0,
                             borderFill: hasStroke ? fill(strokeColor) : nil, corners: Corners(pill: true)),
                semantics: Semantics(hidden: true)
            )
        }
        let border = json.obj("border")
        return RenderNode(
            key: key, jsonId: nil, type: "page_control",
            layout: LayoutNode(id: nil, width: .fit, height: .fit, dimension: .horizontal(alignment: .center, distribution: .center),
                               spacing: json.num("spacing") ?? 0, padding: Spacing.decode(json["padding"]), margin: Spacing.decode(json["margin"]),
                               border: border?.num("width") ?? 0, children: dots.map(\.layout), key: key),
            paint: Paint(background: fill(json["background_color"]), borderWidth: border?.num("width") ?? 0, borderFill: fill(border?["color"]),
                         corners: shapeCorners(json.obj("shape")), shadow: shadow(json.obj("shadow"))),
            semantics: Semantics(label: "Page \(current + 1) of \(count)"),
            children: dots
        )
    }

    // MARK: Tabs

    private func tabs(_ raw: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        let json = Overrides.apply(raw, Overrides.State(selected: scope.selected))
        let tabs = (json.arr("tabs") ?? []).filter(\.isObject)
        let defaultIndex = max(0, tabs.firstIndex { $0.str("id") == json.str("default_tab_id") } ?? -1)
        let index = state.tabs[key].flatMap { tabs.indices.contains($0) ? $0 : nil } ?? defaultIndex
        var inner = scope
        inner.tabs = Tabs(key: key, control: json.obj("control"), selectedIndex: index, tabIds: tabs.map { $0.str("id") })
        let active: RenderNode? = tabs.indices.contains(index)
            ? Overrides.apply(tabs[index], Overrides.State(selected: scope.selected)).obj("stack").flatMap { stack($0, "\(key)/t\(index)", inner) }
            : nil
        let kids = [active].compactMap { $0 }
        let border = json.obj("border")
        let layout = LayoutNode(
            id: json.str("id"), width: SizeSpec.decode(json.obj("size")?["width"]), height: SizeSpec.decode(json.obj("size")?["height"]),
            // A block holding the active tab's stack: the same rules as a z-layer's first layer.
            dimension: .zlayer(horizontal: .start, vertical: .start),
            padding: Spacing.decode(json["padding"]), margin: Spacing.decode(json["margin"]), border: border?.num("width") ?? 0,
            children: kids.map(\.layout), key: key
        )
        return RenderNode(
            key: key, jsonId: json.str("id"), type: "tabs", layout: layout,
            paint: Paint(background: backgroundFill(nil, json["background"]), borderWidth: border?.num("width") ?? 0, borderFill: fill(border?["color"]),
                         corners: shapeCorners(json.obj("shape")), shadow: shadow(json.obj("shadow"))),
            children: kids
        )
    }

    private func tabButton(_ json: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        guard let tabs = scope.tabs else { return json.obj("stack").flatMap { stack($0, key, scope) } }
        guard let stackJSON = json.obj("stack") else { return nil }
        let tabId = json.str("tab_id")
        let found = tabs.tabIds.firstIndex(of: tabId)
        let index = found ?? json.num("tab_index").map(\.clampedInt) ?? -1
        let selected = tabs.tabIds.indices.contains(tabs.selectedIndex) && tabs.tabIds[tabs.selectedIndex] == tabId
        var inner = scope
        inner.selected = selected
        let action: Action? = tabs.tabIds.indices.contains(index) ? .selectTab(tabsKey: tabs.key, index: index) : nil
        guard let node = stack(stackJSON, key, inner, action: action, semantics: Semantics(isButton: true, selected: selected)) else { return nil }
        return node.retyped("tab_control_button", action: node.action, disabled: false, semantics: node.semantics)
    }

    private func toggle(_ raw: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        let on = scope.tabs?.selectedIndex == 1
        let json = Overrides.apply(raw, Overrides.State(selected: on))
        return RenderNode(
            key: key, jsonId: json.str("id"), type: "tab_control_toggle",
            layout: LayoutNode(id: json.str("id"), width: .fixed(51), height: .fixed(31), dimension: .vertical(alignment: .start, distribution: .start), key: key),
            content: .toggle(on: on, track: fill(json[on ? "track_color_on" : "track_color_off"]), thumb: fill(json[on ? "thumb_color_on" : "thumb_color_off"])),
            action: scope.tabs.map { .selectTab(tabsKey: $0.key, index: on ? 0 : 1) },
            semantics: Semantics(isButton: true, label: "Toggle", selected: on)
        )
    }

    // MARK: Timeline

    private func timeline(_ raw: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        let json = Overrides.apply(raw, Overrides.State(selected: scope.selected))
        let items = (json.arr("items") ?? []).filter(\.isObject)
        guard !items.isEmpty else { return nil }
        let gutter = json.num("column_gutter") ?? 0
        let textSpacing = json.num("text_spacing") ?? 0
        let itemSpacing = json.num("item_spacing") ?? 0
        // Grid "auto 1fr": the icon column is as wide as the widest icon.
        let icons: [RenderNode?] = items.enumerated().map { i, item in item.obj("icon").flatMap { icon($0, "\(key)/r\(i)/icon", scope) } }
        let iconColumn = icons.map { node -> Double in
            guard let l = node?.layout else { return 0 }
            if case let .fixed(v) = l.width { return v + l.margin.horizontal }
            return LayoutEngine.maxContent(l)
        }.max() ?? 0
        let rows: [RenderNode] = items.enumerated().map { i, item in
            let rowKey = "\(key)/r\(i)"
            let iconNode = icons[i]
            let connector = item.obj("connector")
            let texts = [item.obj("title").flatMap { text($0, "\(rowKey)/title", scope) },
                         item.obj("description").flatMap { text($0, "\(rowKey)/desc", scope) }].compactMap { $0 }
            let content = RenderNode(
                key: "\(rowKey)/content", jsonId: nil, type: "timeline_content",
                layout: LayoutNode(id: nil, width: .fill, height: .fit, dimension: .vertical(alignment: .start, distribution: .start), spacing: textSpacing,
                                   margin: Spacing(top: 0, bottom: itemSpacing, leading: 0, trailing: 0), children: texts.map(\.layout), key: "\(rowKey)/content"),
                children: texts
            )
            var iconSize = 24.0
            if case let .fixed(v)? = iconNode?.layout.width { iconSize = v }
            let iconCell = RenderNode(
                key: "\(rowKey)/iconcell", jsonId: nil, type: "timeline_icon",
                layout: LayoutNode(id: nil, width: .fixed(iconColumn), height: .fill, dimension: .zlayer(horizontal: .start, vertical: .start),
                                   children: [iconNode?.layout].compactMap { $0 }, key: "\(rowKey)/iconcell", shrink: false),
                children: [iconNode].compactMap { $0 }
            )
            let margin = connector?.obj("margin")
            return RenderNode(
                key: rowKey, jsonId: item.str("id"), type: "timeline_item",
                layout: LayoutNode(id: item.str("id"), width: .fill, height: .fit, dimension: .horizontal(alignment: .start, distribution: .start),
                                   spacing: gutter, children: [iconCell.layout, content.layout], key: rowKey),
                children: [iconCell, content],
                connector: connector.map {
                    RenderNode.Connector(width: $0.num("width") ?? 0, fill: fill($0["color"]), centerX: iconColumn / 2,
                                         top: iconSize / 2 + (margin?.num("top") ?? 0), bottomInset: (margin?.num("bottom") ?? 0) - iconSize / 2)
                }
            )
        }
        let layout = LayoutNode(
            id: json.str("id"), width: SizeSpec.decode(json.obj("size")?["width"]), height: SizeSpec.decode(json.obj("size")?["height"]),
            dimension: .vertical(alignment: .start, distribution: .start), padding: Spacing.decode(json["padding"]), margin: Spacing.decode(json["margin"]),
            children: rows.map(\.layout), key: key
        )
        return RenderNode(key: key, jsonId: json.str("id"), type: "timeline", layout: layout, children: rows)
    }

    // MARK: Countdown

    private func countdown(_ json: JSONValue, _ key: String, _ scope: Scope) -> RenderNode? {
        let target = json.obj("style")?.str("date").flatMap(Countdown.parseDate)
        let ended = target.map { Countdown.hasEnded(targetMs: $0, nowMs: state.nowMs) } ?? false
        let values = target.map { Countdown.values(targetMs: $0, nowMs: state.nowMs) } ?? Countdown.values(targetMs: 0, nowMs: 1)
        var inner = scope
        inner.variables = scope.variables.merging(values) { $1 }
        guard let stackJSON = (ended ? json.obj("end_stack") : nil) ?? json.obj("countdown_stack") else { return nil }
        return stack(stackJSON, "\(key)/\(ended ? "end" : "run")", inner)
    }

    // MARK: Paint helpers

    private func color(_ info: JSONValue?) -> Rgba? {
        guard let type = info?.str("type"), let value = info?.str("value") else { return nil }
        switch type {
        case "hex": return Rgba.parse(value)
        case "alias": return Rgba.parse(colors[value] ?? value)
        default: return nil
        }
    }

    /// A `ColorGradientScheme` (`{ light, dark }`) for the current color mode.
    func fill(_ scheme: JSONValue?) -> Fill? {
        guard let scheme, scheme.isObject else { return nil }
        guard let info = (ctx.dark ? scheme.obj("dark") : nil) ?? scheme.obj("light") else { return nil }
        switch info.str("type") {
        case "hex", "alias": return color(info).map(Fill.solid)
        case "linear": return .linear(degrees: info.num("degrees") ?? 180, stops: stops(info))
        case "radial": return .radial(stops: stops(info))
        default: return nil
        }
    }

    private func stops(_ info: JSONValue) -> [GradientStop] {
        (info.arr("points") ?? []).compactMap { p in
            guard let c = p.str("color").flatMap({ Rgba.parse(colors[$0] ?? $0) }) else { return nil }
            return GradientStop(color: c, percent: p.num("percent") ?? 0)
        }
    }

    /// `mapBackground`: a `background` object wins, with `background_color` overriding its color.
    func backgroundFill(_ backgroundColor: JSONValue?, _ background: JSONValue?) -> Fill? {
        switch background?.str("type") {
        case nil: return fill(backgroundColor)
        case "color":
            let override = backgroundColor.flatMap { $0.isNull ? nil : $0 }
            return fill(override ?? background?["value"])
        case "image":
            guard let files = imageFiles(background?.obj("value")), let url = files.str("webp") ?? files.str("original") else { return nil }
            return .image(url: url, cover: background?.str("fit_mode") == "fill", overlay: fill(background?["color_overlay"]))
        default: return nil
        }
    }

    private func corners(_ json: JSONValue?) -> Corners {
        Corners(topLeading: json?.num("top_leading") ?? 0, topTrailing: json?.num("top_trailing") ?? 0,
                bottomTrailing: json?.num("bottom_trailing") ?? 0, bottomLeading: json?.num("bottom_leading") ?? 0)
    }

    private func shapeCorners(_ shape: JSONValue?) -> Corners {
        switch shape?.str("type") {
        case "rectangle": return corners(shape?.obj("corners"))
        case "circle", "pill": return Corners(pill: true)
        default: return .none
        }
    }

    private func shadow(_ json: JSONValue?) -> Shadow? {
        guard let json, let c = fill(json["color"])?.approximateColor else { return nil }
        return Shadow(x: json.num("x") ?? 0, y: json.num("y") ?? 0, radius: json.num("radius") ?? 0, color: c)
    }

    private func boxPaint(_ json: JSONValue, _ backgroundColor: JSONValue?, _ background: JSONValue?, disabled: Bool) -> Paint {
        let border = json.obj("border")
        return Paint(background: backgroundFill(backgroundColor, background), borderWidth: border?.num("width") ?? 0, borderFill: fill(border?["color"]),
                     corners: shapeCorners(json.obj("shape")), shadow: shadow(json.obj("shadow")), opacity: disabled ? 0.4 : 1)
    }
}

/// Text content measured by the platform; min-content is the widest word (no breaking inside words).
final class TextMeasurable: Measurable {
    private let runs: [TextLogic.Run]
    private let font: FontSpec
    private let measurer: TextMeasurer
    private lazy var maxWidth: Double = runs.isEmpty ? 0 : measurer.measure(runs, font: font, maxWidth: nil).width
    private lazy var minWidth: Double = {
        guard !runs.isEmpty else { return 0 }
        var widest = 0.0
        for run in runs {
            for word in run.text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
                var r = run
                r.text = String(word)
                widest = max(widest, measurer.measure([r], font: font, maxWidth: nil).width)
            }
        }
        return widest
    }()
    private var heights: [Double: Double] = [:]

    init(runs: [TextLogic.Run], font: FontSpec, measurer: TextMeasurer) {
        self.runs = runs
        self.font = font
        self.measurer = measurer
    }

    func minContentWidth() -> Double { minWidth }
    func maxContentWidth() -> Double { maxWidth }
    func height(forWidth width: Double) -> Double {
        if runs.isEmpty { return 0 }
        if let h = heights[width] { return h }
        let h = measurer.measure(runs, font: font, maxWidth: max(width, minWidth)).height
        heights[width] = h
        return h
    }
}

/// Images and videos: as wide as their file at most, any narrower width allowed.
struct MediaMeasurable: Measurable {
    let naturalWidth: Double
    func minContentWidth() -> Double { 0 }
    func maxContentWidth() -> Double { naturalWidth }
    func height(forWidth width: Double) -> Double { 0 }
}

/// A one-line text input: its line is 1.5 x the font size, like the paywall's text.
struct FieldMeasurable: Measurable {
    let font: FontSpec
    func minContentWidth() -> Double { 0 }
    // Chrome sizes an input with no width to about 20 characters.
    func maxContentWidth() -> Double { font.size * 0.55 * 20 }
    func height(forWidth width: Double) -> Double { font.lineHeight }
}
