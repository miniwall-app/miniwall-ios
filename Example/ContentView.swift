// Sample app screen for trying MiniwallSDK on a simulator. Create an iOS App in Xcode
// (SwiftUI, iOS 16+), add this package (File > Add Package Dependencies >
// Add Local...), pick the MiniwallSDK product, and replace ContentView.swift with this file.
// Or generate the whole project, with the UI tests, from project.yml (see README.md in this folder).
//
// UI tests: every control has a stable accessibilityIdentifier. Launch arguments (all optional):
//   -uitest              start a local stand-in for the delivery API (see StubServer below) and configure the SDK with it
//   -tpl <name>          present the spec's fixtures/templates/<name>.json on launch (template sweep, see UITests/MiniwallTemplateTests.swift)
//   -purchaseMode fake|storekit   fake (default): 0.8 s then success; storekit: StoreKit 2 against Configuration.storekit
//   -purchaseResult true|false    fake purchase outcome (default true)
//   -restoreResult true|false     fake restore outcome (default false)
//   -blackholeFont       the bundled screens declare a custom font whose server never answers (UI test: it must not hold the screen back)
import MiniwallSDK
import Network
import StoreKit
import SwiftUI

struct ContentView: View {
    @State private var log = "Tap a button."
    @State private var offline = false
    @State private var storeProducts: [String: Product] = [:]
    @State private var templateShown = false
    private let launch = LaunchOptions()
    /// A publishable key of your Miniwall project (Dashboard > Install). Leave empty to try local JSON only.
    private var apiKey: String { launch.uiTest ? "pk_test_ui" : "" }
    /// A placement key from Dashboard > Placements.
    private let placement = "onboarding"

    var body: some View {
        NavigationStack {
            List {
                Section("Published (needs apiKey)") {
                    Button("present(placement: \"\(placement)\")") { Task { await present(.placement(placement)) } }
                        .disabled(apiKey.isEmpty)
                        .accessibilityIdentifier("present-placement")
                    Button("present(placement: \"never_loaded\")") { Task { await present(.placement("never_loaded")) } }
                        .disabled(apiKey.isEmpty)
                        .accessibilityIdentifier("present-missing")
                    Button(offline ? "Network: offline (tap to go online)" : "Network: online (tap to go offline)") {
                        offline.toggle()
                        StubServer.shared.setOffline(offline)
                    }
                    .disabled(!launch.uiTest)
                    .accessibilityIdentifier("toggle-offline")
                }
                Section("Bundled screens") {
                    Button("Paywall (fullscreen)") { Task { await presentBundled("paywall") } }
                        .accessibilityIdentifier("present-paywall")
                    Button("Paywall (modal)") { Task { await presentBundled("paywall", style: .modal) } }
                        .accessibilityIdentifier("present-paywall-modal")
                    Button("Flow (3 screens)") { Task { await presentBundled("flow-welcome", screens: ["flow_question": "flow-question", "flow_done": "flow-done"]) } }
                        .accessibilityIdentifier("present-flow")
                    Button("Present a bundled screen (paste one as sample.json)") {
                        guard let json = Self.bundled("sample") else {
                            log = "Add a sample.json (a screen exported from the editor) to the app target."
                            return
                        }
                        Task { await present(.json(json["paywall"] ?? json)) }
                    }
                    .accessibilityIdentifier("present-sample")
                }
                Section("Result") {
                    Text(log).font(.callout.monospaced())
                        .accessibilityIdentifier("result")
                }
            }
            .navigationTitle("Miniwall sample")
        }
        .onAppear {
            if launch.uiTest {
                if let port = try? StubServer.shared.start() {
                    Miniwall.configure(apiKey: apiKey, options: .init(apiURL: URL(string: "http://127.0.0.1:\(port)"), analytics: false, timeout: 3))
                }
            } else if !apiKey.isEmpty {
                Miniwall.configure(apiKey: apiKey)
            }
        }
        .task {
            // The view appears again when a presented screen is dismissed: show the template once.
            if let name = launch.template, !templateShown {
                templateShown = true
                try? await Task.sleep(nanoseconds: 600_000_000)
                await presentTemplate(name)
            }
            guard launch.purchaseMode == "storekit" else { return }
            let ids = ["monthly": "com.miniwall.example.monthly", "annual": "com.miniwall.example.annual"]
            if let found = try? await Product.products(for: Array(ids.values)) {
                storeProducts = Dictionary(uniqueKeysWithValues: ids.compactMap { package, id in found.first { $0.id == id }.map { (package, $0) } })
            }
        }
    }

