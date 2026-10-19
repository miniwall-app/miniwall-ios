#if os(iOS)
import MiniwallCore
import UIKit

/// Placements that show by themselves in an app (D-120): when the app opens, when it reports an
/// event with ``Miniwall/track(_:)``, or a few seconds after it opens. The rules live in
/// `AutoTriggers` (core); this runs them against the app's lifecycle and shows one screen at a time.
@MainActor
enum AutoPlacements {
    private static let triggers = AutoTriggers(store: DefaultsStore())
    private static var provider: (String) -> PresentOptions = { _ in PresentOptions() }
    private static var onResult: ((String, PurchaseResult) -> Void)?
    private static var started = false
    private static var loaded = false
    /// The list was not fetched yet or the last fetch failed: tried again at the next foreground and when `configure` runs.
    private static var needsRefresh = false
    private static var pendingOpen = false
    /// Events reported before the list loaded: played once it has.
    private static var pendingEvents: [String] = []
    /// Events reported while a screen was showing: played, in order, when it closes.
    private static var queuedEvents: [String] = []
    private static let maxQueuedEvents = 5
    private static var showing = false
    /// After `stop` and until the next `start`: events are not kept.
    private static var stopped = false
    private static var delayedTasks: [Task<Void, Never>] = []
    private static var observers: [NSObjectProtocol] = []
    private static var refreshing = false
    private static var refreshAgain = false
    /// Bumped by `stop`: a fetch that started before it must not touch the new state.
    private static var generation = 0

    static func start(options: @escaping (String) -> PresentOptions, onResult: ((String, PurchaseResult) -> Void)?) {
        provider = options
        self.onResult = onResult
        stopped = false
        guard !started else { return }
        started = true
        needsRefresh = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                pendingOpen = true
                await refresh()
            }
        })
        // A delay that runs out while the app is in the background must not show a screen then.
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                delayedTasks.forEach { $0.cancel() }
                delayedTasks = []
            }
        })
        // Starting the SDK at launch is itself an open.
        pendingOpen = true
        Task { await refresh() }
    }

    /// `Miniwall.stopAutoPlacements()`: forgets everything `start` set up, so a later `start` begins fresh.
    /// A screen that is showing stays until it closes.
    static func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        delayedTasks.forEach { $0.cancel() }
        delayedTasks = []
        provider = { _ in PresentOptions() }
        onResult = nil
        pendingEvents = []
        queuedEvents = []
        pendingOpen = false
        loaded = false
        needsRefresh = false
        refreshing = false
        refreshAgain = false
        generation += 1
        showing = false
        stopped = true
        started = false
    }

    /// `Miniwall.configure` ran: if `start` came first (or the last fetch failed), fetch the list now.
    static func configured() {
        guard started, needsRefresh, !refreshing else { return }
        Task { await refresh() }
    }

    static func track(_ event: String) {
        guard !stopped else { return }
        guard loaded else {
            pendingEvents.append(event)
            if pendingEvents.count > 20 { pendingEvents.removeFirst(pendingEvents.count - 20) }
            return
        }
        fire(triggers.event(event), event: event)
    }

    /// Fetches the list (a 304 when unchanged), then plays what is waiting.
    private static func refresh() async {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        let current = generation
        refreshing = true
        defer { if current == generation { refreshing = false } }
        repeat {
            refreshAgain = false
            await refreshOnce()
        } while refreshAgain && current == generation
    }

    private static func refreshOnce() async {
        let current = generation
        guard Miniwall.isConfigured else {
            needsRefresh = true
            return
        }
        do {
            let body = try await Miniwall.client.fetch("/auto", query: [URLQueryItem(name: "platform", value: "ios")])
            guard current == generation else { return }
            triggers.load(body)
            loaded = true
            needsRefresh = false
        } catch {
            guard current == generation else { return }
            needsRefresh = true
        }
        guard loaded else { return }
        let events = pendingEvents
        pendingEvents = []
        if pendingOpen {
            pendingOpen = false
            let opened = triggers.appOpened()
            fire(opened.now)
            // Delays count from this open: drop the ones of an earlier open that have not fired yet.
            delayedTasks.forEach { $0.cancel() }
            delayedTasks = opened.delayed.map { item in
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(min(max(0, item.seconds), 31_536_000)) * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    fire([item.placement])
                }
            }
        }
        for event in events { fire(triggers.event(event), event: event) }
    }

    /// Shows the first placement that does not skip; one screen at a time. A trigger of an event that meets
    /// a screen waits in `queuedEvents`; app-open and delay triggers are dropped, as before.
    private static func fire(_ placements: [String], event: String? = nil) {
        guard !placements.isEmpty else { return }
        guard !showing, Miniwall.presenting == 0 else {
            if let event, queuedEvents.count < maxQueuedEvents { queuedEvents.append(event) }
            return
        }
        showing = true
        let current = generation
        Task {
            await run(placements, generation: current)
            // A stop (and maybe a new start) happened meanwhile: the new run owns the state.
            guard current == generation else { return }
            showing = false
            drainQueue()
        }
    }

    private static func run(_ placements: [String], generation current: Int) async {
        for placement in placements {
            do {
                let result = try await Miniwall.present(.placement(placement), options: provider(placement))
                if current == generation { onResult?(placement, result) }
                if case .skipped = result { continue }
                return
            } catch {
                provider(placement).onError?(error)
            }
        }
    }

    /// Plays the next waiting event once no screen is open; each goes through `fire`, so one at a time.
    /// Called when a screen closes (ours in `fire`, the app's in `Miniwall.present`).
    static func drainQueue() {
        guard started, !showing, Miniwall.presenting == 0 else { return }
        while !queuedEvents.isEmpty {
            let event = queuedEvents.removeFirst()
            let placements = triggers.event(event)
            if placements.isEmpty { continue }
            fire(placements, event: event)
            return
        }
    }
}

public extension Miniwall {
    /// Starts the placements that show by themselves (set in the dashboard under "Show it": when the
    /// app opens, after a delay, or on an event you report with ``track(_:)``). Call once after
    /// ``configure(apiKey:options:)``. `options` gives each placement's prices and purchase handlers.
    @MainActor
    static func startAutoPlacements(options: @escaping (String) -> PresentOptions = { _ in PresentOptions() }, onResult: ((String, PurchaseResult) -> Void)? = nil) {
        AutoPlacements.start(options: options, onResult: onResult)
    }

    /// Stops what ``startAutoPlacements(options:onResult:)`` started: no more automatic screens, the
    /// waiting events are forgotten, and a later ``startAutoPlacements(options:onResult:)`` starts fresh.
    /// A screen that is showing stays until it closes.
    @MainActor
    static func stopAutoPlacements() {
        AutoPlacements.stop()
    }

    /// Tells Miniwall something happened in the app, e.g. `Miniwall.track("level_completed")`.
    /// A placement set to "when the app reports an event" with that name shows. While a screen is open, up to
    /// 5 events wait and play, in order, once it closes.
    @MainActor
    static func track(_ event: String) {
        AutoPlacements.track(event)
    }
}
#endif
