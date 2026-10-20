import Foundation

/// Persistent key-value storage (UserDefaults on iOS). Values are JSON text.
public protocol KeyValueStore: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?)
}

public final class MemoryStore: KeyValueStore {
    private var map: [String: String] = [:]
    public init() {}
    public func get(_ key: String) -> String? { map[key] }
    public func set(_ key: String, _ value: String?) { map[key] = value }
}

/// Why a placement showed nothing.
public enum SkipReason: String, Sendable {
    case frequencyCap = "frequency_cap"
    case audience
    case holdout
}

/// Which published screen an event belongs to.
public struct EventContext: Equatable, Sendable {
    public var paywallId: String
    public var version: Int?
    public var placement: String?
    public var experimentId: String?
    public var variant: String?

    public init(paywallId: String, version: Int? = nil, placement: String? = nil, experimentId: String? = nil, variant: String? = nil) {
        self.paywallId = paywallId
        self.version = version
        self.placement = placement
        self.experimentId = experimentId
        self.variant = variant
    }
}

/// What a placement or screen id resolved to.
public struct Resolved {
    public var paywall: JSONValue?
    public var context: EventContext?
    public var skip: SkipReason?
    /// The placement's display settings from the dashboard.
    public var display: JSONValue?

    public init(paywall: JSONValue?, context: EventContext?, skip: SkipReason? = nil, display: JSONValue? = nil) {
        self.paywall = paywall
        self.context = context
        self.skip = skip
        self.display = display
    }
}

/// Targeting input of one call: app attributes (never sent), locale, device.
public struct TargetingInput {
    public var attributes: [String: JSONValue]
    public var locale: String?
    /// `mobile` or `tablet`.
    public var device: String
    /// `ios` or `android`, readable as the `platform` field.
    public var platform: String
    public var ignoreCap = false
    /// Major OS version (`17`), see `AutoAttributes.osVersion`.
    public var osVersion: String?
    /// The app's version name (`2.3.1`).
    public var appVersion: String?
    /// Region, upper case. Nil: taken from `locale` (never from the IP address).
    public var country: String?

    public init(attributes: [String: JSONValue], locale: String?, device: String, platform: String, ignoreCap: Bool = false,
                osVersion: String? = nil, appVersion: String? = nil, country: String? = nil) {
        self.attributes = attributes
        self.locale = locale
        self.device = device
        self.platform = platform
        self.ignoreCap = ignoreCap
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.country = country
    }
}

/// Per-device memory: visitor id, how often each placement showed, first-seen day, last exposure.
/// Same keys and rules as the web's localStorage.
public final class DeviceMemory {
    private let store: KeyValueStore
    private let clock: () -> Int64
    private var sessionShown: [String: Int] = [:]

    static let visitorKey = "uikit:vid"
    static let shownPrefix = "uikit:shown:"
    static let firstSeenKey = "uikit:first-seen"
    static let exposureKey = "uikit:last-exposure"
    static let pendingKey = "uikit:pending-purchase"
    static let opensKey = "uikit:app-opens"
    static let dayMs: Int64 = 86_400_000

    public init(store: KeyValueStore, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.store = store
        self.clock = clock
    }

    public var visitorId: String {
        if let id = store.get(Self.visitorKey) { return id }
        let id = UUID().uuidString.lowercased()
        store.set(Self.visitorKey, id)
        return id
    }

    private func shownLog(_ placement: String) -> (total: Int64, times: [Int64]) {
        guard let raw = store.get(Self.shownPrefix + placement), let o = JSONValue.parse(string: raw) else { return (0, []) }
        return ((o.num("total") ?? 0).clampedInt64, (o.arr("times") ?? []).compactMap { $0.doubleValue.map(\.clampedInt64) })
    }

    public func recordShown(_ placement: String) {
        let log = shownLog(placement)
        let times = Array((log.times + [clock()]).suffix(100))
        store.set(Self.shownPrefix + placement, JSONValue.object(["total": .number(Double(log.total + 1)), "times": .array(times.map { .number(Double($0)) })]).jsonString)
        sessionShown[placement, default: 0] += 1
    }

