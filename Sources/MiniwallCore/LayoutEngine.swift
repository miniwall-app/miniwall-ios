import Foundation

/// Content measured by the platform (text, images): sizes of the content box in pt.
/// Leaves without content (an empty stack) have no measurable.
public protocol Measurable {
    func minContentWidth() -> Double
    func maxContentWidth() -> Double
    func height(forWidth width: Double) -> Double
}

/// One node of the layout tree. Built from the model by ``LayoutNode/from(_:measure:)``;
/// renderers read frames back by ``id``.
public final class LayoutNode {
    public let id: String?
    public let width: SizeSpec
    public let height: SizeSpec
    public let dimension: StackDimension
    public let spacing: Double
    public let padding: Spacing
    public let margin: Spacing
    public let border: Double
    public let children: [LayoutNode]
    public let measurable: Measurable?
    /// Key the frame is reported under; defaults to `id`. Render trees use unique paths.
    public let key: String?
    /// False for `flex-shrink: 0` items (fixed-width images and videos, icons).
    public let shrink: Bool
    /// Images and videos: height = round(width x ratio) unless the height is fixed.
    public let aspectRatio: Double?
    /// A stack's badge, laid out after the stack (`mapBadge` in stack-utils.js).
    public let badge: Badge?

    /// `overlay` straddles the top or bottom edge; `nested` sits inside it.
    public struct Badge {
        public let node: LayoutNode
        public let overlay: Bool
        public let top: Bool
        public let horizontal: Align

        public init(node: LayoutNode, overlay: Bool, top: Bool, horizontal: Align) {
            self.node = node
            self.overlay = overlay
            self.top = top
            self.horizontal = horizontal
        }
    }

    /// Border-box frame in screen coordinates, set by ``LayoutEngine``.
    public internal(set) var frame: LayoutRect?

    public init(
        id: String?,
        width: SizeSpec,
        height: SizeSpec,
        dimension: StackDimension,
        spacing: Double = 0,
        padding: Spacing = .zero,
        margin: Spacing = .zero,
        border: Double = 0,
        children: [LayoutNode] = [],
        measurable: Measurable? = nil,
        key: String? = nil,
        shrink: Bool = true,
        aspectRatio: Double? = nil,
        badge: Badge? = nil
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.dimension = dimension
        self.spacing = spacing
        self.padding = padding
        self.margin = margin
        self.border = border
        self.children = children
        self.measurable = measurable
        self.key = key ?? id
        self.shrink = shrink
        self.aspectRatio = aspectRatio
        self.badge = badge
    }

    // Memoized measurements: intrinsic widths never change; auto heights depend only on the width.
    // Without them nested stacks re-measure their subtrees at every level.
    var maxContentCache: Double?
    var minContentCache: Double?
    var autoHeightCache: [Double: Double] = [:]

    /// Padding + border, per axis. A box is never smaller than this.
    var pbH: Double { padding.horizontal + 2 * border }
    var pbV: Double { padding.vertical + 2 * border }

    /// Layout tree for a component; hidden nodes are dropped, unsupported ones are replaced by
    /// their fallback or dropped (same as the web's Node.svelte). Nil when nothing renders.
    public static func from(_ component: Component, measure: (Component) -> Measurable? = { _ in nil }) -> LayoutNode? {
        guard component.isVisible else { return nil }
        switch component {
        case let .stack(s):
            return LayoutNode(
                id: s.id,
                width: s.width,
                height: s.height,
                dimension: s.dimension,
                spacing: s.spacing,
                padding: s.padding,
                margin: s.margin,
                border: s.borderWidth,
                children: s.components.compactMap { from($0, measure: measure) }
            )
        case let .unsupported(_, _, _, fallback):
            return fallback.flatMap { from($0, measure: measure) }
        }
    }
}

public struct LayoutRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Computes the frame of every node the way the web renderer's CSS does
/// (the web renderer). Pure and deterministic: the same algorithm
/// exists in Kotlin (sdks/android/core) and both are checked against goldens from the web
/// (the shared conformance suite). All sizes are border-box, in pt (= CSS px = dp).
public enum LayoutEngine {
    /// Lays out a screen's root stack inside a `screenWidth` x `screenHeight` area. The root
    /// always takes the full height (it grows and shrinks, like `.paywall-content-scroll`).
    /// Returns frames by node id, in screen coordinates.
    public static func layoutScreen(_ root: LayoutNode, screenWidth: Double, screenHeight: Double) -> [String: LayoutRect] {
        var frames: [String: LayoutRect] = [:]
        let width = stretchWidth(root, screenWidth)
        let height = max(screenHeight - root.margin.vertical, root.pbV)
        layout(root, x: root.margin.leading, y: root.margin.top, w: width, h: height, into: &frames)
        return frames
    }

