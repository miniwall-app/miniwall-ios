import Foundation
import XCTest
@testable import MiniwallCore

/// Same checks as the Android SDK's SvgTest: every icon the templates use must have the
/// bounding box the browser computes (golden/icons), and path commands must reduce correctly.
final class SvgTests: XCTestCase {
    private func load(_ path: String) throws -> [String: JSONValue] {
        let url = Spec.dir.appendingPathComponent(path)
        return try XCTUnwrap(JSONValue.parse(Data(contentsOf: url)).objectValue)
    }

    /// Curves are sampled, so the box is the geometry's (like SVG getBBox).
    private func bounds(_ icon: SvgIcon) -> [Double] {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        func add(_ x: Double, _ y: Double) {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
        for shape in icon.shapes {
            var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0
            for op in shape.ops {
                switch op {
                case let .move(px, py): x = px; y = py; sx = x; sy = y; add(x, y)
                case let .line(px, py): x = px; y = py; add(x, y)
                case let .cubic(x1, y1, x2, y2, px, py):
                    for k in 1...200 {
                        let t = Double(k) / 200, u = 1 - t
                        add(u * u * u * x + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * px,
                            u * u * u * y + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * py)
                    }
                    x = px; y = py
                case .close: x = sx; y = sy
                }
            }
        }
        return [minX, minY, maxX - minX, maxY - minY]
    }

    func testEveryTemplateIconMatchesTheBrowsersGeometry() throws {
        let icons = try load("fixtures/icons/icons.json")
        let golden = try load("golden/icons/icons.json")
        XCTAssertGreaterThanOrEqual(icons.count, 80)
        for (name, source) in icons {
            let icon = try XCTUnwrap(Svg.parse(source.stringValue ?? ""), name)
            XCTAssertEqual(icon.width, 24, name)
            let actual = bounds(icon)
            for (i, key) in ["x", "y", "w", "h"].enumerated() {
                let want = try XCTUnwrap(golden[name]?[key]?.doubleValue)
                XCTAssertLessThan(abs(actual[i] - want), 0.02, "\(name) \(key): \(actual[i]) vs \(want)")
            }
        }
    }

    func testLucideIconsStrokeAndMdiFills() throws {
        let icons = try load("fixtures/icons/icons.json")
        let check = try XCTUnwrap(Svg.parse(icons["lucide/check"]?.stringValue ?? ""))
        XCTAssertTrue(check.shapes.allSatisfy { $0.stroke && !$0.fill && $0.strokeWidth == 2 && $0.roundCap && $0.roundJoin })
        let star = try XCTUnwrap(Svg.parse(icons["mdi/star"]?.stringValue ?? ""))
        XCTAssertTrue(star.shapes.allSatisfy { $0.fill && !$0.stroke })
    }

    func testRelativeSmoothQuadraticAndArcCommands() {
        XCTAssertEqual(Svg.parsePath("m1 1h2v3z"), [.move(1, 1), .line(3, 1), .line(3, 4), .close])
        XCTAssertEqual(Svg.parsePath("m1 1 1 2"), [.move(1, 1), .line(2, 3)])
        XCTAssertEqual(Svg.parsePath("M0 0C1 1 2 1 3 0S5 -1 6 0")[2], .cubic(4, -1, 5, -1, 6, 0))
        XCTAssertEqual(Svg.parsePath("M0 0Q3 3 6 0")[1], .cubic(2, 2, 4, 2, 6, 0))
        // Arc flags without separators: a half circle of radius 1 splits in two quarter arcs.
        let arc = Svg.parsePath("M0 0a1 1 0 012 0")
        XCTAssertEqual(arc.count, 3)
        guard case let .cubic(_, _, _, _, x, _) = arc[2] else { return XCTFail("last op is not a cubic") }
        XCTAssertEqual(x, 2)
        // A drawing command after Z starts from the subpath start.
        XCTAssertEqual(Svg.parsePath("M0 0L1 0ZL0 1")[3], .move(0, 0))
    }

    func testShapesBecomePaths() throws {
        let svg = #"<svg viewBox="0 0 10 10"><g fill="none" stroke="currentColor" stroke-width="3"><rect x="1" y="1" width="8" height="8" rx="2"/><line x1="0" y1="0" x2="5" y2="5"/><polygon points="0,0 4,0 4,4"/></g></svg>"#
        let icon = try XCTUnwrap(Svg.parse(svg))
        XCTAssertEqual(icon.shapes.count, 3)
        XCTAssertTrue(icon.shapes.allSatisfy { $0.stroke && !$0.fill && $0.strokeWidth == 3 })
        let rounded = try XCTUnwrap(Svg.parse(#"<svg viewBox="0 0 10 10"><rect x="1" y="1" width="8" height="8" rx="2" fill="red"/></svg>"#))
        for (i, want) in [1.0, 1.0, 8.0, 8.0].enumerated() { XCTAssertEqual(bounds(rounded)[i], want, accuracy: 0.01) }
    }

    func testFillRuleIsInheritedFromTheGroup() throws {
        let icon = try XCTUnwrap(Svg.parse(#"<svg viewBox="0 0 10 10"><g fill-rule="evenodd"><path d="M0 0H10V10H0Z"/></g><path d="M0 0H5V5H0Z"/></svg>"#))
        XCTAssertEqual(icon.shapes.map(\.evenOdd), [true, false])
    }

    func testUnusableInputIsNil() {
        XCTAssertNil(Svg.parse("not svg"))
        XCTAssertNil(Svg.parse(#"<svg viewBox="0 0 24 24"></svg>"#))
        XCTAssertNil(Svg.parse(#"<svg viewBox="0 0 24 24"><path d="M0 0L1 1" fill="none"/></svg>"#))
        XCTAssertEqual(Svg.parsePath("M0 0L1 1L"), [.move(0, 0), .line(1, 1)])
    }
}
