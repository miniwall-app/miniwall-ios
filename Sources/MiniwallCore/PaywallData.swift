import Foundation

/// The screen document the dashboard publishes (`PaywallData` of `@ui-kit/ui-sdk`).
/// Decoding is lenient by design: an unknown field is ignored, an unknown node type becomes
/// ``Component/unsupported(type:id:raw:fallback:)`` (rendered through its `fallback`, else skipped),
/// a malformed value falls back to the web renderer's default. Mirrors `com.miniwall.core.model`.
public struct PaywallData: Sendable {
    public let id: String
    public let defaultLocale: String
    /// Palette: alias name -> hex color.
    public let colors: [String: String]
    public let base: RootPaywall
    /// locale -> (key -> string).
    public let localizations: [String: [String: String]]
    /// The source document, for fields the typed model does not cover yet.
    public let raw: JSONValue

    /// Throws ``PaywallDecodingError`` only when the JSON is invalid or the document has no root stack.
    public static func decode(_ data: Data) throws -> PaywallData {
        try decode(JSONValue.parse(data))
    }

    public static func decode(_ json: JSONValue) throws -> PaywallData {
        guard let config = json["components_config"], config.isObject else {
            throw PaywallDecodingError("components_config missing")
        }
        guard let base = config["base"], base.isObject else {
            throw PaywallDecodingError("components_config.base missing")
        }
        guard let stackJSON = base["stack"], case let .stack(stack)? = Component.decode(stackJSON) else {
            throw PaywallDecodingError("components_config.base.stack missing or not a stack")
        }
        let colors = (config["colors"]?.objectValue ?? [:]).compactMapValues { $0.stringValue }
        let localizations = (json["components_localizations"]?.objectValue ?? [:]).mapValues { table in
            (table.objectValue ?? [:]).compactMapValues { $0.stringValue }
        }
        return PaywallData(
            id: json["id"]?.stringValue ?? "",
            defaultLocale: json["default_locale"]?.stringValue ?? "en_US",
            colors: colors,
            base: RootPaywall(
                stack: stack,
                header: base["header"].flatMap(Component.decode),
                stickyFooter: base["sticky_footer"].flatMap(Component.decode),
                background: base["background"]
            ),
            localizations: localizations,
            raw: json
        )
    }
}

public struct PaywallDecodingError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct RootPaywall: Sendable {
    public let stack: Stack
    public let header: Component?
    public let stickyFooter: Component?
    public let background: JSONValue?
}

/// Width or height of a node (`SizeType` on the web).
public enum SizeSpec: Equatable, Sendable {
    case fixed(Double)
    /// Fraction of the parent's content box (`0.5` = 50%).
    case relative(Double)
    case fit
    case fill

    static func decode(_ json: JSONValue?) -> SizeSpec {
        switch json?["type"]?.stringValue {
        case "fixed": return .fixed(json?["value"]?.doubleValue ?? 0)
        case "relative": return .relative(json?["value"]?.doubleValue ?? 1)
        case "fill": return .fill
        default: return .fit
        }
    }
}

public struct Spacing: Equatable, Sendable {
    public var top: Double
    public var bottom: Double
    public var leading: Double
    public var trailing: Double

    public init(top: Double, bottom: Double, leading: Double, trailing: Double) {
        self.top = top
        self.bottom = bottom
        self.leading = leading
        self.trailing = trailing
    }

    public static let zero = Spacing(top: 0, bottom: 0, leading: 0, trailing: 0)
    public var horizontal: Double { leading + trailing }
    public var vertical: Double { top + bottom }

    static func decode(_ json: JSONValue?) -> Spacing {
        Spacing(
            top: json?["top"]?.doubleValue ?? 0,
            bottom: json?["bottom"]?.doubleValue ?? 0,
            leading: json?["leading"]?.doubleValue ?? 0,
            trailing: json?["trailing"]?.doubleValue ?? 0
        )
    }
}

/// Main-axis distribution (`justify-content` on the web). Unknown values map to center, like the web.
public enum Distribution: Sendable {
    case start, center, end, spaceBetween, spaceAround, spaceEvenly

    static func decode(_ value: String?) -> Distribution {
        switch value {
        case "start": return .start
        case "end": return .end
        case "space_between": return .spaceBetween
        case "space_around": return .spaceAround
        case "space_evenly": return .spaceEvenly
        default: return .center
        }
    }
}

