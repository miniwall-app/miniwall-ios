import XCTest
@testable import MiniwallCore

final class AppIdentityTests: XCTestCase {
    private func v(_ op: String, _ actual: String?, _ expected: JSONValue) -> Bool {
        Targeting.matches(field: "app_version", op: op, expected: expected, actual: actual.map(JSONValue.string))
    }

    func testOrderingComparesVersionSegmentsAsNumbers() {
        XCTAssertTrue(v("gt", "1.10.0", .string("1.9.9")))
        XCTAssertTrue(v("gte", "2.0", .string("2.0.0")))
        XCTAssertTrue(v("lte", "2", .string("2.0.0")))
        XCTAssertFalse(v("gt", "2", .string("2.0.0")))
        XCTAssertTrue(v("lt", "1.2.3", .string("1.2.10")))
        XCTAssertTrue(v("gte", "3", .number(2)))
        XCTAssertTrue(v("lt", "01.2", .string("1.3")))
        XCTAssertTrue(v("gt", "99999999999999999999.0", .string("1.0")))
    }

    func testASegmentThatIsNotANumberNeverMatches() {
        for op in ["gt", "gte", "lt", "lte"] {
            XCTAssertFalse(v(op, "2.0-beta", .string("1.0")), op)
            XCTAssertFalse(v(op, "2.0.x", .string("1.0")), op)
            XCTAssertFalse(v(op, "1.0", .string("1.x")), op)
            XCTAssertFalse(v(op, "1..2", .string("1.0")), op)
            XCTAssertFalse(v(op, "", .string("1.0")), op)
            XCTAssertFalse(v(op, nil, .string("1.0")), op)
        }
    }

    func testOtherOperatorsStayTextual() {
        XCTAssertTrue(v("eq", "2.3.1", .string("2.3.1")))
        XCTAssertTrue(v("neq", "2.3.1", .string("2.3.2")))
        XCTAssertTrue(v("contains", "2.3.1", .string(".3.")))
        XCTAssertTrue(v("starts_with", "2.3.1", .string("2.")))
        XCTAssertTrue(Targeting.matches(field: "app_version", op: "exists", expected: nil, actual: .string("1.0")))
        XCTAssertTrue(Targeting.matches(field: "os_version", op: "gte", expected: .number(16), actual: .string("17")))
        XCTAssertTrue(Targeting.matches(field: "user.build", op: "gt", expected: .string("1.0"), actual: .string("1.5")))
        XCTAssertFalse(Targeting.matches(field: "user.build", op: "gt", expected: .string("1.0"), actual: .string("1.2.3")))
    }

    func testAnAudienceOnAppVersionPicksTheScreen() {
        let memory = DeviceMemory(store: MemoryStore())
        let screen = #"{"components_config":{"base":{"stack":{}}},"components_localizations":{}}"#
        let body = JSONValue.parse(string: """
        {"paywall":\(screen),"paywallId":"p1","placement":"home","rules":[
          {"id":"r1","conditions":[{"field":"app_version","op":"gte","value":"2.10"}],"paywall":{"paywall":\(screen),"paywallId":"p2"}}]}
        """)!
        var input = TargetingInput(attributes: [:], locale: "en-US", device: "mobile", platform: "android", appVersion: "2.9.4")
        XCTAssertEqual(Delivery.decide(body, input: input, memory: memory).context?.paywallId, "p1")
        input.appVersion = "2.10.0"
        XCTAssertEqual(Delivery.decide(body, input: input, memory: memory).context?.paywallId, "p2")
        input.appVersion = nil
        XCTAssertEqual(Delivery.decide(body, input: input, memory: memory).context?.paywallId, "p1")
    }

    func testTheAppHeaderNamesPlatformAndId() {
        XCTAssertEqual(Events.appHeader(platform: "android", appId: "com.acme.app"), "android:com.acme.app")
        XCTAssertEqual(Events.appHeader(platform: "ios", appId: " com.acme.app "), "ios:com.acme.app")
        XCTAssertNil(Events.appHeader(platform: "ios", appId: nil))
        XCTAssertNil(Events.appHeader(platform: "android", appId: "  "))
    }

    func testEventsCarryPlatformAndVersionsWhenKnown() {
        let ctx = EventContext(paywallId: "p1", version: 3, placement: "home")
        let e = Events.event("view", ctx, visitorId: "visitor-1", occurredAtMs: 0, client: EventClient(platform: "ios", sdkVersion: "0.1.0", appVersion: "2.3.1"))
        XCTAssertEqual(e.str("platform"), "ios")
        XCTAssertEqual(e.str("sdkVersion"), "0.1.0")
        XCTAssertEqual(e.str("appVersion"), "2.3.1")
        let noApp = Events.event("view", ctx, visitorId: "visitor-1", occurredAtMs: 0, client: EventClient(platform: "android", sdkVersion: "0.1.0"))
        XCTAssertNil(noApp["appVersion"])
        XCTAssertEqual(noApp.str("platform"), "android")
        XCTAssertNil(Events.event("view", ctx, visitorId: "visitor-1", occurredAtMs: 0)["platform"])
    }
}
