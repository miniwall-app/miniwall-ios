import Foundation
import XCTest
@testable import MiniwallCore

/// Same cases on every platform SDK.
final class SessionTests: XCTestCase {
    private func screen(_ id: String, _ components: String) -> JSONValue {
        JSONValue.parse(string: """
        {"id":"\(id)","default_locale":"en_US","components_localizations":{"en_US":{}},
         "components_config":{"base":{"stack":{"type":"stack","id":"root","size":{"width":{"type":"fill"},"height":{"type":"fill"}},
         "dimension":{"type":"vertical","alignment":"center","distribution":"start"},"components":[\(components)]}}}}
        """)!
    }

    private func button(_ id: String, onPress: String) -> String {
        """
        {"type":"button","id":"\(id)","name":"\(id)","action":{"type":"workflow"},"triggers":{"on_press":"\(onPress)"},
         "stack":{"type":"stack","id":"\(id)s","components":[],"size":{"width":{"type":"fixed","value":40},"height":{"type":"fixed","value":40}},"dimension":{"type":"vertical"}}}
        """
    }

    private func pkg(_ id: String) -> String {
        #"{"type":"package","id":"pk\#(id)","package_id":"\#(id)","stack":{"type":"stack","id":"pks\#(id)","components":[],"size":{"width":{"type":"fixed","value":40},"height":{"type":"fixed","value":40}},"dimension":{"type":"vertical"}}}"#
    }

    private let buy = #"{"type":"purchase_button","id":"buy","stack":{"type":"stack","id":"buys","components":[],"size":{"width":{"type":"fixed","value":40},"height":{"type":"fixed","value":40}},"dimension":{"type":"vertical"}}}"#

    private final class Host: SessionHost {
        var purchaseResult: Result<Bool, Error> = .success(true)
        var actionProceeds = true
        /// When set, `purchase` waits: the test answers later through `answerPurchase`.
        var deferPurchase = false
        private var waiting: ((Result<Bool, Error>) -> Void)?
        func answerPurchase(_ result: Result<Bool, Error>) { let w = waiting; waiting = nil; w?(result) }
        var shown: [ScreenController] = []
        var result: PurchaseResult?
        var errors: [Error] = []
        func purchase(packageId: String, answers: [String: Flow.Answer], done: @escaping (Result<Bool, Error>) -> Void) { if deferPurchase { waiting = done } else { done(purchaseResult) } }
        func restore(done: @escaping (Result<Bool, Error>) -> Void) { done(.success(true)) }
        func action(actionId: String, answers: [String: Flow.Answer], done: @escaping (Bool) -> Void) { done(actionProceeds) }
        var opened: [String] = []
        func openURL(_ url: String) { opened.append(url) }
        func answer(fieldId: String, value: Flow.Answer?, answers: [String: Flow.Answer]) {}
        func error(_ error: Error) { errors.append(error) }
        func show(_ controller: ScreenController, animated: Bool) { shown.append(controller) }
        func finish(_ result: PurchaseResult) { self.result = result }
        func busy(_ isBusy: Bool) {}
    }

    private func session(_ first: JSONValue, screens: [String: JSONValue] = [:], host: Host, events: @escaping (JSONValue) -> Void, memory: DeviceMemory = DeviceMemory(store: MemoryStore())) -> PaywallSession {
        PaywallSession(
            first: Resolved(paywall: first, context: EventContext(paywallId: "p1", version: 3, placement: "onboarding")),
            memory: memory,
            enqueue: events,
            loadScreen: { id, done in
                if let s = screens[id] { done(.success(Resolved(paywall: s, context: EventContext(paywallId: id, version: 1)))) } else { done(.failure(MiniwallError("missing"))) }
            },
            controllerFactory: { json, answers, onEvent in
                ScreenController(paywall: json, locale: "en_US", dark: false, variablesPerPackage: [:], baseVariables: [:], infoPerPackage: [:],
                                 showRestoreButton: true, initialAnswers: answers, onEvent: onEvent)
            },
            host: host
        )
    }

