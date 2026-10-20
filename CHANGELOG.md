## 0.1.0

- First preview of `MiniwallCore` and `MiniwallSDK` (Swift Package Manager and CocoaPods).
- `Miniwall.configure`, `setAttributes`, `present` (`.placement`, `.paywallId`, `.json`), `preload`, `reportPurchase`, `reset`, `packageIds`, and `MiniwallView` for inline screens.
- Screens built in the Miniwall dashboard are drawn natively in SwiftUI. Prices and purchases stay in your app (StoreKit 2 helpers included).
- No IDFA and no tracking; `PrivacyInfo.xcprivacy` is included.
