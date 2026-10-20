// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MiniwallSDK",
    // macOS is listed only so `swift test` runs the pure-Swift core on a Mac without a simulator.
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "MiniwallSDK", targets: ["MiniwallSDK"]),
    ],
    targets: [
        // Pure Swift (Foundation only): PaywallData model and the layout engine. Mirrors the Android SDK's core.
        .target(name: "MiniwallCore"),
        // SwiftUI renderer and the public API.
        .target(name: "MiniwallSDK", dependencies: ["MiniwallCore"], resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "MiniwallCoreTests", dependencies: ["MiniwallCore"]),
    ]
)
