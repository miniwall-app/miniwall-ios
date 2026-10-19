import Foundation

/// ISO 8601 timestamps with one set of rules on every platform (mirrors `IsoTime.kt`): always UTC with
/// milliseconds when written, like JavaScript's `toISOString()`: `2026-10-10T12:00:00.123Z`.
public enum IsoTime {
    public static func format(_ epochMs: Int64) -> String {
        let days = floorDiv(epochMs, 86_400_000)
        let inDay = epochMs - days * 86_400_000
        // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        let h = inDay / 3_600_000
        let m = inDay / 60_000 % 60
        let s = inDay / 1_000 % 60
        let ms = inDay % 1_000
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", Int(year), Int(month), Int(day), Int(h), Int(m), Int(s), Int(ms))
    }

    private static let pattern = TextLogic.regex(#"^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)?)?$"#)

    /// Epoch milliseconds of an ISO 8601 date or date-time, read like JavaScript's `new Date(text)`: a date alone and a
    /// date-time with `Z` or `±hh:mm` are exact; a date-time with no offset is in the device's time zone
    /// (`offsetMsAt` gives that zone's offset at a moment). Nil when it is not an ISO date.
    public static func parse(_ text: String, offsetMsAt: (Int64) -> Int64 = { Int64(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: Double($0) / 1000))) * 1000 }) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        guard let match = pattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String {
            let r = match.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        guard let year = Int64(group(1)), let month = Int64(group(2)), let day = Int64(group(3)) else { return nil }
        let hasTime = !group(4).isEmpty
        let hour = hasTime ? Int64(group(4)) ?? 0 : 0
        let minute = hasTime ? Int64(group(5)) ?? 0 : 0
        let second = Int64(group(6)) ?? 0
        guard (1...12).contains(month), day >= 1, day <= daysIn(year, month), hour <= 23, minute <= 59, second <= 59 else { return nil }
        let fraction = group(7)
        let ms = fraction.isEmpty ? 0 : Int64(String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let asUtc = days * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1_000 + ms
        let zone = group(8)
        if !hasTime { return asUtc } // a date alone is UTC midnight
        if zone.isEmpty { return asUtc - offsetMsAt(asUtc) } // no offset: the device's own zone
        if zone.hasPrefix("Z") || zone.hasPrefix("z") { return asUtc }
        let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
        let minutes = (Int64(digits.prefix(2)) ?? 0) * 60 + (Int64(digits.dropFirst(2)) ?? 0)
        return asUtc - minutes * 60_000 * (zone.hasPrefix("-") ? -1 : 1)
    }

    private static func daysIn(_ year: Int64, _ month: Int64) -> Int64 {
        switch month {
        case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}
