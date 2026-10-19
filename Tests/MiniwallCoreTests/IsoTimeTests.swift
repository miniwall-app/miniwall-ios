import Foundation
import XCTest
@testable import MiniwallCore

/// Same cases as sdks/android/core IsoTimeTest.kt, checked against Foundation's own parser.
final class IsoTimeTests: XCTestCase {
    func testFormatMatchesFoundationAcrossTheCalendar() {
        let reference = ISO8601DateFormatter()
        reference.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var t: Int64 = -2_000_000_000_000
        while t < 4_200_000_000_000 {
            XCTAssertEqual(IsoTime.format(t), reference.string(from: Date(timeIntervalSince1970: Double(t) / 1000)), "t=\(t)")
            t += 86_400_000 * 13 + 3_723_456
        }
        XCTAssertEqual(IsoTime.format(0), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(IsoTime.format(951_868_799_999), "2000-02-29T23:59:59.999Z")
    }

    func testParseReadsOffsetsLongFractionsDatesAndLocalTimes() {
        let reference = ISO8601DateFormatter()
        reference.formatOptions = [.withInternetDateTime]
        for s in ["2026-12-31T23:59:59Z", "2026-12-31T23:59:59+07:00", "2026-01-01T00:00:00-05:30"] {
            XCTAssertEqual(IsoTime.parse(s), Int64(reference.date(from: s)!.timeIntervalSince1970 * 1000), s)
        }
        XCTAssertEqual(IsoTime.parse("2026-12-31T23:59:59.123456Z"), IsoTime.parse("2026-12-31T23:59:59.123Z"))
        // No offset means the device's zone; a date alone is UTC midnight.
        XCTAssertEqual(IsoTime.parse("2026-12-31T23:59", offsetMsAt: { _ in 7 * 3_600_000 }), IsoTime.parse("2026-12-31T16:59:00Z"))
        XCTAssertEqual(IsoTime.parse("2026-12-31"), IsoTime.parse("2026-12-31T00:00:00Z"))
        XCTAssertNil(IsoTime.parse("tomorrow"))
        XCTAssertNil(IsoTime.parse("2026-13-01T00:00:00Z"))
        XCTAssertNil(IsoTime.parse("2026-02-31T00:00:00Z"))
    }
}