    public func isCapped(_ placement: String, _ cap: JSONValue?) -> Bool {
        guard let cap, let max = cap.num("max") else { return false }
        let log = shownLog(placement)
        let now = clock()
        let count: Int64
        switch cap.str("per") {
        case "session": count = Int64(sessionShown[placement] ?? 0)
        case "ever": count = log.total
        case "day": count = Int64(log.times.filter { now - $0 < Self.dayMs }.count)
        default: count = Int64(log.times.filter { now - $0 < 7 * Self.dayMs }.count)
        }
        return Double(count) >= max
    }

    public func seenCount(_ placement: String) -> Int64 { shownLog(placement).total }

    public func daysSinceFirstSeen() -> Int64 {
        let now = clock()
        let first = store.get(Self.firstSeenKey).flatMap { Int64($0) } ?? {
            store.set(Self.firstSeenKey, String(now))
            return now
        }()
        return (now - first) / Self.dayMs
    }

    public func rememberExposure(_ context: EventContext, heldOut: Bool) {
        var o: [String: JSONValue] = ["paywallId": .string(context.paywallId), "placement": .string(context.placement ?? ""),
                                      "heldOut": .bool(heldOut), "at": .number(Double(clock()))]
        if let v = context.version { o["version"] = .number(Double(v)) }
        store.set(Self.exposureKey, JSONValue.object(o).jsonString)
    }

    /// The last placement met within 30 days.
    public func lastExposure() -> (context: EventContext, heldOut: Bool)? {
        guard let raw = store.get(Self.exposureKey), let o = JSONValue.parse(string: raw), let at = o.num("at"), let id = o.str("paywallId") else { return nil }
        guard clock() - Int64(at) < 30 * Self.dayMs else { return nil }
        return (EventContext(paywallId: id, version: o.num("version").map(\.clampedInt), placement: o.str("placement")), o.bool("heldOut") == true)
    }

    public func rememberPendingPurchase(_ context: EventContext, packageId: String) {
        store.set(Self.pendingKey, Events.contextJSON(context, extra: ["packageId": .string(packageId)]).jsonString)
    }

    public func pendingPurchase() -> JSONValue? { store.get(Self.pendingKey).flatMap(JSONValue.parse(string:)) }
    public func forgetPendingPurchase() { store.set(Self.pendingKey, nil) }

    /// Forgets the visitor (`Miniwall.reset()`): a new visitor id, no counters or exposures.
    public func reset(placements: [String]) {
        (placements.map { Self.shownPrefix + $0 } + [Self.visitorKey, Self.firstSeenKey, Self.exposureKey, Self.pendingKey, Self.opensKey]).forEach { store.set($0, nil) }
        sessionShown = [:]
    }
}

/// A delivery API body turned into the screen to show (Web SDK src/load.ts).
public enum Delivery {
    private static func contextOf(_ body: JSONValue) -> EventContext? {
        guard let id = body.str("paywallId") else { return nil }
        return EventContext(paywallId: id, version: body.num("version").map(\.clampedInt), placement: body.str("placement"))
    }

    /// The paywall JSON of a body (`paywall`, possibly wrapped in `paywallData`); nil when it is not one.
    public static func asPaywall(_ value: JSONValue?) -> JSONValue? {
        guard let o = value, o.isObject else { return nil }
        let unwrapped = o.obj("paywallData") ?? o
        guard unwrapped.obj("components_config")?.obj("base")?.obj("stack") != nil else { return nil }
        return unwrapped.obj("components_localizations") != nil ? unwrapped : unwrapped.merging(["components_localizations": .object([:])])
    }

    public static func pickSide(_ body: JSONValue, visitorId: String) -> Resolved {
        guard let test = body.obj("experiment"), let b = test.obj("b") else { return Resolved(paywall: asPaywall(body["paywall"]), context: contextOf(body)) }
        let id = test.str("id") ?? ""
        let variant = Double(Targeting.bucketOf(id, visitorId)) < (test.num("shareB") ?? 0) ? "b" : "a"
        let chosen = variant == "b" ? b : body
        var context = contextOf(chosen)
        context?.experimentId = id
        context?.variant = variant
        return Resolved(paywall: asPaywall(chosen["paywall"]), context: context)
    }

