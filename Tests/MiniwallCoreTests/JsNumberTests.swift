import XCTest
@testable import MiniwallCore

/// Same cases on every platform SDK: text turns into numbers the way JavaScript's Number() does.
final class JsNumberTests: XCTestCase {
    func testParsesLikeJavaScriptsNumber() {
        XCTAssertEqual(Targeting.jsParse("5"), 5)
        XCTAssertEqual(Targeting.jsParse("-1.5e3"), -1500)
        XCTAssertEqual(Targeting.jsParse(".5"), 0.5)
        XCTAssertEqual(Targeting.jsParse("0xff"), 255)
        XCTAssertEqual(Targeting.jsParse("0b101"), 5)
        XCTAssertEqual(Targeting.jsParse("Infinity"), .infinity)
        // JavaScript turns these into NaN; Swift's own Double(...) accepts some of them.
        for text in ["5f", "NaN", "inf", "0x1p3", "1,5", "--1", "5 5", "0xzz", "1e"] {
            XCTAssertTrue(Targeting.jsParse(text).isNaN, text)
        }
    }
}
