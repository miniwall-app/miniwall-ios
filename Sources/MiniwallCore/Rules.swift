import Foundation

/// What a package offers, for `intro_offer` / `promo_offer` overrides and conditions.
public struct PackageInfo: Equatable, Sendable {
    public var hasIntroOffer: Bool
    public var hasTrial: Bool
    public var hasPromoOffer: Bool

    public init(hasIntroOffer: Bool = false, hasTrial: Bool = false, hasPromoOffer: Bool = false) {
        self.hasIntroOffer = hasIntroOffer
        self.hasTrial = hasTrial
        self.hasPromoOffer = hasPromoOffer
    }
}

/// Overrides and visibility conditions (the web renderer).
public enum Overrides {
    public struct State: Equatable {
        public var selected = false
        public var introOffer = false
        public var promoOffer = false
        public var focus = false
        public var error = false

        public init(selected: Bool = false, introOffer: Bool = false, promoOffer: Bool = false, focus: Bool = false, error: Bool = false) {
            self.selected = selected
            self.introOffer = introOffer
            self.promoOffer = promoOffer
            self.focus = focus
            self.error = error
        }
    }

    private static func conditionTypes(_ o: JSONValue) -> [String?] {
        (o.arr("conditions") ?? []).map { $0.str("type") }
    }

    /// The node with matching overrides merged in, in the web's order: selected, intro_offer, promo_offer, focus, error.
    public static func apply(_ node: JSONValue, _ state: State) -> JSONValue {
        guard let overrides = node.arr("overrides"), case var .object(merged) = node else { return node }
        func mergeFirst(_ type: String, _ on: Bool) {
            guard on, let o = overrides.first(where: { conditionTypes($0).contains(type) }), let props = o.obj("properties")?.objectValue else { return }
            for (k, v) in props { merged[k] = v }
        }
        mergeFirst("selected", state.selected)
        mergeFirst("intro_offer", state.introOffer)
        mergeFirst("promo_offer", state.promoOffer)
        mergeFirst("focus", state.focus)
        mergeFirst("error", state.error)
        return .object(merged)
    }

    private static let visibilityTypes: Set<String> = ["selected_package_condition", "intro_offer_condition", "promo_offer_condition", "variable_condition"]
    private static let order = ["intro_offer_condition", "promo_offer_condition", "selected_package_condition", "variable_condition"]

    /// The first override made only of visibility conditions decides (all must hold); otherwise `visible` (default true).
    public static func isVisible(
        _ overrides: JSONValue?,
        baseVisible: Bool?,
        selectedPackageId: String?,
        packageInfo: PackageInfo?,
        variables: [String: String]
    ) -> Bool {
        let rule = overrides?.arrayValue?.first { o in
            guard let conditions = o.arr("conditions") else { return false }
            return conditions.allSatisfy { visibilityTypes.contains($0.str("type") ?? "") }
        }
        guard let rule else { return baseVisible ?? true }
        let conditions = (rule.arr("conditions") ?? []).filter(\.isObject).sorted {
            (order.firstIndex(of: $0.str("type") ?? "") ?? -1) < (order.firstIndex(of: $1.str("type") ?? "") ?? -1)
        }
        return conditions.allSatisfy { c in
            let op = c.str("operator")
            switch c.str("type") {
            case "intro_offer_condition":
                let has = packageInfo?.hasIntroOffer == true || packageInfo?.hasTrial == true
                let value = c.bool("value")
                return op == "=" ? has == value : op == "!=" ? has != value : false
            case "promo_offer_condition":
                let has = packageInfo?.hasPromoOffer == true
                let value = c.bool("value")
                return op == "=" ? has == value : op == "!=" ? has != value : false
            case "selected_package_condition":
                let packages = (c.arr("packages") ?? []).compactMap(\.stringValue)
                let selected = selectedPackageId ?? ""
                return op == "in" ? packages.contains(selected) : op == "not in" ? !packages.contains(selected) : false
            case "variable_condition":
                let current = variables[c.str("variable") ?? ""]
                let expected = jsString(c.obj("value")?["value"])
                return op == "=" ? current == expected : op == "!=" ? current != expected : false
            default:
                return false
            }
        }
    }
}

/// `String(value)` as JavaScript prints it (numbers without a trailing `.0`).
func jsString(_ v: JSONValue?) -> String {
    switch v {
    case nil: return "undefined"
    case .null?: return "null"
    case let .string(s)?: return s
    case let .bool(b)?: return b ? "true" : "false"
    case let .number(n)?: return jsNumber(n)
    case let v?: return v.jsonString
    }
}

func jsNumber(_ d: Double) -> String { JsNumber.format(d) }

