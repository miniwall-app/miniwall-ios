import Foundation
import XCTest
@testable import MiniwallCore

/// Every layout fixture in the Miniwall spec must produce the same frames as the web
/// renderer (golden/layout/<name>.json), within `tolerance` pt, at every golden viewport.
/// Same check as the Android SDK's GoldenLayoutTest.
final class GoldenLayoutTests: XCTestCase {
    /// Layout-only fixtures have no text, so frames must match closely (Chrome rounds to 1/64 px).
    private let tolerance = 0.1

    func testLayoutMatchesWebGoldens() throws {
        let fixtureDir = Spec.dir.appendingPathComponent("fixtures/layout")
        let fixtures = try FileManager.default.contentsOfDirectory(at: fixtureDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(fixtures.isEmpty, "no fixtures in \(fixtureDir.path)")

        var failures: [String] = []
        for fixtureURL in fixtures {
            let name = fixtureURL.deletingPathExtension().lastPathComponent
            let goldenURL = Spec.dir.appendingPathComponent("golden/layout/\(name).json")
            guard let goldenData = try? Data(contentsOf: goldenURL) else {
                failures.append("\(name): no golden (run pnpm golden:render)")
                continue
            }
            let fixture = try JSONValue.parse(Data(contentsOf: fixtureURL))
            let paywall = try PaywallData.decode(XCTUnwrap(fixture["paywall"]))
            let root = try XCTUnwrap(LayoutNode.from(.stack(paywall.base.stack)), "\(name): root not rendered")
            let viewports = try XCTUnwrap(JSONValue.parse(goldenData)["viewports"]?.objectValue)

            for (viewport, data) in viewports.sorted(by: { $0.key < $1.key }) {
                let size = viewport.split(separator: "x").compactMap { Double($0) }
                let frames = LayoutEngine.layoutScreen(root, screenWidth: size[0], screenHeight: size[1])
                for (id, rect) in (data["nodes"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                    let expected = ["x", "y", "w", "h"].map { rect[$0]?.doubleValue ?? .nan }
                    guard let actual = frames[id] else {
                        // display: none on the web (visible: false) reports an empty rect; native drops the node.
                        if expected.allSatisfy({ $0 == 0 }) { continue }
                        failures.append("\(name)@\(viewport) \(id): missing")
                        continue
                    }
                    let got = [actual.x, actual.y, actual.width, actual.height]
                    if zip(got, expected).contains(where: { abs($0 - $1) > tolerance }) {
                        failures.append("\(name)@\(viewport) \(id): expected \(format(expected)) got \(format(got))")
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) layout mismatches:\n" + failures.joined(separator: "\n"))
    }

    private func format(_ values: [Double]) -> String {
        "(" + values.map { String(format: "%.2f", $0) }.joined(separator: ", ") + ")"
    }
}
