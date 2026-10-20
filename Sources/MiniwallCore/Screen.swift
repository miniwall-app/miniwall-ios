import Foundation

/// One laid-out screen, ready to paint: the header pinned at the top, the root stack (which
/// scrolls inside `rootFrame` when `contentHeight` is taller), the footer pinned at the bottom,
/// and an open sheet over a dimmed backdrop. Mirrors the web renderer.
public final class ScreenRender {
    public let width: Double
    public let height: Double
    public let background: Fill?
    public let header: RenderNode?
    public let root: RenderNode
    /// Height of the root's scrollable content (>= its frame height).
    public let contentHeight: Double
    public let footer: RenderNode?
    public let sheet: RenderNode?

    init(width: Double, height: Double, background: Fill?, header: RenderNode?, root: RenderNode, contentHeight: Double, footer: RenderNode?, sheet: RenderNode?) {
        self.width = width
        self.height = height
        self.background = background
        self.header = header
        self.root = root
        self.contentHeight = contentHeight
        self.footer = footer
        self.sheet = sheet
    }

    public var rootFrame: LayoutRect { root.frame }
}

/// Locale choice (render.ts resolveLocale): exact, then same language, then the default.
public enum Localization {
    public static func resolve(_ available: [String], requested: String?, defaultLocale: String) -> String {
        if let requested, !requested.isEmpty {
            // Only the first '-' (like the web): en-US -> en_US.
            var normalized = requested
            if let dash = normalized.firstIndex(of: "-") { normalized.replaceSubrange(dash...dash, with: "_") }
            let sorted = available.sorted()
            if let exact = sorted.first(where: { $0 == normalized }) { return exact }
            let language = normalized.split(separator: "_").first.map(String.init) ?? normalized
            if let same = sorted.first(where: { ($0.split(separator: "_").first.map(String.init) ?? $0) == language }) { return same }
        }
        return defaultLocale
    }
}

public enum ScreenLayout {
    /// Default package: the first marked `is_selected_by_default`, else the first one (root stack, then sticky footer).
    public static func defaultPackageId(_ base: JSONValue) -> String? {
        func first(_ root: JSONValue?, _ predicate: (JSONValue) -> Bool) -> String? {
            var found: String?
            func visit(_ e: JSONValue?) {
                guard found == nil else { return }
                switch e {
                case let .object(o)?:
                    if o["type"]?.stringValue == "package", predicate(e!) { found = o["package_id"]?.stringValue; return }
                    searchChildren(e!).forEach(visit)
                case let .array(a)?: a.forEach(visit)
                default: break
                }
            }
            visit(root)
            return found
        }
        let stack = base["stack"]
        let footer = base["sticky_footer"]
        return first(stack) { $0.bool("is_selected_by_default") == true }
            ?? first(stack) { _ in true }
            ?? first(footer) { $0.bool("is_selected_by_default") == true }
            ?? first(footer) { _ in true }
    }

    /// Children the web's package search walks (getPaywallComponentChildNodes in style-utils.js).
    private static func searchChildren(_ node: JSONValue) -> [JSONValue?] {
        switch node.str("type") {
        case "stack": return [node["components"], node.obj("badge")?["stack"]]
        case "button", "purchase_button", "redemption_button", "footer", "input_multiple_choice", "input_single_choice", "input_option", "tab", "tab_control_button", "package":
            return [node["stack"]]
        case "carousel": return [node["pages"]]
        case "countdown": return [node["countdown_stack"], node["end_stack"]]
        case "tabs": return [node.obj("control")?["stack"], node["tabs"]]
        case "timeline": return (node.arr("items") ?? []).flatMap { [$0["icon"], $0["title"], $0["description"]] }
        case "express_purchase_button": return [node["wallet_unknown_stack"], node["wallet_available_stack"], node["wallet_unavailable_stack"]]
        default: return []
        }
    }

    /// A centered row the width of the screen holding a stack (the header and footer wrappers).
    private static func pinnedRow(_ stack: RenderNode, _ key: String, _ width: Double) -> (LayoutNode, Double) {
        let row = LayoutNode(id: nil, width: .fixed(width), height: .fit, dimension: .horizontal(alignment: .start, distribution: .center),
                             children: [stack.layout], key: key)
        return (row, LayoutEngine.autoHeight(row, width: width))
    }

