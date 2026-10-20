import Foundation
import XCTest
@testable import MiniwallCore

/// Same cases as the Android SDK's AutoTriggersTest.
final class AutoTriggersTests: XCTestCase {
    private let body = JSONValue.parse(string: """
    {"placements":[
      {"placement":"welcome","trigger":{"type":"app_open","pages":[],"priority":1}},
      {"placement":"rate","trigger":{"type":"app_open","every":3,"pages":[],"priority":9}},
      {"placement":"level","trigger":{"type":"event","event":"level_completed","pages":[],"priority":0}},
      {"placement":"later","trigger":{"type":"delay","seconds":4,"pages":[],"priority":0}},
      {"placement":"web","trigger":{"type":"page_load","pages":[],"priority":0}},
      {"placement":"broken","trigger":{"type":"event","pages":[],"priority":0}}
    ]}
    """)!

    func testAppOpensFireEveryNthByPriorityAndPersist() {
        let store = MemoryStore()
        let triggers = AutoTriggers(store: store)
        triggers.load(body)
        XCTAssertEqual(triggers.triggers.map(\.placement).sorted(), ["later", "level", "rate", "welcome"])
        XCTAssertEqual(triggers.appOpened().now, ["welcome"])
        XCTAssertEqual(triggers.appOpened().now, ["welcome"])
        // The third open reaches "rate" (every 3rd), which has the higher priority.
        let third = triggers.appOpened()
        XCTAssertEqual(third.now, ["rate", "welcome"])
        XCTAssertEqual(third.delayed, [AppOpened.Delayed(placement: "later", seconds: 4)])
        // The count survives a restart.
        let again = AutoTriggers(store: store)
        again.load(body)
        XCTAssertEqual(again.appOpened().now, ["welcome"])
    }

    func testEventsMatchByName() {
        let triggers = AutoTriggers(store: MemoryStore())
        triggers.load(body)
        XCTAssertEqual(triggers.event("level_completed"), ["level"])
        XCTAssertEqual(triggers.event("other"), [])
    }
}