    /// Lays out `node` with its border box at (x, y, w, h); frames go on the nodes and are returned by key.
    @discardableResult
    public static func layoutAt(_ node: LayoutNode, x: Double, y: Double, w: Double, h: Double) -> [String: LayoutRect] {
        var frames: [String: LayoutRect] = [:]
        layout(node, x: x, y: y, w: w, h: h, into: &frames)
        return frames
    }

    /// Border-box width of `node` inside a containing content box `containerWidth` wide (block flow).
    public static func widthIn(_ node: LayoutNode, _ containerWidth: Double) -> Double { stretchWidth(node, containerWidth) }

    // MARK: Intrinsic widths

    /// max-content width (border-box): the width with no line breaks and nothing shrunk.
    public static func maxContent(_ n: LayoutNode) -> Double {
        if let cached = n.maxContentCache { return cached }
        let value = computeMaxContent(n)
        n.maxContentCache = value
        return value
    }

    private static func computeMaxContent(_ n: LayoutNode) -> Double {
        let content: Double
        if let m = n.measurable {
            content = m.maxContentWidth()
        } else if n.children.isEmpty {
            content = 0
        } else {
            switch n.dimension {
            case .horizontal:
                content = n.children.reduce(0.0) { $0 + maxContribution($1) } + n.spacing * Double(n.children.count - 1)
            case .vertical:
                content = n.children.map(maxContribution).max() ?? 0
            case .zlayer:
                content = maxContribution(n.children[0])
            }
        }
        return n.pbH + content
    }

    /// min-content width (border-box): the narrowest the content can get. A row's items sit side by side.
    public static func minContent(_ n: LayoutNode) -> Double {
        if let cached = n.minContentCache { return cached }
        let value = computeMinContent(n)
        n.minContentCache = value
        return value
    }

    private static func computeMinContent(_ n: LayoutNode) -> Double {
        let content: Double
        if let m = n.measurable {
            content = m.minContentWidth()
        } else if n.children.isEmpty {
            content = 0
        } else {
            switch n.dimension {
            case .horizontal:
                content = n.children.reduce(0.0) { $0 + minContribution($1) } + n.spacing * Double(n.children.count - 1)
            case .vertical:
                content = n.children.map(minContribution).max() ?? 0
            case .zlayer:
                content = minContribution(n.children[0])
            }
        }
        return n.pbH + content
    }

    // A fixed width contributes itself; fit, fill and relative contribute their content (CSS treats them as auto here).
    private static func maxContribution(_ c: LayoutNode) -> Double {
        if case let .fixed(v) = c.width { return c.margin.horizontal + max(v, c.pbH) }
        return c.margin.horizontal + maxContent(c)
    }

    private static func minContribution(_ c: LayoutNode) -> Double {
        if case let .fixed(v) = c.width { return c.margin.horizontal + max(v, c.pbH) }
        return c.margin.horizontal + minContent(c)
    }

    /// `fit-content`: shrink-to-fit inside `available`, never below min-content.
    private static func fitContent(_ n: LayoutNode, _ available: Double) -> Double {
        min(maxContent(n), max(minContent(n), available))
    }

    /// Width of a child whose containing content box is `cw` wide, before any flex shrinking:
    /// fixed, relative (% of cw), fill (cw minus margins, `-webkit-fill-available`), fit (fit-content).
    /// Used for a vertical stack's children, a row's flex basis, z-layers and the root.
    private static func stretchWidth(_ c: LayoutNode, _ cw: Double) -> Double {
        let w: Double
        switch c.width {
        case let .fixed(v): w = v
        case let .relative(f): w = f * cw
        case .fill: w = cw - c.margin.horizontal
        case .fit: w = fitContent(c, cw - c.margin.horizontal)
        }
        return max(c.pbH, w)
    }