    /// Targeting in order: frequency cap, first matching audience, then holdout.
    public static func decide(_ body: JSONValue, input: TargetingInput, memory: DeviceMemory) -> Resolved {
        let placement = body.str("placement") ?? ""
        if !placement.isEmpty, !input.ignoreCap, memory.isCapped(placement, body.obj("frequency")) {
            return Resolved(paywall: nil, context: nil, skip: .frequencyCap)
        }
        let rules = (body.arr("rules") ?? []).filter(\.isObject)
        let rule: JSONValue? = placement.isEmpty ? nil : rules.first(where: { r in
            (r.arr("conditions") ?? []).allSatisfy { c in
                guard c.isObject else { return false }
                return Targeting.matches(field: c.str("field") ?? "", op: c.str("op") ?? "", expected: c["value"], actual: fieldValue(c.str("field") ?? "", placement, input, memory))
            }
        })
        if let rule, rule["paywall"] == nil || rule["paywall"]?.isNull == true { return Resolved(paywall: nil, context: nil, skip: .audience) }
        let chosen = rule?.obj("paywall").map { Resolved(paywall: asPaywall($0["paywall"]), context: contextOf($0)) } ?? pickSide(body, visitorId: memory.visitorId)
        if let holdout = body.obj("holdout"), let share = holdout.num("share"), share > 0,
           Double(Targeting.bucketOf("holdout:\(holdout.str("id") ?? "")", memory.visitorId)) < share {
            return Resolved(paywall: nil, context: chosen.context, skip: .holdout)
        }
        var out = chosen
        out.display = body.obj("display")
        return out
    }

    /// Built-in audience fields on mobile; `user.<key>` reads the app's attributes.
    static func fieldValue(_ field: String, _ placement: String, _ input: TargetingInput, _ memory: DeviceMemory) -> JSONValue? {
        if field.hasPrefix("user.") { return input.attributes[String(field.dropFirst(5))] }
        switch field {
        case "locale": return input.locale.map(JSONValue.string)
        case "device": return .string(input.device)
        case "platform": return .string(input.platform)
        case "os_version": return input.osVersion.map(JSONValue.string)
        case "app_version": return input.appVersion.map(JSONValue.string)
        case "country": return (input.country ?? AutoAttributes.country(input.locale)).map(JSONValue.string)
        case "seen_count": return .number(Double(memory.seenCount(placement)))
        case "days_since_first_seen": return .number(Double(memory.daysSinceFirstSeen()))
        default: return nil
        }
    }
}

/// Analytics events as the API takes them (`POST /v1/sdk/events`).
/// Who sends an event: sent as `platform` (`ios` | `android`), `sdkVersion` and `appVersion` (none of it personal).
public struct EventClient: Equatable, Sendable {
    public var platform: String
    public var sdkVersion: String
    public var appVersion: String?
    public init(platform: String, sdkVersion: String, appVersion: String? = nil) {
        self.platform = platform
        self.sdkVersion = sdkVersion
        self.appVersion = appVersion
    }
}

public enum Events {
    /// `X-Miniwall-App` (`ios:<bundleId>` / `android:<applicationId>`), checked against the project's Allowed apps; nil when the id is unknown.
    public static func appHeader(platform: String, appId: String?) -> String? {
        guard let id = appId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return "\(platform):\(id)"
    }

    static func contextJSON(_ context: EventContext, extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["paywallId": .string(context.paywallId)]
        if let v = context.version { o["version"] = .number(Double(v)) }
        if let p = context.placement { o["placement"] = .string(p) }
        if let e = context.experimentId { o["experimentId"] = .string(e) }
        if let v = context.variant { o["variant"] = .string(v) }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func iso(_ ms: Int64) -> String { IsoTime.format(ms) }

    public static func event(_ type: String, _ context: EventContext, visitorId: String, occurredAtMs: Int64, extra: [String: String?] = [:], client: EventClient? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string(type), "visitorId": .string(visitorId), "occurredAt": .string(iso(occurredAtMs))]
        for (k, v) in extra { if let v { fields[k] = .string(v) } }
        if let client {
            fields["platform"] = .string(client.platform)
            fields["sdkVersion"] = .string(client.sdkVersion)
            if let v = client.appVersion { fields["appVersion"] = .string(v) }
        }
        return contextJSON(context, extra: fields)
    }

