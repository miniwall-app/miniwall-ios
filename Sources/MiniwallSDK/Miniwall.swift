import Foundation
@_exported import MiniwallCore

/// A value for audience attributes (`user.<key>` in the dashboard). Read on the device, never sent.
public enum AttributeValue: Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    var json: JSONValue {
        switch self {
        case let .string(s): return .string(s)
        case let .number(n): return .number(n)
        case let .bool(b): return .bool(b)
        }
    }
}

public enum ColorMode: Sendable { case light, dark, system }

/// Entry point of the Miniwall iOS SDK. Same concepts as the Web SDK (`configure`, `present`,
/// `preload`, `reportPurchase`), Swift syntax. Miniwall renders screens; your app sells (D-109).
public enum Miniwall {
    /// SDK version, sent as `X-Miniwall-SDK: ios/<version>`.
    public static let version = "0.1.0"
    static let defaultAPIURL = "https://api.miniwall.app"

    public struct Options: Sendable {
        /// Your API's base URL; the default is Miniwall's.
        public var apiURL: URL?
        /// Locale for texts, e.g. `fr_FR`; default: the device's.
        public var locale: String?
        public var colorMode: ColorMode
        /// Send views, purchases and answers to Miniwall analytics. Default true.
        public var analytics: Bool
        /// Audience attributes (`user.<key>`), merged with ``Miniwall/setAttributes(_:)``.
        public var attributes: [String: AttributeValue]
        /// Seconds before a screen load gives up (the last cached copy is used when there is one).
        public var timeout: TimeInterval
        /// Largest text size multiplier honored from Dynamic Type (1 turns it off). Default 1.6.
        public var maxFontScale: Double

        public init(apiURL: URL? = nil, locale: String? = nil, colorMode: ColorMode = .system, analytics: Bool = true,
                    attributes: [String: AttributeValue] = [:], timeout: TimeInterval = 8, maxFontScale: Double = 1.6) {
            self.apiURL = apiURL
            self.locale = locale
            self.colorMode = colorMode
            self.analytics = analytics
            self.attributes = attributes
            self.timeout = timeout
            self.maxFontScale = maxFontScale
        }
    }

    static let client = MiniwallClient()
    /// Written by ``configure(apiKey:options:)`` and ``setAttributes(_:)`` under `lock`: read it only through
    /// ``currentOptions`` (any thread) so a read never meets a write.
    private static var options = Options()
    static let memory = DeviceMemory(store: DefaultsStore())
    private static let lock = NSLock()

    /// A copy of the options, safe to read from any thread.
    static var currentOptions: Options {
        lock.lock()
        defer { lock.unlock() }
        return options
    }

    /// Whether ``configure(apiKey:options:)`` has run.
    static var isConfigured: Bool {
        lock.lock()
        defer { lock.unlock() }
        return client.apiKey != nil
    }

    /// Call once at launch: `Miniwall.configure(apiKey: "pk_...")`.
    public static func configure(apiKey: String, options: Options = Options()) {
        lock.lock()
        Self.options = options
        client.apiKey = apiKey
        if let url = options.apiURL { client.apiURL = url }
        client.timeout = options.timeout
        client.analytics = options.analytics
        lock.unlock()
        #if os(iOS)
        // startAutoPlacements may have run first: now the list can be fetched.
        Task { @MainActor in AutoPlacements.configured() }
        #endif
    }

    /// Adds or changes audience attributes, e.g. after sign-in: `setAttributes(["plan": "pro"])`. `nil` removes one.
    public static func setAttributes(_ attributes: [String: AttributeValue?]) {
        lock.lock()
        defer { lock.unlock() }
        for (key, value) in attributes { options.attributes[key] = value }
    }

    /// Loads placements' screens (and their images) ahead of time, so `present` opens at once.
    public static func preload(placements: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for placement in placements {
                group.addTask {
                    guard let body = try? await client.fetch("/placements/\(placement.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? placement)") else { return }
                    #if os(iOS)
                    let paywall = Delivery.pickSide(body, visitorId: memory.visitorId).paywall
                    await FontRegistry.shared.load(paywall, wait: FontRegistry.preloadWait)
                    await preloadImages(in: paywall)
                    #endif
                }
            }
        }
    }

    /// The package ids a screen's cards use: the keys your app passes in `products`.
    public static func packageIds(in paywall: JSONValue) -> [String] {
        var ids: [String] = []
        Flow.walk(paywall["components_config"]?["base"]) { node in
            if node.str("type") == "package", let id = node.str("package_id"), !id.isEmpty, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// Records a purchase that finished outside the screen (e.g. a later StoreKit transaction).
    /// It is credited to the screen where buy was tapped, else to the last placement shown or held out.
    public static func reportPurchase(packageId: String? = nil, paywallId: String? = nil) {
        PaywallSession.reportPurchase(memory: memory, enqueue: client.enqueue, packageId: packageId, paywallId: paywallId, client: eventClient)
        client.flush()
    }

    /// Forgets this device's visitor id, frequency counters and exposures (e.g. on sign-out).
    public static func reset(placements: [String] = []) {
        memory.reset(placements: placements)
    }

    // MARK: Internal

    static var targetingLocale: String {
        currentOptions.locale ?? Locale.current.identifier
    }

    /// Sent on every event: platform, SDK version, the app's version name.
    static var eventClient: EventClient {
        EventClient(platform: "ios", sdkVersion: version, appVersion: AutoAttributes.appVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String))
    }

    /// `X-Miniwall-App` for the server's Allowed apps check; nil when the bundle id is unknown.
    static var appHeader: String? { Events.appHeader(platform: "ios", appId: Bundle.main.bundleIdentifier) }

    static func targeting(_ extra: [String: AttributeValue], ignoreCap: Bool = false) -> TargetingInput {
        let attributes = currentOptions.attributes.merging(extra) { $1 }
        #if os(iOS)
        let device = isPad ? "tablet" : "mobile"
        #else
        let device = "desktop"
        #endif
        return TargetingInput(
            attributes: attributes.mapValues(\.json), locale: targetingLocale, device: device, platform: "ios", ignoreCap: ignoreCap,
            osVersion: AutoAttributes.osVersion(String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)),
            appVersion: AutoAttributes.appVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        )
    }

    /// The screen a "Go to screen" button opens: the app's own JSON when given, else the published one.
    static func loadScreen(_ id: String, screens: [String: JSONValue]) async throws -> Resolved {
        if let local = screens[id] {
            guard let paywall = Delivery.asPaywall(local) else { throw MiniwallError("Miniwall: screens[\(id)] is not a screen JSON") }
            return Resolved(paywall: paywall, context: nil)
        }
        let body = try await client.fetch("/paywalls/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")
        guard let paywall = Delivery.asPaywall(body["paywall"]) else { throw MiniwallError("Miniwall: screen \(id) is not a screen JSON") }
        let context = body.str("paywallId").map { EventContext(paywallId: $0, version: body.num("version").map { Int($0) }) }
        return Resolved(paywall: paywall, context: context)
    }
}