    static func build(_ context: ScreenContext, _ state: ScreenState, width: Double, height: Double) -> ScreenRender? {
        guard let base = context.componentsConfig.obj("base"), let rootJSON = base.obj("stack") else { return nil }
        let headerJSON = base.obj("header")?.obj("stack")
        let footerJSON = base.obj("sticky_footer")?.obj("stack")
        let resolver = Resolver(context, state)
        var roots: [(JSONValue, String)] = [(rootJSON, "root")]
        if let headerJSON { roots.append((headerJSON, "header")) }
        if let footerJSON { roots.append((footerJSON, "footer")) }
        if let sheetStack = state.sheet?.obj("stack") { roots.append((sheetStack, "sheet")) }
        var resolved: [String: RenderNode] = [:]
        for (node, root) in zip(resolver.resolveAll(roots), roots) { if let node { resolved[root.1] = node } }
        guard let root = resolved["root"] else { return nil }
        let header = resolved["header"]
        let footer = resolved["footer"]

        var headerHeight = 0.0
        if let header {
            let (row, h) = pinnedRow(header, "header-row", width)
            headerHeight = h
            LayoutEngine.layoutAt(row, x: 0, y: 0, w: width, h: h)
        }
        var footerHeight = 0.0
        if let footer {
            let (row, h) = pinnedRow(footer, "footer-row", width)
            footerHeight = h
            LayoutEngine.layoutAt(row, x: 0, y: height - h, w: width, h: h)
        }
        // A screen that starts with a full-width image shows it under the header.
        let first = rootJSON.arr("components")?.first
        let pullUnderHeader = header != nil && first?.str("type") == "image" && first?.obj("size")?.obj("width")?.str("type") == "fill"
        let top = pullUnderHeader ? 0 : headerHeight
        let areaHeight = max(height - top - footerHeight, 0)
        let rl = root.layout
        let rootWidth = LayoutEngine.widthIn(rl, width)
        let rootHeight = max(areaHeight - rl.margin.vertical, rl.padding.vertical + 2 * rl.border)
        LayoutEngine.layoutAt(rl, x: rl.margin.leading, y: top + rl.margin.top, w: rootWidth, h: rootHeight)

        let rootFrame = root.frame
        let contentBottom = rl.children.map { ($0.frame.map { $0.y + $0.height } ?? rootFrame.y) + $0.margin.bottom }.max() ?? rootFrame.y
        let contentHeight = max(rootFrame.height, contentBottom - rootFrame.y + rl.padding.bottom + rl.border)

        let sheet = state.sheet.flatMap { json in resolved["sheet"].map { sheetNode(resolver, json, $0, width, height) } }
        var background: Fill?
        if let bg = base.obj("background") {
            switch bg.str("type") {
            case "color": background = resolver.fill(bg["value"])
            case "image":
                let files = (context.dark ? bg.obj("value")?.obj("dark") : nil) ?? bg.obj("value")?.obj("light")
                if let url = files?.str("webp") ?? files?.str("original") {
                    background = .image(url: url, cover: bg.str("fit_mode") == "fill", overlay: resolver.fill(bg["color_overlay"]))
                }
            default: break
            }
        }
        return ScreenRender(width: width, height: height, background: background, header: header, root: root,
                            contentHeight: contentHeight, footer: footer, sheet: sheet)
    }

    /// Height the screen needs at `width` when nothing forces it (banners, toasts, slide-ins, inline):
    /// header + the root stack's content + footer.
    static func intrinsicHeight(_ context: ScreenContext, _ state: ScreenState, width: Double) -> Double {
        guard let base = context.componentsConfig.obj("base"), let rootJSON = base.obj("stack") else { return 0 }
        var roots: [(JSONValue, String)] = [(rootJSON, "root")]
        if let h = base.obj("header")?.obj("stack") { roots.append((h, "header")) }
        if let f = base.obj("sticky_footer")?.obj("stack") { roots.append((f, "footer")) }
        let resolved = Resolver(context, state).resolveAll(roots)
        var total = 0.0
        for (node, root) in zip(resolved, roots) {
            guard let node else { continue }
            if root.1 == "root" {
                let l = node.layout
                total += LayoutEngine.autoHeight(l, width: LayoutEngine.widthIn(l, width)) + l.margin.vertical
            } else {
                total += pinnedRow(node, "\(root.1)-row", width).1
            }
        }
        return total
    }

