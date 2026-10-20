import Foundation

/// A parsed JSON value. The screen document is read through this so decoding stays lenient:
/// unknown keys are ignored and a wrong type falls back to the web renderer's default.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var doubleValue: Double? { if case let .number(n) = self { return n }; return nil }
    public var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case let .object(o) = self { return o }; return nil }
    public var isObject: Bool { objectValue != nil }

    /// Parses UTF-8 JSON text.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONValue(any: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// From a Foundation value (JSONSerialization, bridged dictionaries).
    public init(any: Any) throws {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            // JSONSerialization returns booleans as NSNumber; tell them apart by their Core Foundation type.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(try a.map { try JSONValue(any: $0) })
        case let o as [String: Any]:
            self = .object(try o.mapValues { try JSONValue(any: $0) })
        default:
            throw PaywallDecodingError("unsupported JSON value \(type(of: any))")
        }
    }
}

// MARK: - Access helpers (obj/str/num/bool)

public extension JSONValue {
    /// The object at `key`, if it is one.
    func obj(_ key: String) -> JSONValue? {
        guard let v = self[key], v.isObject else { return nil }
        return v
    }

    /// The string at `key` (numbers and booleans are not strings).
    func str(_ key: String) -> String? { self[key]?.stringValue }

    /// The number at `key` (strings are not numbers).
    func num(_ key: String) -> Double? { self[key]?.doubleValue }

    func bool(_ key: String) -> Bool? { self[key]?.boolValue }

    func arr(_ key: String) -> [JSONValue]? { self[key]?.arrayValue }

    var isNull: Bool { if case .null = self { return true }; return false }

    /// A copy of this object with `other`'s keys merged in (other wins).
    func merging(_ other: [String: JSONValue]) -> JSONValue {
        guard case var .object(o) = self else { return self }
        for (k, v) in other { o[k] = v }
        return .object(o)
    }

    /// Foundation value for JSONSerialization.
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(b): return b
        case let .number(n): return n
        case let .string(s): return s
        case let .array(a): return a.map(\.foundationValue)
        case let .object(o): return o.mapValues(\.foundationValue)
        }
    }

    /// Compact JSON text.
    var jsonString: String {
        if case let .string(s) = self, let data = try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) {
            return String(text.dropFirst().dropLast())
        }
        guard let data = try? JSONSerialization.data(withJSONObject: foundationValue, options: [.fragmentsAllowed, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    static func parse(string: String) -> JSONValue? { try? parse(Data(string.utf8)) }
}

extension Double {
    /// The whole number nearest toward zero, kept in a range every platform agrees on: Swift's `Int(d)` traps on
    /// NaN, infinity and values past 64 bits, where other platforms saturate.
    var clampedInt64: Int64 { isNaN ? 0 : Int64(max(-9e15, min(9e15, self))) }
    var clampedInt: Int { Int(clampedInt64) }
}
