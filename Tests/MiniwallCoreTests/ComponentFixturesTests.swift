import Foundation
import XCTest
@testable import MiniwallCore

/// B156: carousel, tabs, video and multiple choice had no template, so nothing exercised them. The fixtures in
/// the spec's fixtures/components are small screens for exactly those; this parses each, builds the render tree at
/// both golden sizes, checks the frames against the web goldens (golden/components) and drives the state changes.
/// Port of ComponentFixturesTest.kt (not run at cloud: no Swift there).
final class ComponentFixturesTests: XCTestCase {
    private var dir: URL { Spec.dir.appendingPathComponent("fixtures/components") }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    private func paywall(_ name: String) throws -> JSONValue {
        try XCTUnwrap(JSONValue.parse(Data(contentsOf: dir.appendingPathComponent("\(name).json")))["paywall"])
    }

    private func controller(_ name: String, onEvent: @escaping (ScreenEvent) -> Void = { _ in }) throws -> ScreenController {
        ScreenController(paywall: try paywall(name), locale: "en_US", dark: false, variablesPerPackage: [:], baseVariables: [:], infoPerPackage: [:],
                         showRestoreButton: true, onEvent: onEvent)
    }

    private func render(_ c: ScreenController, _ w: Double = 375, _ h: Double = 812) throws -> [RenderNode] {
        let r = try XCTUnwrap(c.render(width: w, height: h, measurer: FakeMeasurer()))
        var out: [RenderNode] = []
        [r.header, r.root, r.footer, r.sheet].compactMap { $0 }.forEach { $0.walk { out.append($0) } }
        return out
    }

    /// The node types each fixture exists to exercise.
    private let expectedTypes = [
        "carousel-pages": "carousel", "carousel-peek": "carousel", "tabs-buttons": "tabs", "tabs-toggle": "tab_control_toggle",
        "video-basic": "video", "choice-multiple": "input_option",
    ]

    func testEveryFixtureParsesAndRendersAtBothSizes() throws {
        XCTAssertEqual(Set(expectedTypes.keys), Set(try names()), "a fixture without an entry in expectedTypes")
        for name in try names() {
            _ = try PaywallData.decode(paywall(name))
            for (w, h) in [(375.0, 812.0), (768.0, 1024.0)] {
                let all = try render(controller(name), w, h)
                XCTAssertTrue(all.contains { $0.type == expectedTypes[name] }, "\(name)@\(w): no \(expectedTypes[name] ?? "?") node")
                XCTAssertFalse(all.contains { $0.layout.frame == nil }, "\(name)@\(w): node without a frame")
                XCTAssertFalse(all.contains { $0.frame.width.isNaN || $0.frame.height.isNaN || $0.frame.width < 0 || $0.frame.height < 0 }, "\(name)@\(w): bad frame")
            }
        }
    }

