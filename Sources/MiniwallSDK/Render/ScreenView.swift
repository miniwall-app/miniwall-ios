#if os(iOS)
import Combine
import MiniwallCore
import SwiftUI
import UIKit

/// Observable wrapper of a ``ScreenController``: SwiftUI re-renders on every state change.
final class ScreenModel: ObservableObject {
    let controller: ScreenController
    @Published private(set) var version = 0
    @Published var busy = false

    init(controller: ScreenController) {
        self.controller = controller
        controller.onChange = { [weak self] in self?.version += 1 }
    }
}

/// What nodes call back into: taps, links, text input, carousel pages.
struct RenderActions {
    let model: ScreenModel
    let openURL: (String) -> Void

    func tap(_ action: Action) { model.controller.handle(action) }
}

/// One node at its frame, relative to its parent's frame origin; children follow.
struct NodeView: View {
    let node: RenderNode
    let origin: CGPoint
    let actions: RenderActions

    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let f = node.frame
        let size = CGSize(width: f.width, height: f.height)
        let here = CGPoint(x: f.x, y: f.y)
        content(size: size, here: here)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .opacity(node.paint.opacity)
            .modifier(TapModifier(action: node.action, disabled: node.disabled, actions: actions))
            .modifier(SemanticsModifier(semantics: node.semantics, isText: node.type == "text", fallbackLabel: node.semantics.isButton && node.semantics.label == nil ? Self.plainText(of: node) : ""))
            .offset(x: f.x - origin.x, y: f.y - origin.y)
    }

    /// The texts inside a node, in reading order: the name of a button that has no label of its own.
    private static func plainText(of node: RenderNode) -> String {
        var parts: [String] = []
        if case let .text(text) = node.content, !node.semantics.hidden, !text.plain.isEmpty { parts.append(text.plain) }
        for child in node.children where !child.semantics.hidden {
            let inner = plainText(of: child)
            if !inner.isEmpty { parts.append(inner) }
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func content(size: CGSize, here: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            BoxPaint(paint: node.paint, size: size)
            leaf(size: size)
            if let connector = node.connector { ConnectorView(connector: connector, rowHeight: size.height) }
            if let carousel = node.carousel {
                slider(carousel, size: size, here: here)
            } else if node.clipsChildren {
                ZStack(alignment: .topLeading) { children(here: here) }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .clipShape(CornerShape(corners: node.paint.corners))
            } else {
                children(here: here)
            }
            if let badge = node.badge { NodeView(node: badge, origin: here, actions: actions) }
        }
    }

    @ViewBuilder
    private func children(here: CGPoint) -> some View {
        ForEach(node.children) { child in NodeView(node: child, origin: here, actions: actions) }
    }

    @ViewBuilder
    private func leaf(size: CGSize) -> some View {
        let l = node.layout
        let inner = CGSize(width: max(0, size.width - CGFloat(l.padding.horizontal + 2 * l.border)), height: max(0, size.height - CGFloat(l.padding.vertical + 2 * l.border)))
        let innerOffset = CGPoint(x: CGFloat(l.border + l.padding.leading), y: CGFloat(l.border + l.padding.top))
        switch node.content {
        case let .text(text)?:
            TextNodeView(content: text, size: inner, openURL: actions.openURL)
                .frame(width: inner.width, height: inner.height, alignment: .topLeading)
                .offset(x: innerOffset.x, y: innerOffset.y)
        case let .image(image)?:
            ImageNodeView(content: image, size: inner).offset(x: innerOffset.x, y: innerOffset.y)
        case let .icon(url, color)?:
            IconView(url: url, color: color, size: inner).offset(x: innerOffset.x, y: innerOffset.y)
        case let .video(video)?:
            VideoNodeView(content: video)
                .frame(width: inner.width, height: inner.height)
                .clipShape(MaskShape(mask: video.mask))
                .overlay {
                    if let tint = video.overlay { Rectangle().fill(PaintStyle.style(tint, size: inner)).clipShape(MaskShape(mask: video.mask)) }
                }
                .offset(x: innerOffset.x, y: innerOffset.y)
        case let .toggle(on, track, thumb)?:
            ToggleView(on: on, track: track, thumb: thumb)
        case let .textField(field)?:
            let controller = actions.model.controller
            TextFieldView(
                content: field,
                onChange: { value, valid in controller.setText(field.fieldId, value, valid: valid) },
                onFocus: { focused, value, valid in
                    if focused { controller.focus(field.fieldId) } else { controller.blur(field.fieldId, valid: valid) }
                }
            )
            .frame(width: inner.width, height: inner.height)
            .offset(x: innerOffset.x, y: innerOffset.y)
        case nil:
            EmptyView()
        }
    }

    /// A carousel's pages: shifted to the current page, dragged by a horizontal swipe.
    @ViewBuilder
    private func slider(_ info: RenderNode.CarouselInfo, size: CGSize, here: CGPoint) -> some View {
        let first = node.children.first?.frame
        let step = CGFloat((first?.width ?? Double(size.width)) + info.pageSpacing)
        ZStack(alignment: .topLeading) { children(here: here) }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .offset(x: -CGFloat(info.currentPage) * step + drag)
            .animation(reduceMotion ? nil : .easeInOut(duration: Double(info.transitionMs) / 1000), value: info.currentPage)
            .contentShape(Rectangle())
            // simultaneous, and ignoring mostly vertical drags, so the page still scrolls over a carousel
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        if abs(value.translation.width) > abs(value.translation.height) { drag = value.translation.width }
                    }
                    .onEnded { value in
                        let moved = -Int((value.predictedEndTranslation.width / max(step, 1)).rounded())
                        var page = info.currentPage + max(-1, min(1, moved))
                        page = info.loop ? (page + info.pageCount) % info.pageCount : max(0, min(info.pageCount - 1, page))
                        drag = 0
                        actions.model.controller.setCarouselPage(info.key, page)
                    }
            )
            .task(id: info.currentPage) {
                guard let ms = info.autoAdvanceMs, ms > 0, info.pageCount > 1 else { return }
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                if Task.isCancelled { return }
                let next = info.loop ? (info.currentPage + 1) % info.pageCount : min(info.currentPage + 1, info.pageCount - 1)
                if next != info.currentPage { actions.model.controller.setCarouselPage(info.key, next) }
            }
    }
}