/// `String(number)` as JavaScript prints it (ECMAScript Number::toString): shortest digits, plain below 1e21, exponent form beyond.
public enum JsNumber {
    public static func format(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == 0 { return "0" }
        // Swift prints the shortest digits that round-trip, as "123.45", "1e-05" or "1.5e+20": read them as digits and a point position.
        let parts = "\(abs(d))".split(separator: "e", maxSplits: 1).map(String.init)
        let mantissa = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var digits = Array(mantissa[0] + (mantissa.count > 1 ? mantissa[1] : ""))
        var n = mantissa[0].count + (parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        while digits.count > 1, digits.first == "0" { digits.removeFirst(); n -= 1 }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        let k = digits.count
        let text = String(digits)
        let body: String
        if k <= n, n <= 21 {
            body = text + String(repeating: "0", count: n - k)
        } else if n >= 1, n <= 21 {
            body = String(digits[..<n]) + "." + String(digits[n...])
        } else if n <= 0, n > -6 {
            body = "0." + String(repeating: "0", count: -n) + text
        } else {
            let e = n - 1
            let head = k == 1 ? text : String(digits[0]) + "." + String(digits[1...])
            body = head + "e" + (e >= 0 ? "+" : "-") + String(abs(e))
        }
        return d < 0 ? "-" + body : body
    }
}

/// Placement audiences and A/B buckets (Web SDK src/targeting.ts, load.ts).
public enum Targeting {
    /// Audience condition on a named field. `app_version` (a native-only fact) compares ordering ops
    /// (`gt`/`gte`/`lt`/`lte`) as dotted version numbers; every other op and field is `matches`.
    public static func matches(field: String, op: String, expected: JSONValue?, actual: JSONValue?) -> Bool {
        guard field == "app_version", ["gt", "gte", "lt", "lte"].contains(op) else { return matches(op: op, expected: expected, actual: actual) }
        guard let actual, !actual.isNull, let expected, !expected.isNull else { return false }
        guard let c = compareVersions(jsString(actual), jsString(expected)) else { return false }
        switch op {
        case "gt": return c > 0
        case "gte": return c >= 0
        case "lt": return c < 0
        default: return c <= 0
        }
    }

    /// Compares `1.2.3` style versions segment by segment as numbers; a missing segment is 0 (`2` = `2.0.0`).
    /// Nil when either side has a segment that is not plain digits.
    public static func compareVersions(_ a: String, _ b: String) -> Int? {
        func parts(_ v: String) -> [[UInt8]]? {
            var out: [[UInt8]] = []
            for seg in v.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false) {
                let digits = Array(seg.utf8)
                guard !digits.isEmpty, digits.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
                // Strip leading zeros so equal-length digit strings compare as numbers of any size.
                var d = digits[...]
                while d.count > 1, d.first == 48 { d = d.dropFirst() }
                out.append(Array(d))
            }
            return out
        }
        func compare(_ x: [UInt8], _ y: [UInt8]) -> Int {
            if x.count != y.count { return x.count < y.count ? -1 : 1 }
            for (p, q) in zip(x, y) where p != q { return p < q ? -1 : 1 }
            return 0
        }
        guard let x = parts(a), let y = parts(b) else { return nil }
        for i in 0..<max(x.count, y.count) {
            let c = compare(i < x.count ? x[i] : [48], i < y.count ? y[i] : [48])
            if c != 0 { return c }
        }
        return 0
    }

    public static func matches(op: String, expected: JSONValue?, actual: JSONValue?) -> Bool {
        let has: Bool = {
            switch actual {
            case nil, .null?: return false
            case let .string(s)?: return !s.isEmpty
            default: return true
            }
        }()
        func text(_ v: JSONValue?) -> String { jsString(v).lowercased() }
        switch op {
        case "exists": return has
        case "not_exists": return !has
        case "eq": return has && text(actual) == text(expected)
        case "neq": return !has || text(actual) != text(expected)
        case "contains": return has && text(actual).contains(text(expected))
        case "starts_with": return has && text(actual).hasPrefix(text(expected))
        default:
            let a = numeric(actual)
            let b = numeric(expected)
            if a.isNaN || b.isNaN { return false }
            switch op {
            case "gt": return a > b
            case "gte": return a >= b
            case "lt": return a < b
            default: return a <= b
            }
        }
    }

    private static func numeric(_ v: JSONValue?) -> Double {
        switch v {
        case let .number(n)?: return n
        case let .string(s)?:
            if s.isEmpty { return .nan }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return 0 }
            return jsParse(trimmed)
        default: return .nan
        }
    }

    private static let decimal = TextLogic.regex(#"^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#)

    /// JavaScript's `Number(text)` for a trimmed, non-empty string: decimals, `Infinity`, and `0x`/`0o`/`0b` integers.
    /// Swift's own `Double("inf")`, `Double("nan")` and hex floats are NaN in JavaScript.
    static func jsParse(_ t: String) -> Double {
        if TextLogic.contains(decimal, t) { return Double(t) ?? .nan }
        if t == "Infinity" || t == "+Infinity" { return .infinity }
        if t == "-Infinity" { return -.infinity }
        let scalars = Array(t.unicodeScalars)
        if scalars.count > 2, scalars[0] == "0" {
            let radix: Int
            switch scalars[1] {
            case "x", "X": radix = 16
            case "o", "O": radix = 8
            case "b", "B": radix = 2
            default: return .nan
            }
            // Digits beyond 64 bits lose precision in a Double anyway: parse as Double by accumulation.
            var value = 0.0
            for u in scalars[2...] {
                guard let digit = Int(String(u), radix: radix) else { return .nan }
                value = value * Double(radix) + Double(digit)
            }
            return value
        }
        return .nan
    }

    /// FNV-1a over UTF-16 code units, like the web: the same visitor lands on the same side everywhere.
    public static func bucketOf(_ experimentId: String, _ visitorId: String) -> Int {
        var h: UInt32 = 0x811C9DC5
        for unit in "\(experimentId):\(visitorId)".utf16 {
            h ^= UInt32(unit)
            h = h &* 0x0100_0193
        }
        return Int(h % 100)
    }
}