    /// Request bodies of at most 50 events each.
    public static func batches(_ events: [JSONValue]) -> [String] {
        stride(from: 0, to: events.count, by: 50).map { JSONValue.object(["events": .array(Array(events[$0..<min($0 + 50, events.count)]))]).jsonString }
    }
}

/// How a presented screen ended.
public enum PurchaseResult: Equatable {
    case purchased(packageId: String, answers: [String: Flow.Answer])
    case restored(answers: [String: Flow.Answer])
    case closed(answers: [String: Flow.Answer])
    /// A "Run your code" button was pressed and `onAction` did not keep the screen open.
    case action(actionId: String, answers: [String: Flow.Answer])
    case skipped(SkipReason)

    public var answers: [String: Flow.Answer] {
        switch self {
        case let .purchased(_, a), let .restored(a), let .closed(a), let .action(_, a): return a
        case .skipped: return [:]
        }
    }
}

/// The app's side of a shown screen. Every callback runs on the main thread.
public protocol SessionHost: AnyObject {
    func purchase(packageId: String, answers: [String: Flow.Answer], done: @escaping (Result<Bool, Error>) -> Void)
    func restore(done: @escaping (Result<Bool, Error>) -> Void)
    /// A "Run your code" button. Call `done(false)` to keep the screen open.
    func action(actionId: String, answers: [String: Flow.Answer], done: @escaping (Bool) -> Void)
    func openURL(_ url: String)
    func answer(fieldId: String, value: Flow.Answer?, answers: [String: Flow.Answer])
    func error(_ error: Error)
    /// Shows a new screen (flow step).
    func show(_ controller: ScreenController, animated: Bool)
    /// The screen is done: dismiss it and report `result`.
    func finish(_ result: PurchaseResult)
    /// True while a purchase/restore/action runs: show a spinner and ignore taps.
    func busy(_ isBusy: Bool)
}

public struct MiniwallError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One presentation of a screen and the flow behind it (Web SDK src/render.ts).
public final class PaywallSession {
    private struct Screen {
        let paywall: JSONValue
        let context: EventContext?
        let controller: ScreenController
    }

    private let memory: DeviceMemory
    private let enqueue: (JSONValue) -> Void
    private let loadScreen: (String, @escaping (Result<Resolved, Error>) -> Void) -> Void
    private let controllerFactory: (JSONValue, [String: Flow.Answer], @escaping (ScreenEvent) -> Void) -> ScreenController
    private weak var host: SessionHost?
    private let clock: () -> Int64
    private let client: EventClient?
    private let placement: String?
    private var history: [Screen] = []
    private var current: Screen!
    public private(set) var answers: [String: Flow.Answer] = [:]
    private var reported: Set<String> = []
    private var isBusy = false
    /// The visitor closed the screen while a purchase, restore or action was running: decided when it answers.
    private var closeRequested = false
    private var finished = false

    public init(
        first: Resolved,
        memory: DeviceMemory,
        enqueue: @escaping (JSONValue) -> Void,
        loadScreen: @escaping (String, @escaping (Result<Resolved, Error>) -> Void) -> Void,
        controllerFactory: @escaping (JSONValue, [String: Flow.Answer], @escaping (ScreenEvent) -> Void) -> ScreenController,
        host: SessionHost,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        client: EventClient? = nil
    ) {
        self.client = client
        self.memory = memory
        self.enqueue = enqueue
        self.loadScreen = loadScreen
        self.controllerFactory = controllerFactory
        self.host = host
        self.clock = clock
        placement = first.context?.placement
        show(first.paywall!, first.context, animated: false)
    }

