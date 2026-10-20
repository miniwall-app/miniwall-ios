import Foundation
import XCTest
@testable import MiniwallCore

final class ScreenTests: XCTestCase {
    private var templatesDir: URL { Spec.dir.appendingPathComponent("fixtures/templates") }

    private func templateNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: templatesDir.path).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    private func paywall(_ name: String) throws -> JSONValue {
        try XCTUnwrap(JSONValue.parse(Data(contentsOf: templatesDir.appendingPathComponent("\(name).json")))["paywall"])
    }

    private func raw(_ name: String) throws -> String {
        try String(contentsOf: templatesDir.appendingPathComponent("\(name).json"), encoding: .utf8)
    }

    private func controller(_ json: JSONValue, vars: [String: [String: String]] = [:], onEvent: @escaping (ScreenEvent) -> Void = { _ in }) -> ScreenController {
        ScreenController(paywall: json, locale: "en_US", dark: false, variablesPerPackage: vars, baseVariables: [:], infoPerPackage: [:],
                         showRestoreButton: true, onEvent: onEvent)
    }

    private func nodes(_ render: ScreenRender) -> [RenderNode] {
        var out: [RenderNode] = []
        [render.header, render.root, render.footer, render.sheet].compactMap { $0 }.forEach { $0.walk { out.append($0) } }
        return out
    }

    func testFontScaleGrowsTextAndTheScreenFollows() throws {
        let json = try paywall("two-plans")
        func measure(_ scale: Double) throws -> (sizes: [Double], bottom: Double) {
            let c = controller(json)
            c.fontScale = scale
            let all = nodes(try XCTUnwrap(c.render(width: 375, height: 812, measurer: FakeMeasurer())))
            let sizes = all.compactMap { node -> Double? in
                if case let .text(text)? = node.content { return text.font.size }
                return nil
            }
            return (sizes, all.compactMap { $0.layout.frame }.map { $0.y + $0.height }.max() ?? 0)
        }
        let normal = try measure(1)
        let large = try measure(1.5)
        XCTAssertFalse(normal.sizes.isEmpty)
        XCTAssertEqual(large.sizes, normal.sizes.map { $0 * 1.5 })
        XCTAssertGreaterThanOrEqual(large.bottom, normal.bottom)
    }

    func testEveryTemplateRendersAtPhoneAndTabletSizes() throws {
        let names = try templateNames()
        XCTAssertGreaterThanOrEqual(names.count, 5, "the spec has templates (the open spec holds a small set; the full library is checked privately)")
        var failures: [String] = []
        for name in names {
            for (w, h) in [(375.0, 812.0), (768.0, 1024.0)] {
                guard let render = controller(try paywall(name)).render(width: w, height: h, measurer: FakeMeasurer()) else {
                    failures.append("\(name)@\(w): no render")
                    continue
                }
                let all = nodes(render)
                if all.contains(where: { $0.layout.frame == nil }) { failures.append("\(name)@\(w): node without a frame") }
                if render.rootFrame.width > w + 0.01 { failures.append("\(name)@\(w): root wider than the screen") }
                if all.contains(where: { $0.frame.width.isNaN || $0.frame.height.isNaN || $0.frame.width < 0 || $0.frame.height < 0 }) {
                    failures.append("\(name)@\(w): bad frame")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testSelectingAPackageMovesSelectionAndBuyUsesIt() throws {
        let name = try XCTUnwrap(try templateNames().first { n in
            let t = try raw(n)
            return t.components(separatedBy: "\"type\":\"package\"").count > 2 && t.contains("purchase_button")
        })
        var events: [ScreenEvent] = []
        let c = controller(try paywall(name)) { events.append($0) }
        let packages = nodes(c.render(width: 375, height: 812, measurer: FakeMeasurer())!).filter { $0.type == "package" }
        XCTAssertGreaterThanOrEqual(packages.count, 2)
        let other = try XCTUnwrap(packages.first { $0.semantics.selected != true })
        c.handle(other.action!)
        let after = nodes(c.render(width: 375, height: 812, measurer: FakeMeasurer())!)
        XCTAssertEqual(after.filter { $0.type == "package" && $0.semantics.selected == true }.map(\.key), [other.key])
        let buy = try XCTUnwrap(after.first { if case .purchase? = $0.action { return true }; return false })
        c.handle(buy.action!)
        guard case let .selectPackage(id)? = other.action else { return XCTFail("package action") }
        XCTAssertTrue(events.contains(.purchase(packageId: id, actionId: nil)) || events.contains { if case let .purchase(p, _) = $0 { return p == id }; return false })
    }

    func testProductVariablesFillTexts() throws {
        let name = try XCTUnwrap(try templateNames().first { try raw($0).contains("product.price") })
        let json = try paywall(name)
        var ids: [String] = []
        Flow.walk(json) { if $0.str("type") == "package", let id = $0.str("package_id") { ids.append(id) } }
        let vars = Dictionary(uniqueKeysWithValues: ids.map { ($0, ["product.price": "$1,234.56", "product.price_per_period": "$1,234.56/month", "product.period": "month"]) })
        let texts = nodes(controller(json, vars: vars).render(width: 375, height: 812, measurer: FakeMeasurer())!).compactMap { node -> String? in
            if case let .text(t)? = node.content { return t.plain }
            return nil
        }
        XCTAssertTrue(texts.contains { $0.contains("$1,234.56") }, "\(name): \(texts)")
        XCTAssertFalse(texts.contains { $0.contains("{{") })
    }

    func testRequiredQuestionHoldsContinueUntilAnswered() throws {
        guard let name = try templateNames().first(where: { let t = try raw($0); return t.contains("\"required\":true") && t.contains("input_single_choice") }) else { return }
        var events: [ScreenEvent] = []
        let c = controller(try paywall(name)) { events.append($0) }
        let before = nodes(c.render(width: 375, height: 812, measurer: FakeMeasurer())!)
        XCTAssertTrue(before.contains { $0.type == "button" && $0.disabled && $0.semantics.disabled }, "\(name): continue waits and says so to screen readers")
        let option = try XCTUnwrap(before.first { if case .selectOption? = $0.action { return true }; return false })
        c.handle(option.action!)
        let after = nodes(c.render(width: 375, height: 812, measurer: FakeMeasurer())!)
        XCTAssertEqual(after.first { $0.key == option.key }?.semantics.selected, true)
        XCTAssertTrue(events.contains { if case .answer = $0 { return true }; return false })
    }

    func testTextWrapsAtTheContainerWidth() throws {
        let json = try XCTUnwrap(JSONValue.parse(string: """
        {"id":"t","default_locale":"en_US","components_localizations":{"en_US":{"t":"one two three four five six seven eight nine ten"}},
         "components_config":{"base":{"stack":{"type":"stack","id":"root","size":{"width":{"type":"fill"},"height":{"type":"fill"}},
           "dimension":{"type":"vertical","alignment":"leading","distribution":"start"},"padding":{"top":0,"bottom":0,"leading":10,"trailing":10},
           "components":[{"type":"text","id":"t","text_lid":"t","font_size":20,"size":{"width":{"type":"fill"},"height":{"type":"fit"}}}]}}}}
        """))
        let render = controller(json).render(width: 120, height: 400, measurer: FakeMeasurer())!
        let text = try XCTUnwrap(nodes(render).first { $0.type == "text" })
        XCTAssertEqual(text.frame.width, 100)
        XCTAssertGreaterThan(text.frame.height, 30, "wraps to several 30pt lines")
        XCTAssertEqual(text.frame.height.truncatingRemainder(dividingBy: 30), 0)
    }
}
