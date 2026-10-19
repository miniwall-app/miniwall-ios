import Foundation

/// One entry of `GET /v1/sdk/auto?platform=...` (D-120): a placement and when it shows by itself.
public struct AutoTrigger: Equatable {
    public let placement: String
    /// `app_open`, `event` or `delay`; others are not for apps and are dropped on parse.
    public let type: String
    public var seconds: Int?
    public var event: String?
    /// `app_open`: every Nth open.
    public var every: Int
    public var priority: Int

    public init(placement: String, type: String, seconds: Int? = nil, event: String? = nil, every: Int = 1, priority: Int = 0) {
        self.placement = placement
        self.type = type
        self.seconds = seconds
        self.event = event
        self.every = every
        self.priority = priority
    }
}

/// What an app opening asks for: placements to try now (in order) and the ones to try after a wait.
public struct AppOpened: Equatable {
    public struct Delayed: Equatable {
        public let placement: String
        public let seconds: Int
        public init(placement: String, seconds: Int) {
            self.placement = placement
            self.seconds = seconds
        }
    }

    public let now: [String]
    public let delayed: [Delayed]
}

/// Decides which automatic placements an app's moments fire. The platform layer owns the
/// presenting (one screen at a time, the first placement that does not skip wins, like the web
/// SDK's queue); this holds the rules, so they are tested once. Mirrors `AutoTriggers.kt`.
public final class AutoTriggers {
    private let store: KeyValueStore
    public private(set) var triggers: [AutoTrigger] = []

    public init(store: KeyValueStore) { self.store = store }

    /// Replaces the list from an `/auto` response; highest priority first, otherwise the server's order.
    public func load(_ body: JSONValue) {
        let parsed = (body.arr("placements") ?? []).compactMap(Self.parse)
        // Stable: equal priorities keep the server's order.
        triggers = parsed.enumerated().sorted { a, b in
            a.element.priority != b.element.priority ? a.element.priority > b.element.priority : a.offset < b.offset
        }.map(\.element)
    }

    /// The app came to the foreground: counts the open and returns what fires.
    public func appOpened() -> AppOpened {
        let opens = (store.get(DeviceMemory.opensKey).flatMap { Int64($0) } ?? 0) + 1
        store.set(DeviceMemory.opensKey, String(opens))
        let now = triggers.filter { $0.type == "app_open" && opens % Int64($0.every) == 0 }.map(\.placement)
        let delayed = triggers.filter { $0.type == "delay" }.map { AppOpened.Delayed(placement: $0.placement, seconds: $0.seconds ?? 0) }
        return AppOpened(now: now, delayed: delayed)
    }

    /// The app reported `name` (`Miniwall.track`): the placements waiting for that event.
    public func event(_ name: String) -> [String] {
        triggers.filter { $0.type == "event" && $0.event == name }.map(\.placement)
    }

    private static func parse(_ o: JSONValue) -> AutoTrigger? {
        guard let key = o.str("placement"), let t = o["trigger"], let type = t.str("type") else { return nil }
        let priority = t.num("priority").map(\.clampedInt) ?? 0
        switch type {
        case "app_open":
            return AutoTrigger(placement: key, type: type, every: max(1, t.num("every").map(\.clampedInt) ?? 1), priority: priority)
        case "event":
            guard let event = t.str("event") else { return nil }
            return AutoTrigger(placement: key, type: type, event: event, priority: priority)
        case "delay":
            guard let seconds = t.num("seconds") else { return nil }
            return AutoTrigger(placement: key, type: type, seconds: seconds.clampedInt, priority: priority)
        default:
            return nil
        }
    }
}
