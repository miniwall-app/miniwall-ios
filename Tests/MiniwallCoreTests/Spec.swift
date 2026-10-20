import Foundation
import XCTest

/// The Miniwall spec (github.com/miniwall-app/miniwall-spec): fixtures, golden frames and logic vectors the tests run against.
/// The version this SDK is tested against is pinned in SPEC_VERSION; `scripts/fetch-spec.sh` puts it in `.spec/`.
/// `MINIWALL_SPEC_DIR` points at a checkout somewhere else.
enum Spec {
    static var dir: URL {
        if let path = ProcessInfo.processInfo.environment["MINIWALL_SPEC_DIR"], !path.isEmpty { return URL(fileURLWithPath: path) }
        // <repo>/Tests/MiniwallCoreTests/Spec.swift -> <repo>/.spec
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".spec")
    }
}

final class SpecPresenceTests: XCTestCase {
    func testTheSpecIsFetched() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Spec.dir.appendingPathComponent("fixtures/layout").path),
                      "The Miniwall spec is not at \(Spec.dir.path): run scripts/fetch-spec.sh")
    }
}
