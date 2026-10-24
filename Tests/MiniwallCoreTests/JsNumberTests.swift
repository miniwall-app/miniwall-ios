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

    func testPrintsLikeJavaScriptsString() {
        let cases: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (5, "5"), (-5, "-5"), (1.5, "1.5"), (0.0001, "0.0001"), (0.000001, "0.000001"),
            (1e-7, "1e-7"), (1.5e-7, "1.5e-7"), (12345678.5, "12345678.5"), (1e21, "1e+21"), (1.5e300, "1.5e+300"),
            (123456789012345680000, "123456789012345680000"), (9e15, "9000000000000000"), (0.1 + 0.2, "0.30000000000000004"),
            (.nan, "NaN"), (.infinity, "Infinity"), (-.infinity, "-Infinity"),
        ]
        for (d, text) in cases { XCTAssertEqual(JsNumber.format(d), text, "\(d)") }
    }

    func testMarkdownDotMatchesWhatJavaScriptMatches() {
        // U+0085 is an ordinary character to JavaScript's `.`; line breaks (\n, \r, U+2028, U+2029) are not.
        XCTAssertEqual(TextLogic.htmlFromMarkdown("~a\u{85}b~"), "<s>a\u{85}b</s>")
        XCTAssertEqual(TextLogic.htmlFromMarkdown("~a\rb~"), "~a\rb~")
        XCTAssertEqual(TextLogic.htmlFromMarkdown("~a\u{2028}b~"), "~a\u{2028}b~")
    }

    func testPriceLocaleFollowsTheScreenNotTheDevice() {
        let one = JSONValue.object(["default_locale": .string("en_US"), "components_localizations": .object(["en_US": .object([:])])])
        XCTAssertEqual(Localization.forPaywall(one, requested: "vi_VN"), "en_US")
        XCTAssertEqual(Localization.forPaywall(one, requested: "en-GB"), "en_US")
        let two = JSONValue.object(["default_locale": .string("en_US"), "components_localizations": .object(["en_US": .object([:]), "vi_VN": .object([:])])])
        XCTAssertEqual(Localization.forPaywall(two, requested: "vi"), "vi_VN")
        XCTAssertEqual(Localization.forPaywall(.object([:]), requested: nil), "en_US")
    }
}