    /// Content-based minimum width of a row item (`min-width: auto`).
    private static func minMainWidth(_ c: LayoutNode, _ cw: Double) -> Double {
        let w: Double
        switch c.width {
        case let .fixed(v): w = min(v, minContent(c))
        case let .relative(f): w = min(f * cw, minContent(c))
        case .fill, .fit: w = minContent(c)
        }
        return max(c.pbH, w)
    }

    // MARK: Auto heights

    /// Height (border-box) of `n` at border-box width `w` when its height is auto: what the content needs.
    /// Relative and fill heights of children count as their content here (CSS: percentages of an
    /// indefinite height behave as auto); they resolve against this height in `layout`.
    public static func autoHeight(_ n: LayoutNode, width w: Double) -> Double {
        if let cached = n.autoHeightCache[w] { return cached }
        let value = computeAutoHeight(n, width: w)
        n.autoHeightCache[w] = value
        return value
    }

    private static func computeAutoHeight(_ n: LayoutNode, width w: Double) -> Double {
        let cw = max(w - n.pbH, 0)
        let content: Double
        if let m = n.measurable {
            content = m.height(forWidth: cw)
        } else if n.children.isEmpty {
            content = 0
        } else {
            switch n.dimension {
            case .vertical:
                content = n.children.reduce(0.0) { $0 + $1.margin.vertical + contentHeight($1, stretchWidth($1, cw)) }
                    + n.spacing * Double(n.children.count - 1)
            case .horizontal:
                let widths = rowWidths(n, cw)
                content = n.children.indices.map { n.children[$0].margin.vertical + contentHeight(n.children[$0], widths[$0]) }.max() ?? 0
            case .zlayer:
                let first = n.children[0]
                content = first.margin.vertical + contentHeight(first, stretchWidth(first, cw))
            }
        }
        return n.pbV + content
    }

    /// A child's height when the parent's height is not known yet: fixed stays, the rest is content.
    private static func contentHeight(_ c: LayoutNode, _ w: Double) -> Double {
        specifiedHeight(c, w) ?? autoHeight(c, width: w)
    }

    /// A height known without the parent: fixed, or from the aspect ratio (images, videos).
    private static func specifiedHeight(_ c: LayoutNode, _ w: Double) -> Double? {
        if case let .fixed(v) = c.height { return max(v, c.pbV) }
        if let ratio = c.aspectRatio { return max((w * ratio).rounded(.toNearestOrAwayFromZero), c.pbV) }
        return nil
    }

    // MARK: Layout

    private static func layout(_ n: LayoutNode, x: Double, y: Double, w: Double, h: Double, into out: inout [String: LayoutRect]) {
        let frame = LayoutRect(x: x, y: y, width: w, height: h)
        n.frame = frame
        if let key = n.key { out[key] = frame }
        if let badge = n.badge { layoutBadge(n, badge, frame, &out) }
        if n.children.isEmpty { return }
        let cx = x + n.border + n.padding.leading
        let cy = y + n.border + n.padding.top
        let cw = max(w - n.pbH, 0)
        let ch = max(h - n.pbV, 0)
        switch n.dimension {
        case let .vertical(alignment, distribution):
            layoutColumn(n, alignment, distribution, cx, cy, cw, ch, &out)
        case let .horizontal(alignment, distribution):
            layoutRow(n, alignment, distribution, cx, cy, cw, ch, &out)
        case let .zlayer(horizontal, vertical):
            layoutLayers(n, horizontal, vertical, cx, cy, cw, ch, &out)
        }
    }

