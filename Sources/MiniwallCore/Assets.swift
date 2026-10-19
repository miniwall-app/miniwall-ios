import Foundation

/// `assets` of a delivery body (MOBILE-SDK-PLAN S12): SVG markup per icon (`lucide/x`) and a TTF link per
/// `font_name` (`Inter@600`), so a phone does not call api.iconify.design or trust the links saved in the
/// screen. Older servers send none; every lookup then falls back to the node's own link. Port of `Assets.kt`.
public struct DeliveryAssets: Equatable {
    public var icons: [String: String]
    public var fonts: [String: String]

    public init(icons: [String: String] = [:], fonts: [String: String] = [:]) {
        self.icons = icons
        self.fonts = fonts
    }

    public static func + (a: DeliveryAssets, b: DeliveryAssets) -> DeliveryAssets {
        DeliveryAssets(icons: a.icons.merging(b.icons) { $1 }, fonts: a.fonts.merging(b.fonts) { $1 })
    }
}

/// Size limits of downloads (images and fonts come from links in the screen, so a bad link must not fill memory).
/// A download whose `Content-Length` is larger is refused before the body is read; one without a length (or lying
/// about it) is aborted as soon as the bytes read pass the limit. Port of `DownloadLimits` in `Assets.kt`.
public enum DownloadLimits {
    public static let maxImageBytes: Int64 = 10 * 1024 * 1024
    public static let maxFontBytes: Int64 = 5 * 1024 * 1024

    /// True when a declared `Content-Length` (-1 = unknown) is already over `max`.
    public static func declaredTooLarge(_ contentLength: Int64, max: Int64) -> Bool { contentLength > max }

    /// The bytes of `bytes`, or nil when `contentLength` declares more than `max` or the sequence holds more than `max`
    /// (reading stops at max + 1 bytes, so nothing larger than the limit is ever buffered).
    public static func readLimited<S: AsyncSequence>(_ bytes: S, max: Int64, contentLength: Int64 = -1) async throws -> Data?
    where S.Element == UInt8 {
        if declaredTooLarge(contentLength, max: max) { return nil }
        var out = Data()
        if contentLength > 0 && contentLength <= max { out.reserveCapacity(Int(contentLength)) }
        var total: Int64 = 0
        for try await byte in bytes {
            total += 1
            if total > max { return nil }
            out.append(byte)
        }
        return out
    }
}

/// Accumulates the chunks of a download and refuses to hold more than `max` bytes. The chunk that would pass the
/// limit is not stored, so memory never exceeds `max` plus the one chunk in flight. The pure part of the chunked
/// download in the SDK target (`LimitedDownload`); `readLimited` above is the same rule for an async byte sequence.
public struct LimitedBuffer {
    public let max: Int64
    public private(set) var data = Data()
    public private(set) var exceeded = false

    /// `expectedLength` is the `Content-Length` (-1 = unknown); a plausible one is reserved up front.
    public init(max: Int64, expectedLength: Int64 = -1) {
        self.max = max
        if expectedLength > 0 && expectedLength <= max { data.reserveCapacity(Int(expectedLength)) }
    }

    public var count: Int64 { Int64(data.count) }

    /// Adds a chunk. False (and `exceeded` stays true from then on) when the total would pass `max`.
    @discardableResult
    public mutating func append(_ chunk: Data) -> Bool {
        if exceeded { return false }
        if count + Int64(chunk.count) > max {
            exceeded = true
            return false
        }
        data.append(chunk)
        return true
    }
}

public enum Assets {
    /// An icon file in a path-style URL: `https://api.iconify.design/lucide/x.svg` -> `lucide/x`; an uploaded icon is served by the API at
    /// `https://api.miniwall.app/v1/sdk/icons/custom/<id>.svg` -> `custom/<id>`.
    private static let iconURL = try! NSRegularExpression(pattern: "^https?://[^/?#]+(?:/v1/sdk/icons)?/([a-z0-9-]+)/([a-z0-9-]+)\\.svg(?:[?#].*)?$")