    private func track(_ type: String, _ extra: [String: String?] = [:], context: EventContext? = nil) {
        guard let context = context ?? current.context else { return }
        if type == "view" || type == "holdout", let p = context.placement {
            if type == "view" { memory.recordShown(p) }
            memory.rememberExposure(context, heldOut: type == "holdout")
        }
        if type == "purchase_click", let pkg = extra["packageId"] ?? nil { memory.rememberPendingPurchase(context, packageId: pkg) }
        if type == "purchase" || type == "purchase_cancel" { memory.forgetPendingPurchase() }
        enqueue(Events.event(type, context, visitorId: memory.visitorId, occurredAtMs: clock(), extra: extra, client: client))
    }

    private func reportAnswers() {
        for (fieldId, optionId) in Flow.chosenOptions(answers, current.controller.fields) {
            let key = "\(current.context?.paywallId ?? "")|\(fieldId)|\(optionId)"
            guard reported.insert(key).inserted else { continue }
            track("answer", ["fieldId": fieldId, "optionId": optionId])
        }
    }

    private func emit(_ type: String, _ extra: [String: String?] = [:]) {
        if ["close", "purchase", "action", "restore"].contains(type) { reportAnswers() }
        track(type, extra)
    }

    private func makeController(_ paywall: JSONValue) -> ScreenController {
        controllerFactory(paywall, answers) { [weak self] in self?.onScreenEvent($0) }
    }

    private func show(_ paywall: JSONValue, _ context: EventContext?, animated: Bool) {
        let controller = makeController(paywall)
        current = Screen(paywall: paywall, context: context, controller: controller)
        host?.show(controller, animated: animated)
        track("view")
        // Load linked screens now so "Continue" opens them at once.
        for id in Flow.linkedScreens(paywall["components_config"]) { loadScreen(id) { _ in } }
    }

    private func runBusy(_ task: (@escaping () -> Void) -> Void) {
        guard !isBusy, !finished else { return }
        isBusy = true
        host?.busy(true)
        task { [weak self] in
            self?.isBusy = false
            self?.host?.busy(false)
        }
    }

    /// Applies a close that was asked for while busy, once the running call has been handled.
    private func settle() {
        guard closeRequested, !finished else { return }
        closeRequested = false
        close()
    }

    private func finish(_ result: PurchaseResult) {
        guard !finished else { return }
        finished = true
        host?.finish(result)
    }

    /// The system Back (Android): inside a flow it is "Back to previous screen"; on the first screen it closes.
    public func back() {
        guard !finished else { return }
        if isBusy { close() } else { customAction("screen:back") }
    }

    /// The visitor closed the screen another way (swipe down, close gesture).
    public func close() {
        guard !finished else { return }
        // A purchase may still go through: its answer decides the result, then the close is applied.
        if isBusy { closeRequested = true; return }
        emit("close")
        finish(.closed(answers: answers))
    }

    private func onScreenEvent(_ event: ScreenEvent) {
        guard !finished else { return }
        switch event {
        case let .purchase(packageId, _):
            runBusy { done in
                emit("purchase_click", ["packageId": packageId])
                host?.purchase(packageId: packageId, answers: answers) { [weak self] result in
                    guard let self else { return }
                    done()
                    defer { self.settle() }
                    switch result {
                    case let .success(bought):
                        self.emit(bought ? "purchase" : "purchase_cancel", ["packageId": packageId])
                        if bought { self.finish(.purchased(packageId: packageId, answers: self.answers)) }
                    case let .failure(error):
                        self.emit("purchase_error", ["packageId": packageId])
                        self.host?.error(error)
                    }
                }
            }
        case .restore:
            runBusy { done in
                host?.restore { [weak self] result in
                    guard let self else { return }
                    done()
                    defer { self.settle() }
                    switch result {
                    case let .success(restored):
                        if restored {
                            self.emit("restore")
                            self.finish(.restored(answers: self.answers))
                        }
                    case let .failure(error):
                        self.host?.error(error)
                    }
                }
            }
        case .close:
            close()
        case let .customAction(id):
            customAction(id)
        case let .openURL(url):
            openURL(url)
        case .completeWorkflow:
            // The Web SDK never wires `onCompleteWorkflowNavigate`, so the press does nothing there; same here.
            break
        case .customerCenter, .packageSelected:
            break
        case let .answer(fieldId, value):
            answers = Flow.applyAnswer(answers, kind: current.controller.fields[fieldId], fieldId: fieldId, value: value)
            host?.answer(fieldId: fieldId, value: answers[fieldId], answers: answers)
        }
    }

