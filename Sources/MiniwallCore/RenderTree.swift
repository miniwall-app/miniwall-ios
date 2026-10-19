import Foundation

/// sRGB color, components 0...1. Mirrors `RenderTree.kt`.
public struct Rgba: Equatable, Sendable {
    public var r, g, b, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let clear = Rgba(0, 0, 0, 0)
    public static let black = Rgba(0, 0, 0)

    /// `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA` (CSS order, alpha last), or `transparent`.
    public static func parse(_ value: String?) -> Rgba? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces) else { return nil }
        if raw.lowercased() == "transparent" { return .clear }
        var s = raw
        if s.hasPrefix("#") { s.removeFirst() }
        let full: String
        switch s.count {
        case 3, 4: full = s.map { "\($0)\($0)" }.joined()
        case 6, 8: full = s
        default: return nil
        }
        guard let v = UInt64(full, radix: 16) else { return nil }
        func byte(_ shift: UInt64) -> Double { Double((v >> shift) & 0xFF) / 255 }
        return full.count == 8 ? Rgba(byte(24), byte(16), byte(8), byte(0)) : Rgba(byte(16), byte(8), byte(0))
    }
}

public struct GradientStop: Equatable, Sendable {
    public var color: Rgba
    public var percent: Double
}

/// What fills an area: a color, a CSS gradient, or an image.
public indirect enum Fill: Equatable, Sendable {
    case solid(Rgba)
    /// CSS `linear-gradient(<degrees>deg, ...)`: 0deg points up, 90deg points right.
    case linear(degrees: Double, stops: [GradientStop])
    /// CSS `radial-gradient(circle, ...)`: centered, to the farthest corner.
    case radial(stops: [GradientStop])
    /// Background image; `cover` = `fit_mode: fill` (center), else contain (top center).
    case image(url: String, cover: Bool, overlay: Fill?)

    /// A single color standing in for this fill where it cannot be painted (first stop).
    public var approximateColor: Rgba? {
        switch self {
        case let .solid(c): return c
        case let .linear(_, stops), let .radial(stops): return stops.first?.color
        case .image: return nil
        }
    }
}

public struct Shadow: Equatable, Sendable {
    public var x, y, radius: Double
    public var color: Rgba
}

/// Corner radii in pt. `pill` = fully rounded (CSS 9999px): min(width, height) / 2.
public struct Corners: Equatable, Sendable {
    public var topLeading = 0.0
    public var topTrailing = 0.0
    public var bottomTrailing = 0.0
    public var bottomLeading = 0.0
    public var pill = false

    public init(topLeading: Double = 0, topTrailing: Double = 0, bottomTrailing: Double = 0, bottomLeading: Double = 0, pill: Bool = false) {
        self.topLeading = topLeading
        self.topTrailing = topTrailing
        self.bottomTrailing = bottomTrailing
        self.bottomLeading = bottomLeading
        self.pill = pill
    }

    public static let none = Corners()
    public var isZero: Bool { !pill && topLeading == 0 && topTrailing == 0 && bottomTrailing == 0 && bottomLeading == 0 }

    /// Radii (top-leading, top-trailing, bottom-trailing, bottom-leading) for a box, clamped like CSS.
    public func resolved(width: Double, height: Double) -> [Double] {
        let maxRadius = min(width, height) / 2
        if pill { return Array(repeating: maxRadius, count: 4) }
        return [topLeading, topTrailing, bottomTrailing, bottomLeading].map { min($0, maxRadius) }
    }
}

/// How a box is painted (behind its children).
public struct Paint: Equatable, Sendable {
    public var background: Fill?
    public var borderWidth = 0.0
    public var borderFill: Fill?
    public var corners = Corners.none
    public var shadow: Shadow?
    /// 0.4 for disabled buttons and options.
    public var opacity = 1.0

    public init(background: Fill? = nil, borderWidth: Double = 0, borderFill: Fill? = nil, corners: Corners = .none, shadow: Shadow? = nil, opacity: Double = 1) {
        self.background = background
        self.borderWidth = borderWidth
        self.borderFill = borderFill
        self.corners = corners
        self.shadow = shadow
        self.opacity = opacity
    }

    public static let none = Paint()
}

public enum TextAlign: Sendable { case start, center, end }

public struct FontSpec: Equatable, Sendable {
    /// `components_config.fonts` key (e.g. `Fraunces@700`), or nil for the system font.
    public var name: String?
    /// Family parsed from `name`, when it has the `Family@weight` form.
    public var family: String?
    public var size: Double
    public var weight: Int
    /// CSS line height of the paywall: 1.5 x size.
    public var lineHeight: Double { size * 1.5 }
}

/// Shape that clips an image or video (`mask_shape`).
public enum Mask: Equatable, Sendable {
    case rect(Corners)
    case circle
    /// Bottom edge curves up 54pt in the middle.
    case concave
    /// Bottom edge curves down: sides end 27pt above the bottom.
    case convex
}

public enum Content: Sendable {
    case text(TextContent)
    case image(ImageContent)
    /// A monochrome icon: the image at `url` used as a mask, filled with `color`.
    case icon(url: String, color: Fill?)
    case video(VideoContent)
    /// The tab switch (51 x 31).
    case toggle(on: Bool, track: Fill?, thumb: Fill?)
    case textField(TextFieldContent)
}