    /// The text the UI tests read in the "result" element: `purchased:monthly`, `restored`, `closed`, `action:finish`,
    /// `skipped:holdout`, each followed by ` answers:goal=strength` when there are answers. Errors: `error:<message>`.
    static func describe(_ result: PurchaseResult) -> String {
        let base: String
        switch result {
        case let .purchased(packageId, _): base = "purchased:\(packageId)"
        case .restored: base = "restored"
        case .closed: base = "closed"
        case let .action(actionId, _): base = "action:\(actionId)"
        case let .skipped(reason): base = "skipped:\(reason.rawValue)"
        }
        let answers = result.answers.keys.sorted().map { key -> String in
            switch result.answers[key] {
            case let .one(value)?: return "\(key)=\(value)"
            case let .many(values)?: return "\(key)=\(values.joined(separator: ","))"
            case nil: return key
            }
        }
        return answers.isEmpty ? base : "\(base) answers:\(answers.joined(separator: ";"))"
    }

    static func bundled(_ name: String) -> JSONValue? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url),
              var json = try? JSONValue.parse(data) else { return nil }
        if CommandLine.arguments.contains("-blackholeFont"), case var .object(top) = json, case var .object(config)? = top["components_config"] {
            config["fonts"] = .object(["Blackhole@400": .object(["ios": .string("https://10.255.255.1/blackhole.ttf")])])
            top["components_config"] = .object(config)
            json = .object(top)
        }
        return json
    }

    /// A template of the library (`{description, paywall}`), bundled from the spec's fixtures/templates, or a small component
    /// screen (carousel, tabs, video, multiple choice) from fixtures/components.
    static func template(_ name: String) -> JSONValue? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "templates")
                ?? Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "components"), let data = try? Data(contentsOf: url),
              let json = try? JSONValue.parse(data) else { return nil }
        return json["paywall"] ?? json
    }

    /// How a placement would show the template: the library names its display in the file name (`-bar`, `-slide-in`...);
    /// everything else is a full screen. A "Continue" that links to another screen (`screen:next`) opens `welcome`.
    private func presentTemplate(_ name: String) async {
        guard let json = Self.template(name) else {
            log = "error:template \(name) is not in the app bundle"
            return
        }
        let style: PresentationStyle?
        switch true {
        case name.hasSuffix("-toast"): style = .toast(seconds: 60)
        case name.hasSuffix("-bar"), name.hasSuffix("-banner"): style = .banner(top: true)
        case name.hasSuffix("-slide-in"): style = .sheet
        case name.hasSuffix("-drawer"), name.hasSuffix("-launcher"): style = .modal
        default: style = nil
        }
        await present(.json(json), style: style, screens: ["next": Self.template("welcome")].compactMapValues { $0 })
    }

    private func presentBundled(_ name: String, style: PresentationStyle? = nil, screens: [String: String] = [:]) async {
        guard let json = Self.bundled(name) else {
            log = "error:\(name).json is not in the app bundle"
            return
        }
        await present(.json(json), style: style, screens: screens.compactMapValues(Self.bundled))
    }

    private func present(_ source: ScreenSource, style: PresentationStyle? = nil, screens: [String: JSONValue] = [:]) async {
        log = "presenting" // the UI tests wait for this to change
        var options = PresentOptions()
        options.style = style
        options.screens = screens
        options.products = [
            "monthly": ProductInfo(price: 9.99, currency: "USD", period: .every(.month)),
            "annual": ProductInfo(price: 79.99, currency: "USD", period: .every(.year), offer: .init(price: 0, period: .every(.day, count: 7))),
        ]
        if launch.purchaseMode == "storekit", !storeProducts.isEmpty {
            // Real StoreKit 2 calls, answered by the StoreKit configuration file of the scheme (no money moves).
            options.products = Miniwall.products(from: storeProducts)
            options.onPurchase = Miniwall.storeKitPurchase(storeProducts)
            options.onRestore = Miniwall.storeKitRestore()
        } else {
            options.onPurchase = { request in
                log = "Buying \(request.packageId)..."
                try await Task.sleep(nanoseconds: 800_000_000)
                return launch.purchaseResult
            }
            options.onRestore = {
                try await Task.sleep(nanoseconds: 300_000_000)
                return launch.restoreResult
            }
        }
        options.onAction = { id, answers in
            log = "Action \(id), answers \(answers)"
            return true
        }
        options.onError = { log = "Error: \($0.localizedDescription)" }
        do {
            log = Self.describe(try await Miniwall.present(source, options: options))
        } catch {
            log = "error:\(error.localizedDescription)"
        }
    }
}

