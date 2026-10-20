// XCUITest suite for the Miniwall iOS SDK, driven through the sample app (ContentView.swift). Run on a Mac:
//   cd Example && xcodegen generate
//   xcodebuild test -project MiniwallExample.xcodeproj -scheme MiniwallExample \
//     -destination 'platform=iOS Simulator,name=iPhone 15'
// The app starts a local stand-in for the delivery API (-uitest) and shows bundled screens from the spec's mock-api/ui, so no account,
// network or backend is needed. What the SDK draws is found by its accessibility label (what VoiceOver reads); the sample's own
// controls by accessibilityIdentifier. Not compiled at cloud (no Swift/Xcode there): written against the real XCTest API.
import XCTest

final class MiniwallExampleUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest"]
    }

    /// Launches with extra arguments, e.g. `launch("-restoreResult", "true")`.
    private func launch(_ extra: String...) {
        app.launchArguments += extra
        app.launch()
    }

    // MARK: Helpers

    private func matching(_ label: String) -> NSPredicate { NSPredicate(format: "label CONTAINS %@ OR identifier == %@", label, label) }

    /// Any element a screen reader would announce with this text (static text, button...).
    private func element(_ label: String) -> XCUIElement { app.descendants(matching: .any).matching(matching(label)).firstMatch }

    private func button(_ label: String) -> XCUIElement { app.buttons.matching(matching(label)).firstMatch }

    @discardableResult
    private func waitFor(_ label: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let e = element(label)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "\"\(label)\" never appeared", file: file, line: line)
        return e
    }

    private func waitGone(_ label: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let e = element(label)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, "\"\(label)\" is still on screen", file: file, line: line)
    }

    private func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let b = button(label)
        XCTAssertTrue(b.waitForExistence(timeout: 10), "no button \"\(label)\"", file: file, line: line)
        b.tap()
    }

    private func tapSample(_ identifier: String) {
        let b = app.buttons[identifier]
        XCTAssertTrue(b.waitForExistence(timeout: 10), "sample button \(identifier) missing")
        b.tap()
    }

    /// The sample writes how the screen ended into the element `result` (e.g. `purchased:monthly`).
    private func assertResult(_ expected: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let result = app.staticTexts["result"]
        // The sample's text sits under the screen until it is dismissed: wait for it to exist, the predicate below fails at once when it does not.
        XCTAssertTrue(result.waitForExistence(timeout: timeout), "no element \"result\" (the screen is still open?)", file: file, line: line)
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", expected), object: result)
        let outcome = XCTWaiter().wait(for: [matches], timeout: timeout)
        XCTAssertEqual(outcome, .completed, "result is \"\(result.label)\", expected \"\(expected)\"", file: file, line: line)
    }

    // MARK: Open, choose, buy, restore, close

    func testOpenShowsTheScreenAndCloseButtonEndsItAsClosed() {
        launch()
        tapSample("present-paywall")
        waitFor("Go Pro")
        tap("Close")
        assertResult("closed")
        waitGone("Go Pro")
    }

    func testChoosingAPlanThenSubscribeBuysThatPlan() {
        launch()
        tapSample("present-paywall")
        waitFor("Go Pro")
        XCTAssertTrue(button("Annual").isSelected, "annual is selected by default")
        XCTAssertFalse(button("Monthly").isSelected)
        tap("Monthly")
        XCTAssertTrue(button("Monthly").isSelected)
        XCTAssertFalse(button("Annual").isSelected)
        // The price is formatted for the device's region ("$9.99", "US$9,99"): check the digits, not the separator.
        let monthly = button("Monthly").label
        XCTAssertTrue(monthly.contains("9.99") || monthly.contains("9,99"), "the price comes from the app: \(monthly)")
        tap("Subscribe")
        assertResult("purchased:monthly") // fake store: 0.8 s, then yes
    }

    func testCancelledPurchaseKeepsTheScreenOpen() {
        launch("-purchaseResult", "false")
        tapSample("present-paywall")
        waitFor("Go Pro")
        tap("Subscribe")
        sleep(2) // longer than the fake store
        XCTAssertTrue(element("Go Pro").exists, "a cancelled purchase does not close the screen")
        tap("Close")
        assertResult("closed")
    }

    func testRestoreWithSomethingToRestoreEndsRestored() {
        launch("-restoreResult", "true")
        tapSample("present-paywall")
        waitFor("Go Pro")
        tap("Restore purchases")
        assertResult("restored")
    }

    func testRestoreWithNothingToRestoreKeepsTheScreenOpen() {
        launch("-restoreResult", "false")
        tapSample("present-paywall")
        waitFor("Go Pro")
        tap("Restore purchases")
        sleep(1)
        XCTAssertTrue(element("Go Pro").exists)
        tap("Close")
        assertResult("closed")
    }

    func testSwipingTheModalDownClosesIt() {
        launch()
        tapSample("present-paywall-modal")
        waitFor("Go Pro")
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        from.press(forDuration: 0.1, thenDragTo: to)
        assertResult("closed")
    }

    // MARK: Flow, required question

    func testFlowWithARequiredQuestionAndBack() {
        launch()
        tapSample("present-flow")
        waitFor("Welcome aboard")
        tap("Next")
        waitFor("What is your goal?")
        XCTAssertFalse(button("Continue").isEnabled, "required question: Continue waits for an answer")
        tap("Lose weight")
        XCTAssertTrue(button("Lose weight").isSelected)
        XCTAssertTrue(button("Continue").isEnabled)
        tap("Continue")
        waitFor("All set")
        tap("Back") // the screen's own Back button = screen:back
        waitFor("What is your goal?")
        XCTAssertTrue(button("Lose weight").isSelected, "the answer survives going back")
        tap("Back")
        waitFor("Welcome aboard")
        tap("Close") // first screen: nowhere to go back to
        assertResult("closed answers:goal=lose_weight")
    }

    func testFinishingTheFlowReportsTheAnswersWithTheAction() {
        launch()
        tapSample("present-flow")
        waitFor("Welcome aboard")
        tap("Next")
        waitFor("What is your goal?")
        tap("Build strength")
        tap("Continue")
        waitFor("All set")
        tap("Finish")
        assertResult("action:finish answers:goal=strength")
    }

    // MARK: Offline

    func testOfflineTheLastCopyOfAPlacementStillShows() {
        launch()
        tapSample("present-placement") // online: served by the stand-in, cached by the SDK
        waitFor("Go Pro")
        tap("Close")
        assertResult("closed")
        waitGone("Go Pro")

        tapSample("toggle-offline") // every connection is now dropped
        tapSample("present-placement")
        waitFor("Go Pro") // served from the cache
        tap("Close")
        assertResult("closed")
        waitGone("Go Pro")

        tapSample("present-missing") // never loaded, no cache, no network
        assertResult("error")
    }

    // MARK: StoreKit (optional)

    // MARK: Fonts

    /// A custom font whose server never answers must not hold the screen back for the font download's 6 s timeout.
    func testAFontThatNeverArrivesDoesNotHoldTheScreenBack() {
        launch("-blackholeFont")
        let started = Date()
        tapSample("present-paywall")
        waitFor("Go Pro")
        let seconds = Date().timeIntervalSince(started)
        XCTAssertLessThan(seconds, 6.5, "the screen took \(seconds) s to show (the fonts' wait is limited to 1.5 s)")
        tap("Close")
        assertResult("closed")
    }

    // MARK: Accessibility (Apple's audit stands in for VoiceOver on a device)

    /// Runs the system accessibility audit on a screen: every control has a description and a trait, hit regions are large enough,
    /// nothing is clipped. Left out: colour contrast (it follows the screen's own design) and Dynamic Type (the SDK caps text growth at `maxFontScale`, 1.6 by default, so the audit reports it as partly supported).
    private func auditAccessibility(file: StaticString = #filePath, line: UInt = #line) throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("performAccessibilityAudit needs iOS 17") }
        var issues: [String] = []
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection, .trait, .textClipped]) { issue in
            issues.append("\(issue.auditType.rawValue): \(issue.compactDescription) [\(issue.element?.label ?? "-")]")
            return true
        }
        XCTAssertTrue(issues.isEmpty, "accessibility audit:\n" + issues.joined(separator: "\n"), file: file, line: line)
    }

    func testAccessibilityAuditOfThePaywall() throws {
        launch()
        tapSample("present-paywall")
        waitFor("Go Pro")
        try auditAccessibility()
    }

    func testAccessibilityAuditOfAFlowQuestion() throws {
        launch()
        tapSample("present-flow")
        waitFor("Welcome aboard")
        tap("Next")
        waitFor("What is your goal?")
        try auditAccessibility()
    }

    /// Buys through StoreKit 2 against Configuration.storekit (no money moves). The purchase sheet is system UI whose
    /// layout changes between iOS versions, so this runs only when asked: MINIWALL_UITEST_STOREKIT=1 xcodebuild test ...
    func testStoreKitConfigurationPurchase() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MINIWALL_UITEST_STOREKIT"] == "1", "set MINIWALL_UITEST_STOREKIT=1 to run")
        launch("-purchaseMode", "storekit")
        sleep(2) // the sample loads its products from StoreKit
        tapSample("present-paywall")
        waitFor("Go Pro")
        tap("Monthly")
        tap("Subscribe")
        // The purchase confirmation is drawn by the system; find its confirm button in the app or in SpringBoard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let candidates = ["Subscribe", "Buy", "Confirm"].flatMap { [app.buttons[$0], springboard.buttons[$0]] }
        // On recent simulators the test configuration confirms the purchase by itself and the sheet is gone before it can be tapped.
        let result = app.staticTexts["result"]
        let confirm = candidates.first { $0.waitForExistence(timeout: 5) }
        if let confirm, confirm.exists, confirm.isHittable, result.label != "purchased:monthly" { confirm.tap() }
        assertResult("purchased:monthly", timeout: 30)
    }
}