/// A timeline item's connector bar, under the icon.
struct ConnectorView: View {
    let connector: RenderNode.Connector
    let rowHeight: CGFloat

    var body: some View {
        let height = max(0, rowHeight - CGFloat(connector.top) - CGFloat(connector.bottomInset))
        Rectangle()
            .fill(PaintStyle.style(connector.fill, size: CGSize(width: connector.width, height: height)))
            .frame(width: CGFloat(connector.width), height: height)
            .offset(x: CGFloat(connector.centerX - connector.width / 2), y: CGFloat(connector.top))
            .allowsHitTesting(false)
    }
}

private struct TapModifier: ViewModifier {
    let action: Action?
    let disabled: Bool
    let actions: RenderActions

    func body(content: Self.Content) -> some View {
        if let action, !disabled {
            // A button with nothing drawn inside (an empty 44 x 44 close area) has no hit area unless something fills it:
            // an almost invisible fill makes the whole frame tappable, like the web's button.
            content.background(Color.black.opacity(0.001)).contentShape(Rectangle()).onTapGesture { actions.tap(action) }
        } else {
            content
        }
    }
}

private struct SemanticsModifier: ViewModifier {
    let semantics: Semantics
    let isText: Bool
    /// A button's name when the screen gave it none: its texts. The text inside is then not a second stop for VoiceOver
    /// (since iOS 27 `.combine` no longer merges the UIKit text views into the button).
    var fallbackLabel = ""

    func body(content: Self.Content) -> some View {
        if semantics.hidden {
            content.accessibilityHidden(true)
        } else if semantics.isButton {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(semantics.label ?? fallbackLabel))
                .accessibilityAddTraits(semantics.selected == true ? [.isButton, .isSelected] : .isButton)
                .disabled(semantics.disabled) // VoiceOver says "dimmed"
        } else {
            content
        }
    }
}