    private func openURL(_ url: String) {
        guard TextLogic.isOpenableURL(url) else {
            host?.error(MiniwallError("Miniwall: not opening \"\(url.prefix(40))\": only http(s), mailto and tel links open"))
            return
        }
        host?.openURL(url)
    }

    private func customAction(_ actionId: String) {
        switch Flow.screenLink(actionId) {
        case .back?:
            // The first screen has nowhere to go back to: it closes.
            guard let previous = history.popLast() else { close(); return }
            current = Screen(paywall: previous.paywall, context: previous.context, controller: makeController(previous.paywall))
            host?.show(current.controller, animated: true)
            track("view")
        case let .goTo(screenId)?:
            runBusy { done in
                loadScreen(screenId) { [weak self] result in
                    guard let self else { return }
                    done()
                    defer { self.settle() }
                    switch result {
                    case let .success(next):
                        guard let paywall = next.paywall else {
                            self.host?.error(MiniwallError("Miniwall: screen \(screenId) could not be loaded"))
                            return
                        }
                        self.reportAnswers()
                        self.history.append(self.current)
                        // Every screen of a flow counts under the flow's placement.
                        let context = next.context.map { EventContext(paywallId: $0.paywallId, version: $0.version, placement: self.placement) }
                        self.show(paywall, context, animated: true)
                    case let .failure(error):
                        self.host?.error(error)
                    }
                }
            }
        case nil:
            runBusy { done in
                emit("action", ["actionId": actionId])
                host?.action(actionId: actionId, answers: answers) { [weak self] proceed in
                    guard let self else { return }
                    done()
                    defer { self.settle() }
                    if proceed { self.finish(.action(actionId: actionId, answers: self.answers)) }
                }
            }
        }
    }

    /// A placement that chose to show nothing: count the holdout and report the skip.
    public static func skipped(_ resolved: Resolved, memory: DeviceMemory, enqueue: (JSONValue) -> Void, clock: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }, client: EventClient? = nil) -> PurchaseResult {
        let reason = resolved.skip ?? .audience
        if reason == .holdout, let ctx = resolved.context {
            memory.rememberExposure(ctx, heldOut: true)
            enqueue(Events.event("holdout", ctx, visitorId: memory.visitorId, occurredAtMs: clock(), client: client))
        }
        return .skipped(reason)
    }

    /// A purchase that finished outside the screen: attributes it to the screen where buy was
    /// tapped, else to the last placement met (shown or held out).
    public static func reportPurchase(memory: DeviceMemory, enqueue: (JSONValue) -> Void, packageId: String?, paywallId: String?,
                                      clock: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }, client: EventClient? = nil) {
        let pending = memory.pendingPurchase()
        if pending == nil && paywallId == nil {
            guard let exposure = memory.lastExposure() else { return }
            enqueue(Events.event(exposure.heldOut ? "holdout_purchase" : "purchase", exposure.context, visitorId: memory.visitorId, occurredAtMs: clock(), extra: ["packageId": packageId], client: client))
            return
        }
        guard let id = paywallId ?? pending?.str("paywallId") else { return }
        memory.forgetPendingPurchase()
        let ctx = EventContext(paywallId: id, version: pending?.num("version").map(\.clampedInt), placement: pending?.str("placement"),
                               experimentId: pending?.str("experimentId"), variant: pending?.str("variant"))
        enqueue(Events.event("purchase", ctx, visitorId: memory.visitorId, occurredAtMs: clock(), extra: ["packageId": packageId ?? pending?.str("packageId")], client: client))
    }
}