    /// The sheet: full width at the bottom, its stack inside as in a block.
    private static func sheetNode(_ resolver: Resolver, _ json: JSONValue, _ stack: RenderNode, _ width: Double, _ height: Double) -> RenderNode {
        let box = LayoutNode(id: json.str("id"), width: .fixed(width), height: .fit, dimension: .zlayer(horizontal: .start, vertical: .start),
                             children: [stack.layout], key: "sheet-box")
        let h: Double
        switch SizeSpec.decode(json.obj("size")?["height"]) {
        case let .fixed(v): h = v
        case let .relative(f): h = f * height
        default: h = LayoutEngine.autoHeight(box, width: width)
        }
        LayoutEngine.layoutAt(box, x: 0, y: height - h, w: width, h: h)
        let bg = json.obj("background")
        let fill = bg?.str("type") == "color" ? resolver.fill(bg?["value"]) : nil
        return RenderNode(key: "sheet-box", jsonId: json.str("id"), type: "sheet", layout: box, paint: Paint(background: fill), children: [stack])
    }
}

/// Something the host app handles: purchases, restores, links, custom actions, closing.
public enum ScreenEvent: Equatable {
    case purchase(packageId: String, actionId: String?)
    case restore
    case close
    /// A "Run your code" button, or `screen:<id>` / `screen:back` (handled by the session).
    case customAction(String)
    case openURL(String)
    case completeWorkflow(url: String, method: String)
    case customerCenter
    /// A question's answer changed: the tapped option id or the typed text.
    case answer(fieldId: String, value: String)
    case packageSelected(String)
}

/// State and actions of one shown screen (the web renderer's handlers). Platforms call ``render``
/// when the size or ``state`` changes, and ``handle`` when a node with an action is tapped.
public final class ScreenController {
    private let config: JSONValue
    private let localizations: [String: [String: String]]
    private let defaultLocale: String
    public let locale: String
    private let dark: Bool
    private let variablesPerPackage: [String: [String: String]]
    private let baseVariables: [String: String]
    private let infoPerPackage: [String: PackageInfo]
    private let showRestoreButton: Bool
    private let onEvent: (ScreenEvent) -> Void
    public let fields: [String: Flow.FieldKind]
    public private(set) var state: ScreenState
    /// Called after every state change, so the platform re-renders.
    /// The user's text size setting as a multiplier (the platform sets it before each render).
    public var fontScale = 1.0

    public var onChange: () -> Void = {}

    public init(
        paywall: JSONValue,
        locale requested: String?,
        dark: Bool,
        variablesPerPackage: [String: [String: String]],
        baseVariables: [String: String],
        infoPerPackage: [String: PackageInfo],
        showRestoreButton: Bool,
        initialAnswers: [String: Flow.Answer] = [:],
        onEvent: @escaping (ScreenEvent) -> Void
    ) {
        config = paywall.obj("components_config") ?? .object([:])
        localizations = (paywall.obj("components_localizations")?.objectValue ?? [:]).mapValues { ($0.objectValue ?? [:]).compactMapValues(\.stringValue) }
        defaultLocale = paywall.str("default_locale") ?? "en_US"
        locale = Localization.resolve(Array(localizations.keys), requested: requested, defaultLocale: defaultLocale)
        self.dark = dark
        self.variablesPerPackage = variablesPerPackage
        self.baseVariables = baseVariables
        self.infoPerPackage = infoPerPackage
        self.showRestoreButton = showRestoreButton
        self.onEvent = onEvent
        let fields = Flow.questionFields(config)
        self.fields = fields
        var s = ScreenState()
        s.selectedPackageId = config.obj("base").flatMap(ScreenLayout.defaultPackageId)
        for (fieldId, answer) in initialAnswers {
            switch (fields[fieldId], answer) {
            case (.text?, let .one(v)): s.texts[fieldId] = v
            case (.text?, _): break
            case (_, let .one(v)): s.choices[fieldId] = [v]
            case (_, let .many(vs)): s.choices[fieldId] = vs
            }
        }
        state = s
    }

    private func update(_ next: ScreenState) {
        state = next
        onChange()
    }

    public func context(_ measurer: TextMeasurer) -> ScreenContext {
        ScreenContext(componentsConfig: config, localizations: localizations, defaultLocale: defaultLocale, locale: locale, dark: dark,
                      variablesPerPackage: variablesPerPackage, baseVariables: baseVariables, infoPerPackage: infoPerPackage,
                      showRestoreButton: showRestoreButton, fontScale: fontScale, measurer: measurer)
    }

