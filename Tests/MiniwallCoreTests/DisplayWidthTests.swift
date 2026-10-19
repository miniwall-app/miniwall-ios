import XCTest
@testable import MiniwallCore

/// Same cases as sdks/android/core DisplayWidthTest.kt.
final class DisplayWidthTests: XCTestCase {
    func testSizesFollowTheWebTable() {
        XCTAssertEqual(DisplayWidth.cap(kind: "modal", size: "small", maxContentWidth: nil), 360)
        XCTAssertEqual(DisplayWidth.cap(kind: "modal", size: "medium", maxContentWidth: nil), 440)
        XCTAssertEqual(DisplayWidth.cap(kind: "modal", size: "large", maxContentWidth: nil), 560)
        XCTAssertEqual(DisplayWidth.cap(kind: "sheet", size: "small", maxContentWidth: nil), 320)
        XCTAssertEqual(DisplayWidth.cap(kind: "sheet", size: "large", maxContentWidth: nil), 440)
        XCTAssertEqual(DisplayWidth.cap(kind: "toast", size: "medium", maxContentWidth: nil), 360)
    }

    func testMaxContentWidthWinsOverSize() {
        XCTAssertEqual(DisplayWidth.cap(kind: "modal", size: "small", maxContentWidth: 500), 500)
        XCTAssertEqual(DisplayWidth.cap(kind: "fullscreen", size: nil, maxContentWidth: 500), 500)
        XCTAssertEqual(DisplayWidth.cap(kind: "banner", size: "large", maxContentWidth: 500), 500)
    }

    func testNoLimitByDefault() {
        XCTAssertNil(DisplayWidth.cap(kind: "modal", size: nil, maxContentWidth: nil))
        XCTAssertNil(DisplayWidth.cap(kind: "fullscreen", size: "large", maxContentWidth: nil))
        XCTAssertNil(DisplayWidth.cap(kind: "banner", size: "small", maxContentWidth: nil))
        XCTAssertNil(DisplayWidth.cap(kind: "modal", size: "huge", maxContentWidth: nil))
        XCTAssertEqual(DisplayWidth.cap(kind: "modal", size: "small", maxContentWidth: -1), 360)
    }

    private func display(_ json: String) -> JSONValue? { JSONValue.parse(string: json) }

    func testPlacementSizeIsTheDefaultAndTheExplicitOptionWins() {
        let d = display(#"{"format":"modal","size":"small"}"#)
        XCTAssertEqual(DisplayWidth.resolveSize(explicit: nil, display: d, styleOverridden: false), "small")
        XCTAssertEqual(DisplayWidth.resolveSize(explicit: "large", display: d, styleOverridden: false), "large")
        XCTAssertEqual(DisplayWidth.resolveSize(explicit: "large", display: d, styleOverridden: true), "large")
        let size = DisplayWidth.resolveSize(explicit: nil, display: d, styleOverridden: false)
        XCTAssertEqual(DisplayWidth.cap(kind: "modal", size: size, maxContentWidth: nil), 360)
        XCTAssertEqual(DisplayWidth.cap(kind: "sheet", size: size, maxContentWidth: nil), 320)
        XCTAssertEqual(DisplayWidth.cap(kind: "toast", size: size, maxContentWidth: nil), 280)
        XCTAssertEqual(DisplayWidth.cap(kind: "modal", size: size, maxContentWidth: 500), 500)
    }

    func testPlacementSizeIsIgnoredWhenTheCallPicksTheFormat() {
        XCTAssertNil(DisplayWidth.resolveSize(explicit: nil, display: display(#"{"format":"modal","size":"large"}"#), styleOverridden: true))
    }

    func testMissingOrUnknownPlacementSizeKeepsTheOldNoLimit() {
        XCTAssertNil(DisplayWidth.resolveSize(explicit: nil, display: nil, styleOverridden: false))
        XCTAssertNil(DisplayWidth.resolveSize(explicit: nil, display: display(#"{"format":"modal"}"#), styleOverridden: false))
        XCTAssertNil(DisplayWidth.resolveSize(explicit: nil, display: display(#"{"size":"huge"}"#), styleOverridden: false))
        XCTAssertNil(DisplayWidth.resolveSize(explicit: nil, display: display(#"{"size":3}"#), styleOverridden: false))
    }
}