    /// The name the server files an icon under, or nil for a link that is not a `set/name.svg` file.
    public static func iconKey(_ url: String) -> String? {
        let ns = url as NSString
        guard let m = iconURL.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges == 3 else { return nil }
        return "\(ns.substring(with: m.range(at: 1)))/\(ns.substring(with: m.range(at: 2)))"
    }

    /// Assets of a body and of everything nested in it that ships its own (an A/B side in `experiment.b`,
    /// each audience's screen in `rules[].paywall`), since each of those is a full delivery body.
    public static func of(_ body: JSONValue?) -> DeliveryAssets {
        guard let body, body.isObject else { return DeliveryAssets() }
        var own = DeliveryAssets()
        if let a = body.obj("assets") { own = DeliveryAssets(icons: strings(a["icons"]), fonts: strings(a["fonts"])) }
        var sides: [JSONValue] = []
        if let b = body.obj("experiment")?.obj("b") { sides.append(b) }
        for rule in body.arr("rules") ?? [] { if let p = rule.obj("paywall") { sides.append(p) } }
        return sides.reduce(own) { $0 + Assets.of($1) }
    }

    private static func strings(_ value: JSONValue?) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in value?.objectValue ?? [:] { if let s = v.stringValue { out[k] = s } }
        return out
    }

    private static func isFontLink(_ url: String) -> Bool {
        guard url.hasPrefix("https://") else { return false }
        let path = (url.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url).lowercased()
        return path.hasSuffix(".ttf") || path.hasSuffix(".otf")
    }

    /// Where to get the font file for `name`: the server's link first, else the one saved in the screen
    /// (`fonts[name].<platform>`: `ios` or `android`). Nil for a system font or a link that is not a TTF/OTF over https.
    public static func fontLink(name: String, declaration: JSONValue?, platform: String, assets: DeliveryAssets) -> String? {
        [assets.fonts[name], declaration?.str(platform)].compactMap { $0 }.first(where: isFontLink)
    }
}

/// Facts the SDK reads from the device for audiences (docs/specs/targeting.md, mobile section). Port of `AutoAttributes` in `Assets.kt`.
public enum AutoAttributes {
    /// Region of a locale (`vi-VN`, `vi_VN`, `zh-Hans-CN`, `es-419`), upper case; nil when the locale has none. Never from an IP.
    public static func country(_ locale: String?) -> String? {
        guard let locale else { return nil }
        for part in locale.split(whereSeparator: { $0 == "-" || $0 == "_" }).dropFirst() {
            let n = part.utf16.count
            if n == 1 { return nil } // extension or private use: nothing region-like after it
            let scalars = part.unicodeScalars
            if n == 2, scalars.allSatisfy({ ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }) { return part.uppercased() }
            if n == 3, scalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) { return String(part) }
        }
        return nil
    }

    /// Major version of the OS (`17.4.1` -> `17`, `14` -> `14`), so `gte 16` compares as a number like on the web.
    public static func osVersion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(while: { $0.value >= 48 && $0.value <= 57 }).map { Character($0) })
        return digits.isEmpty ? nil : digits
    }

    /// The app's own version name as the store shows it (`2.3.1`); blank is none.
    public static func appVersion(_ raw: String?) -> String? {
        // Events carry it as an analytics label (letters, digits, . + _ -, up to 32): others become `-`.
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        let allowed = Set(".+_-".unicodeScalars)
        let cleaned = String(String.UnicodeScalarView(t.unicodeScalars.prefix(32).map { u -> Unicode.Scalar in
            let ok = (u.value >= 48 && u.value <= 57) || (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122) || allowed.contains(u)
            return ok ? u : "-"
        }))
        guard let first = cleaned.unicodeScalars.first, (first.value >= 48 && first.value <= 57) || (first.value >= 65 && first.value <= 90) || (first.value >= 97 && first.value <= 122) else { return nil }
        return cleaned
    }
}