/// A whole screen: background, scrolling root, pinned header and footer, sheet, busy spinner.
struct ScreenView: View {
    @ObservedObject var model: ScreenModel
    let openURL: (String) -> Void
    /// Widest the content gets (pt); the page background still fills the width, the content is centered. nil = no limit.
    var maxContentWidth: Double?
    private let measurer = TextKitMeasurer()
    @State private var now = Date()
    // Read so the screen re-renders when the user changes the text size.
    @Environment(\.sizeCategory) private var sizeCategory

    /// The Dynamic Type multiplier (1 at the default size), kept within what the layout can take.
    private var fontScale: Double {
        _ = sizeCategory
        return Self.currentFontScale
    }

    /// The same multiplier outside a view: banners, toasts and sheets measure their height with it before the screen is drawn.
    static var currentFontScale: Double {
        let system = Double(UIFontMetrics.default.scaledValue(for: 100)) / 100
        return min(max(system, 0.85), max(1, Miniwall.currentOptions.maxFontScale))
    }

    var body: some View {
        GeometryReader { proxy in
            let _ = { model.controller.fontScale = fontScale }()
            let render = model.controller.render(width: Double(proxy.size.width), height: Double(proxy.size.height), measurer: measurer,
                                                 nowMs: Int64(now.timeIntervalSince1970 * 1000))
            let actions = RenderActions(model: model, openURL: openURL)
            ZStack(alignment: .topLeading) {
                if let render {
                    screen(render, actions: actions)
                }
                if model.busy {
                    Color(UIColor.systemBackground).opacity(0.6)
                    // On its own opaque card: the spinner never sits on top of a button label or other text.
                    ProgressView()
                        .padding(16)
                        .background(Color(UIColor.systemBackground), in: RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 6)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: maxContentWidth.map { CGFloat($0) } ?? .infinity)
        .frame(maxWidth: .infinity)
        .background(backgroundFill.ignoresSafeArea())
        .task(id: model.controller.hasCountdown) {
            // A clock only for screens with a countdown.
            guard model.controller.hasCountdown else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                now = Date()
            }
        }
    }

    /// The page behind the screen, extended into the safe areas: the paywall's background, else the root stack's.
    private var backgroundFill: some View {
        GeometryReader { proxy in
            FillView(fill: model.controller.pageBackground(), shape: Rectangle(), size: proxy.size)
        }
    }

    @ViewBuilder
    private func screen(_ render: ScreenRender, actions: RenderActions) -> some View {
        let root = render.root
        let rf = render.rootFrame
        ZStack(alignment: .topLeading) {
            FillView(fill: render.background, shape: Rectangle(), size: CGSize(width: render.width, height: render.height))
            // The root stack scrolls inside its frame when its content is taller.
            ZStack(alignment: .topLeading) {
                BoxPaint(paint: root.paint, size: CGSize(width: rf.width, height: rf.height))
                ScrollView(.vertical, showsIndicators: render.contentHeight > rf.height + 0.5) {
                    ZStack(alignment: .topLeading) {
                        ForEach(root.children) { NodeView(node: $0, origin: CGPoint(x: rf.x, y: rf.y), actions: actions) }
                    }
                    .frame(width: rf.width, height: render.contentHeight, alignment: .topLeading)
                }
                .scrollDisabled(render.contentHeight <= rf.height + 0.5)
                .scrollDismissesKeyboard(.interactively)
            }
            .frame(width: rf.width, height: rf.height, alignment: .topLeading)
            .offset(x: rf.x, y: rf.y)
            if let header = render.header { NodeView(node: header, origin: .zero, actions: actions) }
            if let footer = render.footer { NodeView(node: footer, origin: .zero, actions: actions) }
            if let sheet = render.sheet {
                Color.black.opacity(0.25)
                    .frame(width: render.width, height: render.height)
                    .contentShape(Rectangle())
                    .onTapGesture { model.controller.closeSheet() }
                    .accessibilityHidden(true)
                NodeView(node: sheet, origin: .zero, actions: actions)
                    .transition(.move(edge: .bottom))
            }
        }
        .ignoresSafeArea(.keyboard)
    }
}
#endif