    public func render(width: Double, height: Double, measurer: TextMeasurer, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> ScreenRender? {
        state.nowMs = nowMs
        return ScreenLayout.build(context(measurer), state, width: width, height: height)
    }

    public func handle(_ action: Action) {
        switch action {
        case let .selectPackage(id):
            guard state.selectedPackageId != id else { return }
            var s = state
            s.selectedPackageId = id
            update(s)
            onEvent(.packageSelected(id))
        case let .purchase(actionId):
            if let id = state.selectedPackageId { onEvent(.purchase(packageId: id, actionId: actionId)) }
        case let .selectTab(key, index):
            guard state.tabs[key] != index else { return }
            var s = state
            s.tabs[key] = index
            update(s)
        case let .selectOption(fieldId, optionId, multiple, actionId):
            let current = state.choices[fieldId] ?? []
            let next: [String]
            if !multiple { next = [optionId] } else if current.contains(optionId) { next = current.filter { $0 != optionId } } else { next = current + [optionId] }
            var s = state
            s.choices[fieldId] = next
            update(s)
            if !fieldId.isEmpty { onEvent(.answer(fieldId: fieldId, value: optionId)) }
            if let actionId { onEvent(.customAction(actionId)) }
        case let .openURL(url):
            onEvent(.openURL(url))
        case let .button(json, actionId):
            button(json, actionId)
        }
    }

    private func localized(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return localizations[locale]?[id] ?? localizations[defaultLocale]?[id]
    }

    private func button(_ a: JSONValue, _ actionId: String?) {
        switch a.str("type") {
        case "workflow":
            if let actionId, !actionId.isEmpty { onEvent(.customAction(actionId)) }
        case "complete_workflow":
            guard let url = localized(a.obj("url")?.str("url_lid")), !url.isEmpty else { return }
            onEvent(.completeWorkflow(url: url, method: a.obj("url")?.str("method") ?? "external_browser"))
        case "navigate_back":
            onEvent(.close)
        case "restore_purchases":
            onEvent(.restore)
        case "navigate_to":
            switch a.str("destination") {
            case "customer_center": onEvent(.customerCenter)
            case "screen_redirect": onEvent(.customAction("screen_redirect"))
            case "privacy_policy", "terms", "url":
                if let url = localized(a.obj("url")?.str("url_lid")), !url.isEmpty { onEvent(.openURL(url)) }
            case "sheet":
                var s = state
                if let sheet = a.obj("sheet") {
                    s.sheet = sheet
                    s.sheetRootPackageId = state.selectedPackageId
                } else {
                    s.sheet = nil
                    s.selectedPackageId = state.sheetRootPackageId
                }
                update(s)
            default: break
            }
        default: break
        }
    }

    /// Closes an open sheet (backdrop tap, swipe), restoring the package selected when it opened.
    public func closeSheet() {
        guard state.sheet != nil else { return }
        var s = state
        s.sheet = nil
        s.selectedPackageId = state.sheetRootPackageId
        update(s)
    }

    public func setCarouselPage(_ key: String, _ page: Int) {
        guard state.carouselPages[key] != page else { return }
        var s = state
        s.carouselPages[key] = page
        update(s)
    }

    /// The visitor typed in a text field. `valid` is the keyboard type's own check (email, url, number).
    public func setText(_ fieldId: String, _ value: String, valid: Bool) {
        var s = state
        s.texts[fieldId] = value
        if valid { s.textErrors.remove(fieldId) }
        update(s)
        if valid { onEvent(.answer(fieldId: fieldId, value: value.trimmingCharacters(in: .whitespacesAndNewlines))) }
    }

    public func focus(_ fieldId: String?) {
        var s = state
        s.focusedField = fieldId
        update(s)
    }

    /// Leaving a field shows its error state when the value is invalid.
    public func blur(_ fieldId: String, valid: Bool) {
        var s = state
        s.focusedField = nil
        if valid { s.textErrors.remove(fieldId) } else { s.textErrors.insert(fieldId) }
        update(s)
    }

    /// Height the screen needs at `width` (banners, toasts, slide-ins, inline placement).
    public func intrinsicHeight(width: Double, measurer: TextMeasurer) -> Double {
        ScreenLayout.intrinsicHeight(context(measurer), state, width: width)
    }

    /// The page behind the screen, for the area outside the layout (safe areas): the paywall's
    /// background, else the root stack's.
    public func pageBackground() -> Fill? {
        struct NoText: TextMeasurer {
            func measure(_ runs: [TextLogic.Run], font: FontSpec, maxWidth: Double?) -> (width: Double, height: Double) { (0, 0) }
        }
        let resolver = Resolver(context(NoText()), state)
        let base = config.obj("base")
        if let bg = base?.obj("background"), bg.str("type") == "color", let fill = resolver.fill(bg["value"]) { return fill }
        let root = base?.obj("stack")
        return resolver.backgroundFill(root?["background_color"], root?["background"])
    }

    /// Whether the screen shows a countdown, so the platform re-renders every second.
    public lazy var hasCountdown: Bool = {
        var found = false
        Flow.walk(config) { if $0.str("type") == "countdown" { found = true } }
        return found
    }()
}