    private static func layoutColumn(
        _ n: LayoutNode, _ alignment: Align, _ distribution: Distribution,
        _ cx: Double, _ cy: Double, _ cw: Double, _ ch: Double, _ out: inout [String: LayoutRect]
    ) {
        let items = n.children
        let widths = items.map { stretchWidth($0, cw) }
        let contentHeights = items.indices.map { autoHeight(items[$0], width: widths[$0]) }
        let bases: [Double] = items.indices.map { i in
            let c = items[i]
            if let h = specifiedHeight(c, widths[i]) { return h }
            switch c.height {
            case let .relative(f): return max(f * ch, c.pbV)
            // fill on a column's main axis is auto in Chrome (-webkit-fill-available does not apply to flex main sizes).
            default: return contentHeights[i]
            }
        }
        let mins: [Double] = items.indices.map { i in
            let c = items[i]
            let m: Double
            switch c.height {
            case let .fixed(v): m = min(v, contentHeights[i])
            // An image's height comes from its width: its content is that tall, so it does not shrink.
            case _ where c.aspectRatio != nil: m = bases[i]
            case let .relative(f): m = min(f * ch, contentHeights[i])
            case .fill, .fit: m = contentHeights[i]
            }
            return max(c.pbV, m)
        }
        let available = ch - n.spacing * Double(items.count - 1) - items.reduce(0.0) { $0 + $1.margin.vertical }
        let heights = flexShrink(bases: bases, mins: mins, inners: items.indices.map { items[$0].shrink ? bases[$0] - items[$0].pbV : 0 }, available: available)
        let offsets = distribute(distribution, space: ch, sizes: items.indices.map { heights[$0] + items[$0].margin.vertical }, gap: n.spacing)
        for i in items.indices {
            let c = items[i]
            let itemX = cx + c.margin.leading + (cw - widths[i] - c.margin.horizontal) * alignment.factor
            layout(c, x: itemX, y: cy + offsets[i] + c.margin.top, w: widths[i], h: heights[i], into: &out)
        }
    }

    private static func layoutRow(
        _ n: LayoutNode, _ alignment: Align, _ distribution: Distribution,
        _ cx: Double, _ cy: Double, _ cw: Double, _ ch: Double, _ out: inout [String: LayoutRect]
    ) {
        let items = n.children
        let widths = rowWidths(n, cw)
        let heights = items.indices.map { crossHeight(items[$0], widths[$0], ch) }
        let offsets = distribute(distribution, space: cw, sizes: items.indices.map { widths[$0] + items[$0].margin.horizontal }, gap: n.spacing)
        for i in items.indices {
            let c = items[i]
            let itemY = cy + c.margin.top + (ch - heights[i] - c.margin.vertical) * alignment.factor
            layout(c, x: cx + offsets[i] + c.margin.leading, y: itemY, w: widths[i], h: heights[i], into: &out)
        }
    }

    /// Item widths of a row with content width `cw`: flex basis, then shrink to fit.
    private static func rowWidths(_ n: LayoutNode, _ cw: Double) -> [Double] {
        let items = n.children
        let bases = items.map { stretchWidth($0, cw) }
        let mins = items.map { minMainWidth($0, cw) }
        let available = cw - n.spacing * Double(items.count - 1) - items.reduce(0.0) { $0 + $1.margin.horizontal }
        return flexShrink(bases: bases, mins: mins, inners: items.indices.map { items[$0].shrink ? bases[$0] - items[$0].pbH : 0 }, available: available)
    }

    /// Height of an item on a row's cross axis (also a z-layer's upper layers) whose line is `ch` tall:
    /// fill stretches to the line, relative is a fraction of it, fit is the content.
    private static func crossHeight(_ c: LayoutNode, _ w: Double, _ ch: Double) -> Double {
        if let specified = specifiedHeight(c, w) { return specified }
        let h: Double
        switch c.height {
        case let .fixed(v): h = v
        case let .relative(f): h = f * ch
        case .fill: h = ch - c.margin.vertical
        case .fit: h = autoHeight(c, width: w)
        }
        return max(c.pbV, h)
    }

    /// Z-layer: the first layer is in normal flow (it sizes a fit z-layer); every other layer is
    /// placed over the content box by the stack's alignment, like a one-item row.
    private static func layoutLayers(
        _ n: LayoutNode, _ horizontal: Align, _ vertical: Align,
        _ cx: Double, _ cy: Double, _ cw: Double, _ ch: Double, _ out: inout [String: LayoutRect]
    ) {
        for (index, c) in n.children.enumerated() {
            if index == 0 {
                let w = stretchWidth(c, cw)
                let h: Double
                if let specified = specifiedHeight(c, w) {
                    h = specified
                } else if case let .relative(f) = c.height {
                    h = max(f * ch, c.pbV)
                } else {
                    // fill in block flow is auto in Chrome.
                    h = autoHeight(c, width: w)
                }
                layout(c, x: cx + c.margin.leading, y: cy + c.margin.top, w: w, h: h, into: &out)
            } else {
                let basis = stretchWidth(c, cw)
                let w = flexShrink(bases: [basis], mins: [minMainWidth(c, cw)], inners: [c.shrink ? basis - c.pbH : 0], available: cw - c.margin.horizontal)[0]
                let h = crossHeight(c, w, ch)
                let x = cx + c.margin.leading + (cw - w - c.margin.horizontal) * horizontal.factor
                let y = cy + c.margin.top + (ch - h - c.margin.vertical) * vertical.factor
                layout(c, x: x, y: y, w: w, h: h, into: &out)
            }
        }
    }