    /// Frames of every stack must match the web golden. Carousel pages are the exception on x and width: the web carousel is as
    /// wide as its content (shrink-to-fit, max 100%) and lays out pages without the shift the native slider applies, the native
    /// carousel is always as wide as its parent. Heights and y still must match. A known limit.
    func testFramesMatchTheWebGoldens() throws {
        var failures: [String] = []
        for name in try names() {
            let goldenURL = Spec.dir.appendingPathComponent("golden/components/\(name).json")
            guard let data = try? Data(contentsOf: goldenURL) else { failures.append("\(name): no golden (run pnpm golden:render)"); continue }
            let viewports = try XCTUnwrap(JSONValue.parse(data)["viewports"]?.objectValue)
            for (viewport, entry) in viewports.sorted(by: { $0.key < $1.key }) {
                let size = viewport.split(separator: "x").compactMap { Double($0) }
                var frames: [String: LayoutRect] = [:]
                for node in try render(controller(name), size[0], size[1]) {
                    if let id = node.jsonId, node.layout.frame != nil { frames[id] = node.frame }
                }
                let carousel = name.hasPrefix("carousel")
                for (id, rect) in (entry["nodes"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                    let expected = ["x", "y", "w", "h"].map { rect[$0]?.doubleValue ?? .nan }
                    guard let actual = frames[id] else {
                        if expected.allSatisfy({ $0 == 0 }) { continue }
                        failures.append("\(name)@\(viewport) \(id): missing")
                        continue
                    }
                    let got = [actual.x, actual.y, actual.width, actual.height]
                    let checked = carousel && id.hasPrefix("page") ? [1, 3] : [0, 1, 2, 3]
                    if checked.contains(where: { abs(got[$0] - expected[$0]) > 0.1 }) {
                        failures.append("\(name)@\(viewport) \(id): expected \(expected) got \(got)")
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) layout mismatches:\n" + failures.joined(separator: "\n"))
    }

    func testCarouselShowsThePageItWasToldTo() throws {
        let c = try controller("carousel-peek")
        func slider() throws -> RenderNode.CarouselInfo { try XCTUnwrap(try render(c).compactMap(\.carousel).first) }
        let first = try slider()
        XCTAssertEqual(first.pageCount, 3)
        XCTAssertEqual(first.currentPage, 1, "initial_page_index")
        c.setCarouselPage(first.key, 2)
        XCTAssertEqual(try slider().currentPage, 2)
        c.setCarouselPage(first.key, 7)
        XCTAssertTrue((0...2).contains(try slider().currentPage), "a page out of range falls back to a page that exists")
        XCTAssertEqual(try render(c).filter { $0.key.contains("/dots/") }.count, 3, "one indicator per page")
    }

    func testTabButtonsSwitchTheShownTab() throws {
        let c = try controller("tabs-buttons")
        func ids() throws -> Set<String> { Set(try render(c).compactMap(\.jsonId)) }
        var shown = try ids()
        XCTAssertTrue(shown.contains("pane0") && !shown.contains("pane1"), "the default tab shows first")
        let buttons = try render(c).filter { $0.type == "tab_control_button" }
        XCTAssertEqual(buttons.count, 2)
        XCTAssertEqual(buttons.map { $0.semantics.selected }, [true, false], "the open tab's button says it is selected")
        c.handle(try XCTUnwrap(buttons[1].action))
        shown = try ids()
        XCTAssertTrue(shown.contains("pane1") && !shown.contains("pane0"), "tapping the second button opens the second tab")
        XCTAssertEqual(try render(c).filter { $0.type == "tab_control_button" }.map { $0.semantics.selected }, [false, true])
    }

    func testTabToggleSwitchesBetweenTheTwoTabs() throws {
        let c = try controller("tabs-toggle")
        let off = try XCTUnwrap(try render(c).first { $0.type == "tab_control_toggle" })
        guard case let .toggle(on, _, _)? = off.content else { return XCTFail("toggle content") }
        XCTAssertFalse(on)
        c.handle(try XCTUnwrap(off.action))
        let after = try render(c)
        guard case let .toggle(nowOn, _, _)? = after.first(where: { $0.type == "tab_control_toggle" })?.content else { return XCTFail("toggle content") }
        XCTAssertTrue(nowOn)
        XCTAssertTrue(after.contains { $0.jsonId == "pane1" } && !after.contains { $0.jsonId == "pane0" })
    }

    func testVideoCarriesItsSettingsAndTakesItsSize() throws {
        let node = try XCTUnwrap(try render(controller("video-basic")).first { $0.type == "video" })
        guard case let .video(video)? = node.content else { return XCTFail("video content") }
        XCTAssertTrue(video.url.hasSuffix("video.mp4"))
        XCTAssertTrue(video.cover)
        XCTAssertFalse(video.autoPlay)
        XCTAssertTrue(video.muted)
        XCTAssertTrue(video.showControls)
        XCTAssertNotNil(video.fallbackImageURL)
        XCTAssertEqual(node.frame.height, 200, accuracy: 0.1)
        XCTAssertEqual(node.frame.width, 343, accuracy: 0.1)
    }

    func testMultipleChoiceHonoursMinAndMaxAndKeepsTapOrder() throws {
        var events: [ScreenEvent] = []
        let c = try controller("choice-multiple") { events.append($0) }
        func options() throws -> [RenderNode] { try render(c).filter { $0.type == "input_option" } }
        XCTAssertEqual(try options().count, 3)
        c.handle(try XCTUnwrap(try options()[0].action))
        c.handle(try XCTUnwrap(try options()[2].action))
        let full = try options()
        XCTAssertEqual(full.map { $0.semantics.selected == true }, [true, false, true], "two chosen, tap order kept")
        XCTAssertTrue(full[1].disabled && full[1].action == nil, "at max the rest are off")
        c.handle(try XCTUnwrap(full[0].action))
        let after = try options()
        XCTAssertEqual(after.map { $0.semantics.selected == true }, [false, false, true], "tapping a chosen option clears it (multiple)")
        XCTAssertTrue(after.allSatisfy { !$0.disabled }, "below max every option is open again")
        XCTAssertEqual(events.filter { if case .answer = $0 { return true }; return false }.count, 3)
    }
}
