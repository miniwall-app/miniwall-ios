import Foundation

/// Text helpers ported from the web renderer. Each function matches its web source exactly;
/// the shared conformance suite holds the cases both must agree on. Mirrors `TextLogic.kt`.
public enum TextLogic {
    // MARK: Regex helpers (NSRegularExpression works on UTF-16, like JavaScript)

    static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are constants; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    /// Replaces every match of `re` in `s` with `transform(groups)` (group 0 = whole match; nil = group did not take part).
    static func replace(_ re: NSRegularExpression, in s: String, _ transform: ([String?]) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups: [String?] = (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            out += transform(groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func contains(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    // MARK: Variables (the web renderer)

    private static let template = regex(#"\{\{\s*([$a-zA-Z0-9._-]+)(?:\s*\|\s*([^}]*))?\s*\}\}"#)
    private static let customPrefix = regex(#"^\$?custom\."#)
    private static let letters = regex(#"\p{L}+"#)

    /// `{{ name }}` / `{{ name | uppercase }}` substitution. Unknown names become empty; unknown modifiers are ignored.
    public static func replaceVariables(_ text: String?, _ variables: [String: String]) -> String {
        guard let text, !text.isEmpty else { return "" }
        return replace(template, in: text) { g in
            let name = replace(customPrefix, in: (g[1] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) { _ in "" }
            guard let value = variables[name] else { return "" }
            guard let modifier = g[2]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return value }
            switch modifier {
            case "uppercase": return value.uppercased()
            case "lowercase": return value.lowercased()
            case "capitalize":
                return replace(letters, in: value) { w in
                    let word = w[0] ?? ""
                    return word.prefix(1).uppercased() + word.dropFirst().lowercased()
                }
            default: return value
            }
        }
    }

    // MARK: Markdown (the web renderer)

    private static func escapeHTML(_ text: String) -> String {
        var out = ""
        // Scalars, not Characters: a combining mark after `<` would make "<" + mark one Character and skip the escape (JS and Kotlin work on UTF-16 units).
        for c in text.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    private static let safeScheme = regex("^(https?:|mailto:|tel:)")
    private static let relative = regex("^[/#?]")
    private static let anyScheme = regex("^[a-z][a-z0-9+.-]*:")

    /// Characters a browser ignores in a URL scheme: code <= 32 and 127.
    static func stripControl(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value > 32 && $0.value != 127 }))
    }

    static func isSafeHref(_ href: String) -> Bool {
        let plain = stripControl(href.replacingOccurrences(of: "&amp;", with: "&")).lowercased()
        return contains(safeScheme, plain) || contains(relative, plain) || !contains(anyScheme, plain)
    }

    private static let newLine = regex(#"\\\n"#)
    private static let bold = regex(#"\*\*(.*?)\*\*"#)
    private static let italic = regex(#"\*(.*?)\*"#)
    private static let strike = regex("~(.*?)~")
    private static let code = regex("`(.*?)`")
    private static let link = regex(#"\[(.*?)\]\((.*?)\)"#)
    static let codeOpen = "<span style='font-family: monospace'>"

    /// The small markdown subset as HTML, after escaping (same output as the web, tag for tag).
    public static func htmlFromMarkdown(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        var s = escapeHTML(text)
        s = replace(newLine, in: s) { _ in "<br/>" }
        s = replace(bold, in: s) { "<b>\($0[1] ?? "")</b>" }
        s = replace(italic, in: s) { "<i>\($0[1] ?? "")</i>" }
        s = replace(strike, in: s) { "<s>\($0[1] ?? "")</s>" }
        s = replace(code, in: s) { "\(codeOpen)\($0[1] ?? "")</span>" }
        s = replace(link, in: s) { g in
            let label = g[1] ?? ""
            let href = g[2] ?? ""
            return isSafeHref(href)
                ? "<a href=\"\(href)\" target='_blank' rel='noopener noreferrer' style='color:inherit;text-decoration:none;'>\(label)</a>"
                : label
        }
        return s
    }

    /// One styled piece of a text, ready for an AttributedString.
    public struct Run: Equatable, Sendable {
        public var text: String
        public var bold = false
        public var italic = false
        public var strikethrough = false
        public var code = false
        /// Unescaped link target, when the run is inside a link.
        public var link: String?

        public init(text: String, bold: Bool = false, italic: Bool = false, strikethrough: Bool = false, code: Bool = false, link: String? = nil) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.strikethrough = strikethrough
            self.code = code
            self.link = link
        }
    }

    private static let hrefPattern = regex(#"^<a href="([^"]*)""#)

    /// The runs of `htmlFromMarkdown`'s output, with HTML whitespace rules (runs of spaces and
    /// newlines collapse to one space) and `<br/>` as a line break.
    public static func runs(_ markdown: String?) -> [Run] {
        let html = htmlFromMarkdown(markdown)
        var out: [Run] = []
        var b = 0, i = 0, s = 0, c = 0
        var href: String?
        var text = ""
        func flush() {
            guard !text.isEmpty else { return }
            out.append(Run(text: decodeEntities(text), bold: b > 0, italic: i > 0, strikethrough: s > 0, code: c > 0, link: href))
            text = ""
        }
        let scalars = html.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let ch = scalars[index]
            guard ch == "<", let end = scalars[index...].firstIndex(of: ">") else {
                text.unicodeScalars.append(ch)
                index = scalars.index(after: index)
                continue
            }
            let tag = String(scalars[index...end])
            flush()
            switch tag {
            case "<br/>": out.append(Run(text: "\n", bold: b > 0, italic: i > 0, strikethrough: s > 0, code: c > 0, link: href))
            case "<b>": b += 1
            case "</b>": b = max(0, b - 1)
            case "<i>": i += 1
            case "</i>": i = max(0, i - 1)
            case "<s>": s += 1
            case "</s>": s = max(0, s - 1)
            case codeOpen: c += 1
            case "</span>": c = max(0, c - 1)
            case "</a>": href = nil
            default:
                if tag.hasPrefix("<a "), let m = hrefPattern.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) {
                    href = decodeEntities((tag as NSString).substring(with: m.range(at: 1)))
                }
            }
            index = scalars.index(after: end)
        }
        flush()
        return collapseWhitespace(out)
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static let whitespace = regex("[ \\t\\n\\r\\f]+")

    /// `white-space: normal`: collapse runs of whitespace, drop it at line starts and ends.
    private static func collapseWhitespace(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        var atLineStart = true
        func trimLastEnd() {
            guard var last = out.popLast() else { return }
            while last.text.hasSuffix(" ") { last.text.removeLast() }
            out.append(last)
        }
        for run in runs {
            if run.text == "\n" {
                trimLastEnd()
                out.append(run)
                atLineStart = true
                continue
            }
            var t = replace(whitespace, in: run.text) { _ in " " }
            if atLineStart || (out.last?.text.hasSuffix(" ") ?? false) {
                while t.hasPrefix(" ") { t.removeFirst() }
            }
            if t.isEmpty { continue }
            var copy = run
            copy.text = t
            out.append(copy)
            atLineStart = false
        }
        trimLastEnd()
        return out.filter { !$0.text.isEmpty }
    }

    // MARK: URLs and fonts (sdks/web/src/url.ts, fonts.ts)

    private static let openable = regex("^(https?:|mailto:|tel:)")
    private static let rootPath = regex("^/(?!/)")

    /// Links a paywall may open: http(s), mailto, tel and site-relative paths. Never `javascript:` or `data:`.
    public static func isOpenableURL(_ url: String) -> Bool {
        let plain = stripControl(url).lowercased()
        return contains(openable, plain) || contains(rootPath, plain)
    }

    private static let fontName = regex(#"^(?:[A-Z]+:)?(.+)@([0-9]{3})$"#)

    /// `Fraunces@700` -> ("Fraunces", 700); anything else -> nil.
    public static func parseFontName(_ name: String) -> (family: String, weight: Int)? {
        let ns = name as NSString
        guard let m = fontName.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: m.range(at: 1)), Int(ns.substring(with: m.range(at: 2))) ?? 400)
    }
}