    /// A badge is absolutely positioned against the stack's padding box at its max-content size.
    /// `overlay` centers it on the top or bottom edge; `nested` puts it inside, one border width in.
    private static func layoutBadge(_ n: LayoutNode, _ badge: LayoutNode.Badge, _ f: LayoutRect, _ out: inout [String: LayoutRect]) {
        let b = n.border
        let node = badge.node
        let w: Double
        if case let .fixed(v) = node.width { w = max(v, node.pbH) } else { w = maxContent(node) }
        let h = specifiedHeight(node, w) ?? autoHeight(node, width: w)
        let x: Double
        let y: Double
        if badge.overlay {
            switch badge.horizontal {
            case .start: x = f.x
            case .center: x = f.x + f.width / 2 - w / 2
            case .end: x = f.x + f.width - w
            }
            y = badge.top ? f.y + b / 2 - h / 2 : f.y + f.height - b / 2 - h / 2
        } else {
            switch badge.horizontal {
            case .start: x = f.x + 2 * b
            case .center: x = f.x + f.width / 2 - w / 2
            case .end: x = f.x + f.width - 2 * b - w
            }
            y = badge.top ? f.y + 2 * b : f.y + f.height - 2 * b - h
        }
        layout(node, x: x + node.margin.leading, y: y + node.margin.top, w: w, h: h, into: &out)
    }

    // MARK: Flex

    /// CSS flexbox "resolve flexible lengths" for items with flex-grow 0 and flex-shrink 1
    /// (every stack child on the web). Items only shrink, in proportion to their inner
    /// (content-box) base size, never below their minimum.
    static func flexShrink(bases: [Double], mins: [Double], inners: [Double], available: Double) -> [Double] {
        let hypothetical = bases.indices.map { max(bases[$0], mins[$0]) }
        if hypothetical.reduce(0.0, +) <= available { return hypothetical }
        var target = hypothetical
        var frozen = bases.indices.map { bases[$0] < mins[$0] || inners[$0] <= 0 }
        while frozen.contains(false) {
            let free = available - bases.indices.reduce(0.0) { $0 + (frozen[$1] ? target[$1] : bases[$1]) }
            let scaled = bases.indices.filter { !frozen[$0] }.reduce(0.0) { $0 + inners[$1] }
            var totalViolation = 0.0
            var violation = [Double](repeating: 0, count: bases.count)
            for i in bases.indices where !frozen[i] {
                let raw = scaled > 0 ? bases[i] + free * inners[i] / scaled : bases[i]
                let clamped = max(raw, mins[i])
                violation[i] = clamped - raw
                totalViolation += violation[i]
                target[i] = clamped
            }
            if totalViolation <= 0 { break }
            for i in bases.indices where !frozen[i] && violation[i] > 0 { frozen[i] = true }
        }
        return target
    }

    /// Main-axis start offset of each item (outer sizes `sizes`) for a distribution, inside `space`.
    static func distribute(_ distribution: Distribution, space: Double, sizes: [Double], gap: Double) -> [Double] {
        let n = Double(sizes.count)
        if sizes.isEmpty { return [] }
        let free = space - sizes.reduce(0.0, +) - gap * (n - 1)
        // Negative free space: space-between falls back to start, space-around/evenly to center (CSS Box Alignment).
        let spacing: (lead: Double, between: Double)
        switch distribution {
        case .start: spacing = (0, 0)
        case .center: spacing = (free / 2, 0)
        case .end: spacing = (free, 0)
        case .spaceBetween: spacing = free > 0 && n > 1 ? (0, free / (n - 1)) : (0, 0)
        case .spaceAround: spacing = free > 0 ? (free / (2 * n), free / n) : (free / 2, 0)
        case .spaceEvenly: spacing = free > 0 ? (free / (n + 1), free / (n + 1)) : (free / 2, 0)
        }
        let between = spacing.between
        var position = spacing.lead
        return sizes.map { size in
            defer { position += size + gap + between }
            return position
        }
    }
}
