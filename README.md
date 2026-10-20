# MiniwallSDK (iOS)

Show screens built in the Miniwall dashboard (paywalls, onboarding, offers, surveys) natively in
SwiftUI. Miniwall renders; your app sells: prices come from your app, purchases run in your code.

Status: preview, not yet tagged for release. Tested on an iPhone 17 simulator (iOS 27): `swift test` 75/75, UI tests, 77-template sweep (the sample app and the sweep are not in this repository). iOS 16+, Swift 5.9 (Xcode 15+).

## Install

Swift Package Manager: add this repository (or, for now, a local checkout) and pick the
`MiniwallSDK` product. CocoaPods (React Native, Flutter): `pod 'MiniwallCore', :path => '<miniwall-ios checkout>'`
and `pod 'MiniwallSDK', :path => '<miniwall-ios checkout>'`.

## Use

```swift
import MiniwallSDK

// At launch
Miniwall.configure(apiKey: "pk_...")

// Show a placement and wait until it closes
var options = PresentOptions()
options.products = Miniwall.products(from: ["monthly": monthly, "annual": annual]) // StoreKit 2 products
options.onPurchase = Miniwall.storeKitPurchase(["monthly": monthly, "annual": annual]) // or your own code
options.onRestore = Miniwall.storeKitRestore()
let result = try await Miniwall.present(placement: "upgrade", options: options)
switch result {
case let .purchased(packageId, _): print("bought", packageId)
case .closed, .restored, .action, .skipped: break
}
```

Inline (an onboarding step, a pricing section):

```swift
MiniwallView(.placement("onboarding"), options: options) { result in ... }
```

| API | What it does |
|---|---|
| `Miniwall.configure(apiKey:options:)` | API key, API URL, locale, color mode, analytics on/off, audience attributes, timeout |
| `Miniwall.setAttributes(_:)` | Audience attributes (`user.<key>`); read on the device, never sent |
| `Miniwall.present(_:options:from:)` | `.placement`, `.paywallId` or `.json`; returns `PurchaseResult` (`purchased`, `restored`, `closed`, `action`, `skipped`) |
| `Miniwall.preload(placements:)` | Fetches screens and images ahead |
| `Miniwall.reportPurchase(packageId:paywallId:)` | A purchase that finished later (credited to the screen where buy was tapped) |
| `Miniwall.reset(placements:)` | Forgets the device's visitor id and counters |
| `Miniwall.packageIds(in:)` | Package ids a screen uses (keys of `products`) |
| `PresentOptions` | `products`, `variablesPerPackage`, `customVariables`, `attributes`, `locale`, `colorMode`, `style`, `screens`, `onPurchase`, `onRestore`, `onAction`, `onAnswer`, `onOpenURL`, `onError` |

The placement's display maps to iOS: fullscreen → full screen cover, modal/drawer/launcher → page
sheet (form sheet on iPad), slide-in → sheet as tall as the content, banner → pinned strip that does
not block the app, toast → card that closes itself.

Privacy: no IDFA, no tracking; a random install id (cleared by `reset`) counts views for analytics,
frequency caps and A/B tests. `PrivacyInfo.xcprivacy` is included.

## Develop

The tests run against the [Miniwall spec](https://github.com/miniwall-app/miniwall-spec) (fixtures, golden frames, logic vectors). The version this SDK is tested against is pinned in `SPEC_VERSION`:

```bash
scripts/fetch-spec.sh   # puts it in .spec/ (or set MINIWALL_SPEC_DIR to your own checkout)
swift test              # core: layout goldens, logic vectors, components, sessions (macOS, no simulator)
```

`Example/` is a sample app (XcodeGen) with UI tests and a template sweep: see `Example/README.md`. It bundles the spec's ten example templates.