    private func tap(_ controller: ScreenController, _ predicate: (RenderNode) -> Bool) {
        var nodes: [RenderNode] = []
        controller.render(width: 375, height: 812, measurer: FakeMeasurer())!.root.walk { nodes.append($0) }
        controller.handle(nodes.first(where: predicate)!.action!)
    }

    private func isPurchase(_ n: RenderNode) -> Bool { if case .purchase? = n.action { return true }; return false }

    func testPurchaseReportsClickThenPurchaseAndFinishes() {
        let host = Host()
        var events: [JSONValue] = []
        let s = session(screen("p1", "\(pkg("monthly")),\(buy)"), host: host, events: { events.append($0) })
        tap(host.shown.last!, isPurchase)
        XCTAssertEqual(events.map { $0.str("type")! }, ["view", "purchase_click", "purchase"])
        XCTAssertEqual(events[0].str("placement"), "onboarding")
        XCTAssertEqual(host.result, .purchased(packageId: "monthly", answers: [:]))
        _ = s
    }

    func testCancelledPurchaseStaysOpen() {
        let host = Host()
        host.purchaseResult = .success(false)
        var events: [JSONValue] = []
        let s = session(screen("p1", "\(pkg("monthly")),\(buy)"), host: host, events: { events.append($0) })
        tap(host.shown.last!, isPurchase)
        XCTAssertEqual(events.map { $0.str("type")! }, ["view", "purchase_click", "purchase_cancel"])
        XCTAssertNil(host.result)
        _ = s
    }

    func testCloseWhilePurchasingWaitsForTheAnswer() {
        // A purchase that goes through after the visitor tried to close is still a purchase.
        let bought = Host()
        bought.deferPurchase = true
        let a = session(screen("p1", "\(pkg("monthly")),\(buy)"), host: bought, events: { _ in })
        tap(bought.shown.last!, isPurchase)
        a.close()
        XCTAssertNil(bought.result, "still waiting for the store")
        bought.answerPurchase(.success(true))
        guard case .purchased? = bought.result else { return XCTFail("expected purchased, got \(String(describing: bought.result))") }

        // Cancelled: the close the visitor asked for is applied after the answer.
        let cancelled = Host()
        cancelled.deferPurchase = true
        var events: [JSONValue] = []
        let b = session(screen("p1", "\(pkg("monthly")),\(buy)"), host: cancelled, events: { events.append($0) })
        tap(cancelled.shown.last!, isPurchase)
        b.close()
        cancelled.answerPurchase(.success(false))
        guard case .closed? = cancelled.result else { return XCTFail("expected closed, got \(String(describing: cancelled.result))") }
        XCTAssertEqual(events.map { $0.str("type")! }, ["view", "purchase_click", "purchase_cancel", "close"])
    }

    func testGoToScreenCountsUnderThePlacementAndBackReturns() {
        let host = Host()
        var events: [JSONValue] = []
        let second = screen("p2", button("back", onPress: "screen:back"))
        let s = session(screen("p1", button("next", onPress: "screen:p2")), screens: ["p2": second], host: host, events: { events.append($0) })
        tap(host.shown.last!) { $0.type == "button" }
        XCTAssertEqual(host.shown.count, 2)
        XCTAssertEqual(events.last?.str("paywallId"), "p2")
        XCTAssertEqual(events.last?.str("placement"), "onboarding")
        tap(host.shown.last!) { $0.type == "button" }
        XCTAssertEqual(host.shown.count, 3)
        XCTAssertNil(host.result)
        _ = s
    }

    func testCustomActionFinishesUnlessKeptOpen() {
        let host = Host()
        host.actionProceeds = false
        var events: [JSONValue] = []
        let s = session(screen("p1", button("go", onPress: "get_started")), host: host, events: { events.append($0) })
        tap(host.shown.last!) { $0.type == "button" }
        XCTAssertNil(host.result)
        host.actionProceeds = true
        tap(host.shown.last!) { $0.type == "button" }
        XCTAssertEqual(host.result, .action(actionId: "get_started", answers: [:]))
        _ = s
    }