/// Position on one axis: leading/top, center, trailing/bottom.
public enum Align: Sendable {
    case start, center, end

    public var factor: Double {
        switch self {
        case .start: return 0
        case .center: return 0.5
        case .end: return 1
        }
    }

    /// Cross-axis alignment of a vertical/horizontal stack. Unknown values map to center, like the web.
    static func decode(_ value: String?) -> Align {
        switch value {
        case "leading", "top": return .start
        case "trailing", "bottom": return .end
        default: return .center
        }
    }
}

/// Stack direction and alignment (`dimension` on the web).
public enum StackDimension: Equatable, Sendable {
    case vertical(alignment: Align, distribution: Distribution)
    case horizontal(alignment: Align, distribution: Distribution)
    /// Layers on top of each other; layers 2...n are placed inside the content box by these alignments.
    case zlayer(horizontal: Align, vertical: Align)

    static func decode(_ json: JSONValue?) -> StackDimension {
        let alignment = json?["alignment"]?.stringValue
        let distribution = Distribution.decode(json?["distribution"]?.stringValue)
        switch json?["type"]?.stringValue {
        case "horizontal":
            return .horizontal(alignment: Align.decode(alignment), distribution: distribution)
        case "zlayer":
            // top_leading ... bottom_trailing; unknown -> center.
            let a = alignment ?? "center"
            let h: Align = a.hasSuffix("leading") ? .start : a.hasSuffix("trailing") ? .end : .center
            let v: Align = a.hasPrefix("top") ? .start : a.hasPrefix("bottom") ? .end : .center
            return .zlayer(horizontal: h, vertical: v)
        case "vertical":
            return .vertical(alignment: Align.decode(alignment), distribution: distribution)
        case nil where json?.isObject != true:
            return .vertical(alignment: .center, distribution: .center)
        default:
            // The web renders any other type as a row (stack-utils.js mapDimension).
            return .horizontal(alignment: Align.decode(alignment), distribution: distribution)
        }
    }
}

public struct Stack: Sendable {
    public let id: String?
    public let raw: JSONValue
    public let components: [Component]
    public let width: SizeSpec
    public let height: SizeSpec
    public let dimension: StackDimension
    public let spacing: Double
    public let margin: Spacing
    public let padding: Spacing
    /// Border width in pt; the border takes layout space (also for gradient borders).
    public let borderWidth: Double
}

public indirect enum Component: Sendable {
    case stack(Stack)
    /// A node type this SDK version does not render yet. Rendered as `fallback` when present.
    case unsupported(type: String, id: String?, raw: JSONValue, fallback: Component?)

    public var type: String {
        switch self {
        case .stack: return "stack"
        case let .unsupported(type, _, _, _): return type
        }
    }

    public var id: String? {
        switch self {
        case let .stack(s): return s.id
        case let .unsupported(_, id, _, _): return id
        }
    }

    public var raw: JSONValue {
        switch self {
        case let .stack(s): return s.raw
        case let .unsupported(_, _, raw, _): return raw
        }
    }

    /// `visible: false` hides the node (takes no space, no spacing).
    public var isVisible: Bool { raw["visible"]?.boolValue != false }

    /// Nil when the value is not an object.
    public static func decode(_ json: JSONValue) -> Component? {
        guard json.isObject else { return nil }
        let type = json["type"]?.stringValue ?? ""
        let id = json["id"]?.stringValue
        switch type {
        case "stack":
            return .stack(Stack(
                id: id,
                raw: json,
                components: (json["components"]?.arrayValue ?? []).compactMap(Component.decode),
                width: SizeSpec.decode(json["size"]?["width"]),
                height: SizeSpec.decode(json["size"]?["height"]),
                dimension: StackDimension.decode(json["dimension"]),
                spacing: json["spacing"]?.doubleValue ?? 0,
                margin: Spacing.decode(json["margin"]),
                padding: Spacing.decode(json["padding"]),
                borderWidth: json["border"]?["width"]?.doubleValue ?? 0
            ))
        default:
            return .unsupported(type: type, id: id, raw: json, fallback: json["fallback"].flatMap(Component.decode))
        }
    }
}
