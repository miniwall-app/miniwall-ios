#if os(iOS)
import AVFoundation
import MiniwallCore
import SwiftUI
import UIKit

/// A text drawn by TextKit with the attributes ``TextKitMeasurer`` measured, so it fits its frame
/// exactly. Links are tappable (they go through the screen's URL handling).
struct TextLabel: UIViewRepresentable {
    let content: TextContent
    let openURL: (String) -> Void

    private var hasLinks: Bool { content.runs.contains { $0.link != nil } }

    func makeUIView(context: Context) -> UIView {
        let view = makeView(context: context)
        // The frame comes from the layout engine; never let intrinsic sizes fight it.
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            view.setContentHuggingPriority(.defaultLow, for: axis)
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        return view
    }

    private func makeView(context: Context) -> UIView {
        if hasLinks {
            let view = UITextView()
            view.isEditable = false
            view.isScrollEnabled = false
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.delegate = context.coordinator
            view.linkTextAttributes = [:]
            return view
        }
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.openURL = openURL
        let color: UIColor = content.color.approximateColor.map(TextStyle.uiColor) ?? .black
        let text = TextStyle.attributed(content.runs, font: content.font, color: color, align: content.align)
        // What VoiceOver (and UI tests) read is the plain text. Left to UIKit it is the attributed text, whose custom font is
        // registered for this process only: the accessibility runtime rebuilding that font crashed the app
        // (EXC_BAD_ACCESS in CreateFontWithFontURL) on a screen with a downloaded font.
        let plain = content.runs.map(\.text).joined()
        if let label = view as? UILabel {
            label.attributedText = text
            label.accessibilityLabel = plain
        } else if let textView = view as? UITextView {
            textView.attributedText = text
            textView.accessibilityValue = plain
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: (String) -> Void
        init(openURL: @escaping (String) -> Void) { self.openURL = openURL }

        func textView(_ textView: UITextView, shouldInteractWith url: URL, in range: NSRange, interaction: UITextItemInteraction) -> Bool {
            openURL(url.absoluteString)
            return false
        }
    }
}

/// Text in its frame; gradient text colors are painted through the glyphs like `background-clip: text`.
struct TextNodeView: View {
    let content: TextContent
    let size: CGSize
    let openURL: (String) -> Void

    var body: some View {
        switch content.color {
        case .linear, .radial:
            Rectangle().fill(PaintStyle.style(content.color, size: size))
                .mask(label)
        default:
            label
        }
    }

