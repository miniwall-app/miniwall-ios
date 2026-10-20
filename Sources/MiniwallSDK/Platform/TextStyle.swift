#if os(iOS)
import CoreText
import MiniwallCore
import UIKit

/// Resumes a continuation once, from whichever of two tasks gets there first.
private final class FirstOnly: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func resume() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

/// Fonts for texts: a downloaded custom font (`components_config.fonts[name].ios`), a font of
/// that family installed on the device, or the system font at the requested weight.
final class FontRegistry {
    static let shared = FontRegistry()
    private var registered: [String: String] = [:]
    private var failed: Set<String> = []
    private let lock = NSLock()

    /// Registers a TTF/OTF file for a font name (`Family@weight`); returns its PostScript name.
    @discardableResult
    func register(name: String, data: Data) -> Bool {
        guard let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider) else { return false }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterGraphicsFont(font, &error)
        if let postScript = font.postScriptName as String? {
            lock.lock()
            registered[name] = postScript
            lock.unlock()
            return true
        }
        return false
    }

    /// How long a screen waits for its fonts before it shows with the system font; the download goes on and serves the next screen.
    static let showWait: TimeInterval = 1.5
    /// `Miniwall.preload` runs in the background: it can wait for slow fonts.
    static let preloadWait: TimeInterval = 10

    private var inFlight: [String: Task<Void, Never>] = [:]

    /// Downloads and registers the screen's custom fonts: the link the server delivered for the name
    /// (`assets.fonts`), else `components_config.fonts[name].ios` when that is a link to a TTF/OTF (kept in the caches directory). Names that are not links (older screens)
    /// keep the system font; a font that fails to load is skipped. All fonts download at once, in the background, and the
    /// screen waits at most `wait` seconds: a slow network costs one short wait, not one per font, and the screen uses the
    /// system font for what did not arrive. A font that arrives later stays registered (and cached on disk) for the next screen.
    func load(_ paywall: JSONValue?, wait: TimeInterval = FontRegistry.showWait) async {
        guard case let .object(fonts)? = paywall?["components_config"]?["fonts"] else { return }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("miniwall/fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var tasks: [Task<Void, Never>] = []
        for (name, declaration) in fonts {
            lock.lock()
            let known = registered[name] != nil || failed.contains(name)
            lock.unlock()
            guard !known, let link = DeliveredAssets.shared.fontLink(name: name, declaration: declaration), let url = URL(string: link) else { continue }
            let file = directory.appendingPathComponent(String(format: "%08x", Self.stableHash(link)) + ".font")
            lock.lock()
            if let running = inFlight[link] {
                tasks.append(running)
            } else {
                let task = Task { [self] in
                    await download(name: name, url: url, file: file)
                    lock.lock()
                    inFlight[link] = nil
                    lock.unlock()
                }
                inFlight[link] = task
                tasks.append(task)
            }
            lock.unlock()
        }
        guard !tasks.isEmpty else { return }
        // Wait for all of them or for the time limit, whichever comes first. (A task group would wait for its slowest child
        // before returning, whatever the limit; the downloads are not cancelled with this wait either.)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let first = FirstOnly(continuation)
            Task { for task in tasks { await task.value }; first.resume() }
            Task { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)); first.resume() }
        }
    }

    private func download(name: String, url: URL, file: URL) async {
        let data: Data?
        if let cached = try? Data(contentsOf: file) {
            data = cached
        } else if case .data(let fetched) = await LimitedDownload.fetch(URLRequest(url: url, timeoutInterval: 6), max: DownloadLimits.maxFontBytes, configuration: URLSession.shared.configuration) {
            // Read in chunks with a size limit: refused on a larger Content-Length, cancelled once the bytes pass the limit.
            try? fetched.write(to: file, options: .atomic)
            data = fetched
        } else {
            NSLog("Miniwall: font %@ not loaded (failed or larger than %lld bytes)", name, DownloadLimits.maxFontBytes)
            data = nil
        }
        if let data, register(name: name, data: data) { return }
        try? FileManager.default.removeItem(at: file)
        lock.lock()
        failed.insert(name)
        lock.unlock()
    }

    func postScriptName(for name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return registered[name]
    }

    private static func weight(_ w: Int) -> UIFont.Weight {
        switch w {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }

    /// The font for a spec and a run's style (bold, italic, code).
    func font(_ spec: FontSpec, bold: Bool = false, italic: Bool = false, code: Bool = false) -> UIFont {
        let size = CGFloat(spec.size)
        // <b> in the web's markdown is font-weight: bold (700), at least the text's own weight.
        let weightValue = bold ? max(spec.weight, 700) : spec.weight
        var font: UIFont
        if code {
            font = .monospacedSystemFont(ofSize: size, weight: Self.weight(weightValue))
        } else if let name = spec.name, let ps = postScriptName(for: name), let custom = UIFont(name: ps, size: size) {
            font = Self.styled(custom, weight: weightValue)
        } else if let family = spec.family, let installed = Self.installed(family: family, weight: weightValue, size: size) {
            font = installed
        } else {
            font = .systemFont(ofSize: size, weight: Self.weight(weightValue))
        }
        if italic, let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return font
    }

    /// FNV-1a, so a font keeps its cache file name across launches (`hashValue` changes every run).
    private static func stableHash(_ s: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for byte in s.utf8 { h = (h ^ UInt32(byte)) &* 16_777_619 }
        return h
    }

    private static let weightAxisTag = 2_003_265_652 // the 'wght' axis tag

    /// Whether the font is variable along weight. A static TTF has no variation axes (nil or empty).
    private static func hasWeightAxis(_ font: UIFont) -> Bool {
        guard let axes = CTFontCopyVariationAxes(font as CTFont) as? [[String: Any]], !axes.isEmpty else { return false }
        return axes.contains { ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue == weightAxisTag }
    }

    /// A custom font at a weight. A variable font moves along its `wght` axis. A static font cannot, so a bold
    /// request (600 and up) asks for the family's bold face through the `bold` trait; a family without one keeps its weight.
    private static func styled(_ font: UIFont, weight: Int) -> UIFont {
        if hasWeightAxis(font) { return withWeight(font, weight) }
        let traits = font.fontDescriptor.symbolicTraits
        guard weight >= 600, !traits.contains(.traitBold),
              let descriptor = font.fontDescriptor.withSymbolicTraits(traits.union(.traitBold)) else { return font }
        let bold = UIFont(descriptor: descriptor, size: font.pointSize)
        return bold.fontDescriptor.symbolicTraits.contains(.traitBold) ? bold : font
    }

    /// A variable font's `wght` axis set to the weight.
    private static func withWeight(_ font: UIFont, _ weight: Int) -> UIFont {
        let key = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        return UIFont(descriptor: font.fontDescriptor.addingAttributes([key: [weightAxisTag: Double(weight)]]), size: font.pointSize)
    }

    private static func installed(family: String, weight: Int, size: CGFloat) -> UIFont? {
        guard !UIFont.fontNames(forFamilyName: family).isEmpty else { return nil }
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [UIFontDescriptor.TraitKey.weight: Self.weight(weight).rawValue],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
}

enum TextStyle {
    static func uiColor(_ c: Rgba) -> UIColor {
        UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    static func alignment(_ a: TextAlign) -> NSTextAlignment {
        switch a {
        case .start: return .natural
        case .center: return .center
        case .end: return UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft ? .left : .right
        }
    }

    /// The text as TextKit lays it out: every line exactly 1.5 x the font size (CSS `line-height: 1.5`),
    /// glyphs centered in the line like CSS half-leading.
    static func attributed(_ runs: [TextLogic.Run], font spec: FontSpec, color: UIColor = .black, align: TextAlign = .start) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lineHeight = CGFloat(spec.lineHeight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.alignment = alignment(align)
        paragraph.lineBreakMode = .byWordWrapping
        for run in runs {
            let font = FontRegistry.shared.font(spec, bold: run.bold, italic: run.italic, code: run.code)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
                // TextKit puts the glyphs at the bottom of a tall line; CSS centers them.
                .baselineOffset: (lineHeight - font.lineHeight) / 4,
            ]
            if run.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, let url = URL(string: link) { attrs[.link] = url }
            out.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        return out
    }
}

/// Measures with TextKit, the same engine ``TextLabel`` draws with.
struct TextKitMeasurer: TextMeasurer {
    func measure(_ runs: [TextLogic.Run], font: FontSpec, maxWidth: Double?) -> (width: Double, height: Double) {
        let text = TextStyle.attributed(runs, font: font)
        let width = maxWidth.map { CGFloat($0) } ?? .greatestFiniteMagnitude
        let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
        return (Double(ceil(rect.width)), Double(ceil(rect.height / CGFloat(font.lineHeight) - 0.01) * CGFloat(font.lineHeight)))
    }
}
#endif
