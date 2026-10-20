# iOS sample app and UI tests

`ContentView.swift` is the sample; `MiniwallExampleApp.swift` its entry point. `project.yml` (XcodeGen) builds both and the
XCUITest bundle in `UITests/`. Needs a Mac with Xcode 15+. It bundles the spec's templates from `.spec/` (`scripts/fetch-spec.sh`); link a bigger spec folder there to sweep a bigger library.

```bash
brew install xcodegen
scripts/fetch-spec.sh               # the spec pinned in SPEC_VERSION -> .spec/
cd Example
xcodegen generate                  # writes MiniwallExample.xcodeproj (git-ignored)
xcodebuild test -project MiniwallExample.xcodeproj -scheme MiniwallExample \
  -destination 'platform=iOS Simulator,name=iPhone 17'
# optional, real StoreKit 2 purchase against Configuration.storekit:
MINIWALL_UITEST_STOREKIT=1 xcodebuild test ... -only-testing:MiniwallExampleUITests/MiniwallExampleUITests/testStoreKitConfigurationPurchase
```

Or `open MiniwallExample.xcodeproj` and press Cmd-U. Without XcodeGen: make an iOS App target, add this package
(product `MiniwallSDK`), add `ContentView.swift`, `MiniwallExampleApp.swift` and every file of `the spec's mock-api/ui/` to the app target,
a UI Testing Bundle target with `UITests/MiniwallExampleUITests.swift`, and `Configuration.storekit` in the scheme (Run > Options).

## What the tests cover

Open and Close; choose a plan, Subscribe (fake store, 0.8 s); cancelled purchase; Restore (restored / nothing to restore); swipe
down closes a modal; a three-screen flow with the screen's Back button and a required question (Continue disabled until answered);
finishing the flow reports the answers; offline (the last copy of a placement still shows, a never-loaded one errors); Apple's accessibility
audit (`performAccessibilityAudit`: element descriptions, traits, hit regions, clipped text; it stands in for VoiceOver on a device, colour contrast and
Dynamic Type are left out on purpose, see the comment in the test); a custom font whose server never answers must not hold the screen back (launch argument
`-blackholeFont`); StoreKit purchase (opt-in). The suite passes on an iPhone 17 and an iPad Pro 13" simulator (iOS 27).

## How it works

- Launch argument `-uitest` makes the app start a tiny HTTP server (`StubServer` in `ContentView.swift`) that plays the delivery API
  from the bundled `placements.json` / `paywalls.json`, and configure the SDK with it. `toggle-offline` makes it drop connections.
- The screens are `the spec's mock-api/ui/*.json`, shared with the Android, React Native and Flutter suites. The Kotlin core test
  `UiFixturesTest` checks (at cloud) that they behave as these tests expect.
- Identifiers in the sample: `present-placement`, `present-missing`, `toggle-offline`, `present-paywall`, `present-paywall-modal`,
  `present-flow`, `present-sample`, `result`. The text in `result` is `purchased:<package>`, `restored`, `closed`, `action:<id>`,
  `skipped:<reason>` (+ ` answers:k=v`) or `error:<message>`. The SDK's own views are found by label, as VoiceOver reads them.
- Other launch arguments: `-purchaseResult false`, `-restoreResult true`, `-purchaseMode storekit`.

Build from a folder outside iCloud Drive / Desktop and Documents sync: their extended attributes make Xcode's `codesign` fail
("resource fork, Finder information, or similar detritus not allowed"). `xcodebuild ... -derivedDataPath <folder outside iCloud>` and `swift test --scratch-path <folder>` keep the products out of it; if the sources are synced too, copy the checkouts out first.

## Template sweep (all 77 templates)

`UITests/MiniwallTemplateTests.swift` presents every template of `the spec's fixtures/templates` (the app takes
`-tpl <name>`; the file name says how it shows: `-bar`/`-banner` banner, `-toast` toast, `-slide-in` sheet, `-drawer`/`-launcher`
modal, otherwise full screen) and fails when the app crashes, reports an error or shows a blank screen. It also runs at the largest
text size. Each screenshot is attached to the result bundle. It is skipped unless asked for (about 9 s per template, 12 minutes for all 77):

```bash
TEST_RUNNER_MINIWALL_TEMPLATES=all xcodebuild test -project MiniwallExample.xcodeproj -scheme MiniwallExample \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MiniwallExampleUITests/MiniwallTemplateTests
# or a few: TEST_RUNNER_MINIWALL_TEMPLATES=calm-money,notice-bar
# the small carousel / tabs / video / multiple-choice screens (B156, the spec's fixtures/components): TEST_RUNNER_MINIWALL_TEMPLATES=components
```

By hand: `-tpl carousel-pages`, `carousel-peek`, `tabs-buttons`, `tabs-toggle`, `video-basic`, `choice-multiple`. Swipe the carousel, tap the tab buttons / toggle, play the video, choose two options of the question (the third turns off).

It cannot see a clipped line of text or a wrong icon; look at the attached screenshots (or the dark and large-text runs) for those.

## Sweeping the React Native and Flutter samples on iOS

`xcrun simctl openurl booted miniwall-example://present?tpl=<name>` (what the template sweep scripts do) makes iOS ask "Open in ...?", and nothing taps that
button from the command line. `UITests/AcceptOpenAlerts.swift` is a helper, not a test of the SDK: run it next to the sweep and it taps "Open" for as long as you ask:

```bash
TEST_RUNNER_MINIWALL_ACCEPT_MINUTES=90 xcodebuild test -project MiniwallExample.xcodeproj -scheme MiniwallExample \
  -destination 'platform=iOS Simulator,id=<the simulator the sweep uses>' -only-testing:MiniwallExampleUITests/AcceptOpenAlerts
```

Keep one simulator booted while sweeping (`booted` means "the booted one"). A late tap can open the previous template behind a banner or toast.