/// Launch arguments of the UI tests; the app behaves like the plain sample when none are given.
struct LaunchOptions {
    private let arguments = ProcessInfo.processInfo.arguments
    var uiTest: Bool { arguments.contains("-uitest") }
    var template: String? { value(after: "-tpl") }
    var purchaseMode: String { value(after: "-purchaseMode") ?? "fake" }
    var purchaseResult: Bool { value(after: "-purchaseResult") != "false" }
    var restoreResult: Bool { value(after: "-restoreResult") == "true" }

    private func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
    }
}

/// UI tests only: a tiny HTTP server in the app that plays the delivery API (`/v1/sdk/placements/<name>`,
/// `/v1/sdk/paywalls/<id>`, `/v1/sdk/events`) from the bundled placements.json / paywalls.json (the spec's mock-api/ui).
/// `setOffline(true)` makes it drop every connection: the SDK must fall back to its cached copy.
final class StubServer {
    static let shared = StubServer()
    private let queue = DispatchQueue(label: "miniwall.stub")
    private var listener: NWListener?
    private var offline = false

    func setOffline(_ value: Bool) { queue.sync { offline = value } }

    /// Starts listening on a free loopback port and returns it (once; later calls return the same port).
    func start() throws -> UInt16 {
        if let port = listener?.port?.rawValue { return port }
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        self.listener = listener
        return listener.port?.rawValue ?? 0
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { return connection.cancel() }
            if self.offline { return connection.cancel() }
            let target = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"
            let path = target.split(separator: "?").first.map(String.init) ?? target
            let (status, body) = self.response(method: String(request.prefix(while: { $0 != " " })), path: path)
            let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func response(method: String, path: String) -> (Int, Data) {
        let parts = path.split(separator: "/").map(String.init)
        if method == "POST", path == "/v1/sdk/events" { return (200, Data("{}".utf8)) }
        guard method == "GET", parts.count == 4, parts[0] == "v1", parts[1] == "sdk" else { return (404, Data("{}".utf8)) }
        let file = parts[2] == "placements" ? "placements" : "paywalls"
        let name = parts[3].removingPercentEncoding ?? parts[3]
        guard let url = Bundle.main.url(forResource: file, withExtension: "json"), let data = try? Data(contentsOf: url),
              let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let one = all[name],
              let body = try? JSONSerialization.data(withJSONObject: one) else { return (404, Data("{\"error\":{\"message\":\"unknown\"}}".utf8)) }
        return (200, body)
    }
}