public struct TextContent: Sendable {
    public var runs: [TextLogic.Run]
    public var font: FontSpec
    public var color: Fill
    public var align: TextAlign
    public var plain: String { runs.map(\.text).joined() }
}

public struct ImageContent: Sendable {
    public var url: String
    public var cover: Bool
    public var overlay: Fill?
    public var mask: Mask
    public var borderWidth: Double
    public var borderFill: Fill?
    public var shadow: Shadow?
}

public struct VideoContent: Sendable {
    public var url: String
    public var fallbackImageURL: String?
    public var cover: Bool
    public var autoPlay: Bool
    public var loop: Bool
    public var muted: Bool
    public var showControls: Bool
    public var mask: Mask
    public var overlay: Fill?
}

public struct TextFieldContent: Sendable {
    public var fieldId: String
    public var placeholder: String
    public var keyboard: String
    public var capitalize: String
    public var required: Bool
    public var value: String
    public var font: FontSpec
    public var color: Fill
    public var align: TextAlign
    public var placeholderFont: FontSpec
    public var placeholderColor: Fill
    public var placeholderAlign: TextAlign
}

/// What a tap does. ``ScreenController`` turns it into state changes or host events.
public enum Action: Sendable {
    case selectPackage(String)
    /// Buy the selected package; the id is the button's `triggers.on_purchase_press`, if any.
    case purchase(actionId: String?)
    /// A button's `action` (workflow, complete_workflow, navigate_back, restore_purchases, navigate_to).
    case button(action: JSONValue, actionId: String?)
    case selectTab(tabsKey: String, index: Int)
    case selectOption(fieldId: String, optionId: String, multiple: Bool, actionId: String?)
    case openURL(String)
}

/// Accessibility of a node: role and label for VoiceOver.
public struct Semantics: Sendable {
    public var isButton = false
    public var label: String?
    public var selected: Bool?
    public var hidden = false
    /// Not available now (a continue button waiting for a required answer): announced as dimmed.
    public var disabled = false

    public init(isButton: Bool = false, label: String? = nil, selected: Bool? = nil, hidden: Bool = false, disabled: Bool = false) {
        self.isButton = isButton
        self.label = label
        self.selected = selected
        self.hidden = hidden
        self.disabled = disabled
    }
}

/// One painted node. `layout` holds its frame after ``LayoutEngine`` runs. Children paint in
/// order on top of the parent; `badge` paints above everything in it.
public final class RenderNode: Identifiable {
    /// Unique within a screen, stable across re-renders (path of indices).
    public let key: String
    public let jsonId: String?
    public let type: String
    public let layout: LayoutNode
    public let paint: Paint
    public let content: Content?
    public let action: Action?
    public let disabled: Bool
    public let semantics: Semantics
    public let children: [RenderNode]
    public let badge: RenderNode?
    /// Carousel: clip children to this box.
    public let clipsChildren: Bool
    /// Carousel slider: the node a horizontal swipe moves.
    public let carousel: CarouselInfo?
    /// Timeline row: the bar joining this item's icon to the next, painted under the icon.
    public let connector: Connector?

    public var id: String { key }

    public struct CarouselInfo: Sendable {
        public let key: String
        public let pageCount: Int
        public let currentPage: Int
        public let loop: Bool
        public let pageSpacing: Double
        public let autoAdvanceMs: Int?
        public let transitionMs: Int
    }

    /// Vertical bar, `width` wide, centered `centerX` from the row's left edge, from `top` below
    /// the row's top to `bottomInset` above its bottom (negative: it runs past the row).
    public struct Connector: Sendable {
        public let width: Double
        public let fill: Fill?
        public let centerX: Double
        public let top: Double
        public let bottomInset: Double
    }

    public init(
        key: String, jsonId: String?, type: String, layout: LayoutNode, paint: Paint = .none, content: Content? = nil,
        action: Action? = nil, disabled: Bool = false, semantics: Semantics = Semantics(), children: [RenderNode] = [],
        badge: RenderNode? = nil, clipsChildren: Bool = false, carousel: CarouselInfo? = nil, connector: Connector? = nil
    ) {
        self.key = key
        self.jsonId = jsonId
        self.type = type
        self.layout = layout
        self.paint = paint
        self.content = content
        self.action = action
        self.disabled = disabled
        self.semantics = semantics
        self.children = children
        self.badge = badge
        self.clipsChildren = clipsChildren
        self.carousel = carousel
        self.connector = connector
    }

    /// A copy with another type, action and state (wrappers: button, package, option...).
    func retyped(_ type: String, action: Action?, disabled: Bool, semantics: Semantics, content: Content? = nil) -> RenderNode {
        RenderNode(key: key, jsonId: jsonId, type: type, layout: layout, paint: paint, content: content, action: action,
                   disabled: disabled, semantics: semantics, children: children, badge: badge)
    }

    public func walk(_ visit: (RenderNode) -> Void) {
        visit(self)
        children.forEach { $0.walk(visit) }
        badge?.walk(visit)
    }

    public var frame: LayoutRect { layout.frame ?? LayoutRect(x: 0, y: 0, width: 0, height: 0) }
}