    /// Web parity: `complete_workflow` is pressable but the Web SDK never wires `onCompleteWorkflowNavigate`
    /// (as the Web SDK does), so the press does nothing: no URL opened, no event, no result, no close, no onAction.
    func testCompleteWorkflowDoesNothingLikeTheWebSdk() {
        let host = Host()
        var events: [JSONValue] = []
        let json = JSONValue.parse(string: """
        {"id":"p1","default_locale":"en_US","components_localizations":{"en_US":{"u":"https://example.com/done"}},
         "components_config":{"base":{"stack":{"type":"stack","id":"root","size":{"width":{"type":"fill"},"height":{"type":"fill"}},
         "dimension":{"type":"vertical"},"components":[{"type":"button","id":"done","name":"done","action":{"type":"complete_workflow","url":{"url_lid":"u","method":"external_browser"}},
         "stack":{"type":"stack","id":"dones","components":[],"size":{"width":{"type":"fixed","value":40},"height":{"type":"fixed","value":40}},"dimension":{"type":"vertical"}}}]}}}}
        """)!
        let s = session(json, host: host, events: { events.append($0) })
        tap(host.shown.last!) { $0.type == "button" }
        XCTAssertTrue(host.opened.isEmpty)
        XCTAssertTrue(host.errors.isEmpty)
        XCTAssertNil(host.result)
        XCTAssertEqual(events.compactMap { $0.str("type") }, ["view"])
        XCTAssertEqual(host.shown.count, 1)
        _ = s
    }

    func testFrequencyCapHoldoutAndAudiences() {
        let memory = DeviceMemory(store: MemoryStore())
        let input = TargetingInput(attributes: [:], locale: "en_US", device: "mobile", platform: "ios")
        let body = JSONValue.parse(string: #"{"paywall":\#(screen("p1", "").jsonString),"paywallId":"p1","placement":"home","frequency":{"max":1,"per":"ever"}}"#)!
        XCTAssertNil(Delivery.decide(body, input: input, memory: memory).skip)
        memory.recordShown("home")
        XCTAssertEqual(Delivery.decide(body, input: input, memory: memory).skip, .frequencyCap)
        let held = JSONValue.parse(string: #"{"paywall":\#(screen("p1", "").jsonString),"paywallId":"p1","placement":"x","holdout":{"id":"h","share":100}}"#)!
        XCTAssertEqual(Delivery.decide(held, input: input, memory: memory).skip, .holdout)
        let rules = JSONValue.parse(string: #"""
        {"paywall":\#(screen("p1", "").jsonString),"paywallId":"p1","placement":"home2","rules":[
          {"id":"r1","conditions":[{"field":"user.plan","op":"eq","value":"pro"}],"paywall":null},
          {"id":"r2","conditions":[{"field":"platform","op":"eq","value":"ios"}],"paywall":{"paywall":\#(screen("p9", "").jsonString),"paywallId":"p9"}}]}
        """#)!
        var pro = input
        pro.attributes = ["plan": .string("Pro")]
        XCTAssertEqual(Delivery.decide(rules, input: pro, memory: memory).skip, .audience)
        var free = input
        free.attributes = ["plan": .string("free")]
        XCTAssertEqual(Delivery.decide(rules, input: free, memory: memory).context?.paywallId, "p9")
        free.platform = "android"
        XCTAssertEqual(Delivery.decide(rules, input: free, memory: memory).context?.paywallId, "p1")
    }

    func testLaterPurchaseIsCreditedToTheScreenWhereBuyWasTapped() {
        let memory = DeviceMemory(store: MemoryStore())
        let host = Host()
        host.purchaseResult = .failure(MiniwallError("store busy"))
        var events: [JSONValue] = []
        let s = session(screen("p1", "\(pkg("annual")),\(buy)"), host: host, events: { events.append($0) }, memory: memory)
        tap(host.shown.last!, isPurchase)
        XCTAssertFalse(host.errors.isEmpty)
        PaywallSession.reportPurchase(memory: memory, enqueue: { events.append($0) }, packageId: nil, paywallId: nil)
        XCTAssertEqual(events.last?.str("type"), "purchase")
        XCTAssertEqual(events.last?.str("packageId"), "annual")
        XCTAssertEqual(events.last?.str("paywallId"), "p1")
        _ = s
    }
}
