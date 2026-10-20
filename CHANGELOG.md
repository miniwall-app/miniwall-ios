## 0.1.0

- First preview of `MiniwallCore` and `MiniwallSDK` (Swift Package Manager and CocoaPods).
- `Miniwall.configure`, `setAttributes`, `present` (`.placement`, `.paywallId`, `.json`), `preload`, `reportPurchase`, `reset`, `packageIds`, and `MiniwallView` for inline screens.
- Screens built in the Miniwall dashboard are drawn natively in SwiftUI. Prices and purchases stay in your app (StoreKit 2 helpers included).
- No IDFA and no tracking; `PrivacyInfo.xcprivacy` is included.
- A screen waits at most 1.5 s for its custom fonts, then shows with the system font; a font that arrives later is kept for the next screen. `Miniwall.preload` waits up to 10 s.
