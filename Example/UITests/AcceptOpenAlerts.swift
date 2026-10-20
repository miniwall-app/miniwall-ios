// Helper for the template sweeps of the React Native and Flutter samples on a simulator (not a test of the SDK).
// `xcrun simctl openurl booted miniwall-example://present?tpl=<name>` makes iOS ask "Open in <app>?"; nothing taps the button
// from the command line. Run this alongside the sweep and it taps "Open" for as long as you ask:
//   TEST_RUNNER_MINIWALL_ACCEPT_MINUTES=90 xcodebuild test -project MiniwallExample.xcodeproj -scheme MiniwallExample \
//     -destination 'platform=iOS Simulator,name=<the simulator the sweep uses>' -only-testing:MiniwallExampleUITests/AcceptOpenAlerts
// then start the sweep script of the sample you are testing (React Native or Flutter) in another terminal. Skipped unless the variable is set.
import XCTest

final class AcceptOpenAlerts: XCTestCase {
    func testAcceptOpenAlerts() throws {
        let minutes = Double(ProcessInfo.processInfo.environment["MINIWALL_ACCEPT_MINUTES"] ?? "") ?? 0
        try XCTSkipIf(minutes <= 0, "Helper for the RN/Flutter template sweeps: set TEST_RUNNER_MINIWALL_ACCEPT_MINUTES=<minutes>")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let end = Date().addingTimeInterval(minutes * 60)
        while Date() < end {
            let alert = springboard.alerts.firstMatch
            // Two buttons: Cancel, then Open.
            if alert.exists, alert.buttons.count >= 2 { alert.buttons.element(boundBy: 1).tap() }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }
}