    /// The label gets a little more height than the layout's frame. SwiftUI rounds a frame down to the pixel grid
    /// (134.4 pt becomes 134.33 pt on a 3x screen) and a UILabel or UITextView leaves out a last line that does not
    /// fit whole: two lines of 67.2 pt lost their second line. The frame the layout reserved stays the same.
    private var label: some View {
        TextLabel(content: content, openURL: openURL)
            .frame(width: size.width, height: size.height + 2, alignment: .topLeading)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// An icon: SVG files are drawn as paths in the icon color, raster files are used as a mask
/// (CSS mask-image, contain, centered).
struct IconView: View {
    let url: String
    let color: Fill?
    let size: CGSize

    var body: some View {
        Group {
            if url.split(separator: "?").first?.lowercased().hasSuffix(".svg") == true {
                SvgIconView(url: url, color: color, size: size)
            } else {
                RemoteImage(url: url) { image in
                    Rectangle()
                        .fill(PaintStyle.style(color ?? .solid(.black), size: size))
                        .mask(Image(uiImage: image).resizable().scaledToFit())
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Draws the icon's shapes scaled to fit the frame, centered (CSS `contain`).
struct SvgIconView: View {
    let url: String
    let color: Fill?
    let size: CGSize
    /// The icon last loaded and the link it was loaded for: a state's icon must never outlive a link change
    /// (a selected package swaps its icon file through an override).
    @State private var loaded: (url: String, icon: SvgIcon)?

    var body: some View {
        ZStack {
            if let icon = URL(string: url).flatMap(IconLoader.shared.cached) ?? loaded.flatMap({ $0.url == url ? $0.icon : nil }) {
                let scale = min(size.width / icon.width, size.height / icon.height)
                let style = PaintStyle.style(color ?? .solid(.black), size: size)
                ForEach(Array(icon.shapes.enumerated()), id: \.offset) { item in
                    let shape = item.element
                    let path = SvgShapePath(icon: icon, shape: shape)
                    ZStack {
                        if shape.fill { path.fill(style, style: FillStyle(eoFill: shape.evenOdd)) }
                        if shape.stroke {
                            path.stroke(style, style: StrokeStyle(lineWidth: shape.strokeWidth * scale, lineCap: shape.roundCap ? .round : .butt, lineJoin: shape.roundJoin ? .round : .miter))
                        }
                    }
                }
            }
        }
        // Runs again whenever the link changes (a selected option swaps its icon file through an override).
        .task(id: url) {
            guard let u = URL(string: url) else { return }
            let requested = url
            let icon = await withCheckedContinuation { continuation in IconLoader.shared.load(u) { continuation.resume(returning: $0) } }
            loaded = icon.map { (requested, $0) }
        }
    }
}

struct SvgShapePath: Shape {
    let icon: SvgIcon
    let shape: SvgShape

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / icon.width, rect.height / icon.height)
        let dx = rect.minX + (rect.width - icon.width * scale) / 2 - icon.minX * scale
        let dy = rect.minY + (rect.height - icon.height * scale) / 2 - icon.minY * scale
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: dx + x * scale, y: dy + y * scale) }
        var path = Path()
        for op in shape.ops {
            switch op {
            case let .move(x, y): path.move(to: p(x, y))
            case let .line(x, y): path.addLine(to: p(x, y))
            case let .cubic(x1, y1, x2, y2, x, y): path.addCurve(to: p(x, y), control1: p(x1, y1), control2: p(x2, y2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

struct ImageNodeView: View {
    let content: ImageContent
    let size: CGSize

    var body: some View {
        let shape = MaskShape(mask: content.mask)
        ZStack {
            RemoteImage(url: content.url) { image in
                if content.cover {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
            .frame(width: size.width, height: size.height)
            if let overlay = content.overlay { Rectangle().fill(PaintStyle.style(overlay, size: size)) }
            if content.borderWidth > 0, let border = content.borderFill {
                // The web strokes the mask path twice as wide, inside the clip: the visible border is `width`.
                shape.stroke(PaintStyle.style(border, size: size), lineWidth: CGFloat(content.borderWidth * 2))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .shadow(color: content.shadow?.color.color ?? .clear, radius: CGFloat((content.shadow?.radius ?? 0) / 2),
                x: CGFloat(content.shadow?.x ?? 0), y: CGFloat(content.shadow?.y ?? 0))
    }
}

/// The tab switch: 51 x 31 track, 27pt thumb (as in the web renderer).
struct ToggleView: View {
    let on: Bool
    let track: Fill?
    let thumb: Fill?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Capsule().fill(PaintStyle.style(track ?? .solid(Rgba(0.8, 0.8, 0.8)), size: CGSize(width: 51, height: 31)))
            Circle()
                .fill(PaintStyle.style(thumb ?? .solid(Rgba(1, 1, 1)), size: CGSize(width: 27, height: 27)))
                .frame(width: 27, height: 27)
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                .offset(x: on ? 22 : 2, y: 2)
        }
        .frame(width: 51, height: 31)
        .animation(.easeOut(duration: 0.3), value: on)
    }
}

/// A looping, muted-by-default video (AVPlayer), clipped like images.
struct VideoNodeView: UIViewRepresentable {
    let content: VideoContent

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var looper: AVPlayerLooper?
        var url: String?
    }

    func makeUIView(context: Context) -> PlayerView { PlayerView() }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.playerLayer.videoGravity = content.cover ? .resizeAspectFill : .resizeAspect
        guard view.url != content.url, let url = URL(string: content.url) else { return }
        view.url = content.url
        let player = AVQueuePlayer()
        player.isMuted = content.muted
        if content.loop {
            view.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        } else {
            player.insert(AVPlayerItem(url: url), after: nil)
        }
        view.playerLayer.player = player
        if content.autoPlay { player.play() }
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.playerLayer.player?.pause()
        view.looper = nil
    }
}

/// A question's text field (as in the web renderer): keyboard type, capitalization, validity per type.
struct TextFieldView: UIViewRepresentable {
    let content: TextFieldContent
    let onChange: (String, Bool) -> Void
    let onFocus: (Bool, String, Bool) -> Void

    static func isValid(_ value: String, keyboard: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return true }
        switch keyboard {
        case "email": return v.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
        case "url": return URL(string: v)?.scheme != nil
        case "numeric", "decimal": return Double(v) != nil
        default: return true
        }
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != content.value, !field.isFirstResponder { field.text = content.value }
        field.font = FontRegistry.shared.font(content.font)
        field.textColor = content.color.approximateColor.map(TextStyle.uiColor) ?? .black
        field.textAlignment = TextStyle.alignment(content.align)
        let placeholderParagraph = NSMutableParagraphStyle()
        placeholderParagraph.alignment = TextStyle.alignment(content.placeholderAlign)
        field.attributedPlaceholder = NSAttributedString(string: content.placeholder, attributes: [
            .font: FontRegistry.shared.font(content.placeholderFont),
            .foregroundColor: content.placeholderColor.approximateColor.map(TextStyle.uiColor) ?? UIColor.placeholderText,
            .paragraphStyle: placeholderParagraph,
        ])
        field.accessibilityLabel = content.placeholder.isEmpty ? content.fieldId : content.placeholder
        switch content.keyboard {
        case "email": field.keyboardType = .emailAddress; field.textContentType = .emailAddress; field.autocorrectionType = .no
        case "numeric": field.keyboardType = .numberPad
        case "decimal": field.keyboardType = .decimalPad
        case "tel": field.keyboardType = .phonePad; field.textContentType = .telephoneNumber
        case "url": field.keyboardType = .URL; field.autocorrectionType = .no
        default: field.keyboardType = .default
        }
        switch content.capitalize {
        case "sentences": field.autocapitalizationType = .sentences
        case "words": field.autocapitalizationType = .words
        case "characters": field.autocapitalizationType = .allCharacters
        default: field.autocapitalizationType = .none
        }
        field.returnKeyType = .done
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TextFieldView
        init(parent: TextFieldView) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            let value = field.text ?? ""
            parent.onChange(value, TextFieldView.isValid(value, keyboard: parent.content.keyboard))
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            parent.onFocus(true, field.text ?? "", true)
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            let value = field.text ?? ""
            parent.onFocus(false, value, TextFieldView.isValid(value, keyboard: parent.content.keyboard))
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
    }
}
#endif