/// Screen links and answers (Web SDK src/flow.ts).
public enum Flow {
    public enum Link: Equatable {
        case back
        case goTo(String)
    }

    public static func screenLink(_ actionId: String) -> Link? {
        if actionId == "screen:back" { return .back }
        if actionId.hasPrefix("screen:"), actionId.count > "screen:".count { return .goTo(String(actionId.dropFirst("screen:".count))) }
        return nil
    }

    public enum FieldKind: Sendable { case single, multiple, text }

    /// An answer: one option id / typed text, or several option ids (multiple choice).
    public enum Answer: Equatable, Sendable {
        case one(String)
        case many([String])
    }

    public static func applyAnswer(_ answers: [String: Answer], kind: FieldKind?, fieldId: String, value: String) -> [String: Answer] {
        var next = answers
        if kind == .multiple {
            var current: [String] = []
            if case let .many(values)? = next[fieldId] { current = values }
            let toggled = current.contains(value) ? current.filter { $0 != value } : current + [value]
            next[fieldId] = toggled.isEmpty ? nil : .many(toggled)
            return next
        }
        next[fieldId] = value.isEmpty ? nil : .one(value)
        return next
    }

    /// Every node object in a JSON tree, however nested.
    public static func walk(_ e: JSONValue?, _ visit: (JSONValue) -> Void) {
        switch e {
        case let .array(a)?: a.forEach { walk($0, visit) }
        case let .object(o)?:
            if case .string? = o["type"] { visit(e!) }
            // Sorted for a stable order (JSON objects are unordered in Swift).
            for key in o.keys.sorted() { walk(o[key], visit) }
        default: break
        }
    }

    public static func questionFields(_ config: JSONValue?) -> [String: FieldKind] {
        var out: [String: FieldKind] = [:]
        walk(config) { node in
            let kind: FieldKind?
            switch node.str("type") {
            case "input_single_choice": kind = .single
            case "input_multiple_choice": kind = .multiple
            case "input_text": kind = .text
            default: kind = nil
            }
            if let kind, let field = node.str("field_id"), !field.isEmpty { out[field] = kind }
        }
        return out
    }

    public static func linkedScreens(_ config: JSONValue?) -> [String] {
        var ids: [String] = []
        walk(config) { node in
            if case let .goTo(id)? = screenLink(node.obj("triggers")?.str("on_press") ?? ""), !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// Chosen options for analytics; typed text never leaves the app.
    public static func chosenOptions(_ answers: [String: Answer], _ fields: [String: FieldKind]) -> [(fieldId: String, optionId: String)] {
        fields.keys.sorted().flatMap { fieldId -> [(fieldId: String, optionId: String)] in
            guard fields[fieldId] != .text else { return [] }
            switch answers[fieldId] {
            case let .one(v)?: return [(fieldId, v)]
            case let .many(vs)?: return vs.map { (fieldId, $0) }
            case nil: return []
            }
        }
    }
}

/// Countdown variables (the web renderer).
public enum Countdown {
    public static func values(targetMs: Int64, nowMs: Int64) -> [String: String] {
        var out: [String: String] = [:]
        func put(_ unit: String, _ v: Int64) {
            out["count_\(unit)_with_zero"] = v < 10 ? "0\(v)" : "\(v)"
            out["count_\(unit)_without_zero"] = "\(v)"
        }
        let diff = targetMs - nowMs
        if diff <= 0 {
            ["days", "hours", "minutes", "seconds"].forEach { put($0, 0) }
            return out
        }
        let totalSeconds = diff / 1000
        let totalMinutes = totalSeconds / 60
        let totalHours = totalMinutes / 60
        put("days", totalHours / 24)
        put("hours", totalHours % 24)
        put("minutes", totalMinutes % 60)
        put("seconds", totalSeconds % 60)
        return out
    }

    public static func hasEnded(targetMs: Int64, nowMs: Int64) -> Bool { targetMs <= nowMs }

    /// ISO 8601 date (with or without fractional seconds) in epoch milliseconds.
    public static func parseDate(_ s: String) -> Int64? { IsoTime.parse(s) }
}
