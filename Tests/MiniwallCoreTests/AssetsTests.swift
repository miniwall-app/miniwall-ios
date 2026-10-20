import Foundation
import XCTest
@testable import MiniwallCore

/// Same cases on every platform SDK.
final class AssetsTests: XCTestCase {
    private func obj(_ s: String) -> JSONValue { JSONValue.parse(string: s)! }

    func testIconKeyIsTheSetAndNameOfTheSvgFile() {
        XCTAssertEqual(Assets.iconKey("https://api.iconify.design/lucide/x.svg"), "lucide/x")
        XCTAssertEqual(Assets.iconKey("https://api.iconify.design/lucide/arrow-right.svg?color=red"), "lucide/arrow-right")
        XCTAssertEqual(Assets.iconKey("https://api.miniwall.app/v1/sdk/icons/custom/3f2a-9b.svg"), "custom/3f2a-9b")
        XCTAssertEqual(Assets.iconKey("https://api.iconify.design/tabler/home.svg"), "tabler/home")
        XCTAssertNil(Assets.iconKey("https://api.iconify.design/lucide/x.png"))
        XCTAssertNil(Assets.iconKey("https://api.miniwall.app/v2/sdk/icons/custom/a.svg"))
        XCTAssertNil(Assets.iconKey("https://cdn.example.com/a/b/icon.svg"))
        XCTAssertNil(Assets.iconKey("not a url"))
    }

    func testAssetsOfABodyIncludeWhatItsExperimentSideAndAudienceScreensShip() {
        let body = obj("""
        {"assets":{"icons":{"lucide/x":"<svg/>"},"fonts":{"Inter@600":"https://f/a.ttf"}},
          "experiment":{"b":{"assets":{"icons":{"lucide/check":"<svg c/>"},"fonts":{}}}},
          "rules":[{"paywall":{"assets":{"icons":{},"fonts":{"Nunito@700":"https://f/n.ttf"}}}},{"paywall":null}]}
        """)
        let assets = Assets.of(body)
        XCTAssertEqual(Set(assets.icons.keys), ["lucide/x", "lucide/check"])
        XCTAssertEqual(Set(assets.fonts.keys), ["Inter@600", "Nunito@700"])
        XCTAssertEqual(Assets.of(obj(#"{"paywall":{}}"#)), DeliveryAssets())
        XCTAssertEqual(Assets.of(obj(#"{"assets":{"icons":5,"fonts":{"a":3}}}"#)), DeliveryAssets())
        XCTAssertEqual(Assets.of(nil), DeliveryAssets())
    }

    func testFontLinkPrefersTheServerThenTheScreenAndRejectsNonFontFiles() {
        let declaration = obj(#"{"ios":"https://x/screen.ttf","android":"https://x/screen-android.otf","web":"https://x/a.woff2"}"#)
        let served = DeliveryAssets(fonts: ["Inter@600": "https://server/inter.ttf"])
        XCTAssertEqual(Assets.fontLink(name: "Inter@600", declaration: declaration, platform: "ios", assets: served), "https://server/inter.ttf")
        XCTAssertEqual(Assets.fontLink(name: "Inter@600", declaration: declaration, platform: "android", assets: DeliveryAssets()), "https://x/screen-android.otf")
        XCTAssertEqual(Assets.fontLink(name: "Inter@600", declaration: declaration, platform: "ios", assets: DeliveryAssets()), "https://x/screen.ttf")
        XCTAssertNil(Assets.fontLink(name: "Inter@600", declaration: obj(#"{"ios":"Helvetica"}"#), platform: "ios", assets: DeliveryAssets()))
        XCTAssertNil(Assets.fontLink(name: "Inter@600", declaration: obj(#"{"ios":"http://x/a.ttf"}"#), platform: "ios", assets: DeliveryAssets()))
        XCTAssertEqual(Assets.fontLink(name: "A", declaration: declaration, platform: "ios", assets: DeliveryAssets(fonts: ["A": "https://x/a.woff2"])), "https://x/screen.ttf")
        XCTAssertNil(Assets.fontLink(name: "A", declaration: nil, platform: "ios", assets: DeliveryAssets()))
    }
}

final class AutoAttributesTests: XCTestCase {
    func testCountryComesFromTheLocaleRegionOnly() {
        XCTAssertEqual(AutoAttributes.country("vi-VN"), "VN")
        XCTAssertEqual(AutoAttributes.country("vi_VN"), "VN")
        XCTAssertEqual(AutoAttributes.country("en_us"), "US")
        XCTAssertEqual(AutoAttributes.country("zh-Hans-CN"), "CN")
        XCTAssertEqual(AutoAttributes.country("zh_CN_#Hans"), "CN")
        XCTAssertEqual(AutoAttributes.country("es-419"), "419")
        XCTAssertNil(AutoAttributes.country("vi"))
        XCTAssertNil(AutoAttributes.country("en-u-nu-latn"))
        XCTAssertNil(AutoAttributes.country(""))
        XCTAssertNil(AutoAttributes.country(nil))
    }

    func testOsVersionIsTheMajorNumberAndAppVersionIsKeptAsWritten() {
        XCTAssertEqual(AutoAttributes.osVersion("17.4.1"), "17")
        XCTAssertEqual(AutoAttributes.osVersion("14"), "14")
        XCTAssertEqual(AutoAttributes.osVersion(" 8.1.0 "), "8")
        XCTAssertNil(AutoAttributes.osVersion("preview"))
        XCTAssertNil(AutoAttributes.osVersion(nil))
        XCTAssertEqual(AutoAttributes.appVersion(" 2.3.1 "), "2.3.1")
        XCTAssertNil(AutoAttributes.appVersion("  "))
    }

    func testAudienceFieldsReadTheAutomaticFacts() {
        let memory = DeviceMemory(store: MemoryStore())
        let input = TargetingInput(attributes: [:], locale: "vi_VN", device: "tablet", platform: "ios", osVersion: "17", appVersion: "2.3.1")
        func field(_ name: String, _ i: TargetingInput? = nil) -> JSONValue? { Delivery.fieldValue(name, "home", i ?? input, memory) }
        XCTAssertEqual(field("os_version"), .string("17"))
        XCTAssertEqual(field("app_version"), .string("2.3.1"))
        XCTAssertEqual(field("country"), .string("VN"))
        var spain = input
        spain.country = "ES"
        XCTAssertEqual(field("country", spain), .string("ES"))
        XCTAssertEqual(field("device"), .string("tablet"))
        var noVersion = input
        noVersion.osVersion = nil
        XCTAssertNil(field("os_version", noVersion))
        var noLocale = input
        noLocale.locale = nil
        XCTAssertNil(field("country", noLocale))
    }

    func testAnAudienceCanTestThemLikeTheWebWould() {
        let memory = DeviceMemory(store: MemoryStore())
        let screen = #"{"components_config":{"base":{"stack":{}}},"components_localizations":{}}"#
        let body = JSONValue.parse(string: """
        {"paywall":\(screen),"paywallId":"p1","placement":"home","rules":[
          {"id":"r1","conditions":[{"field":"country","op":"eq","value":"vn"},{"field":"os_version","op":"gte","value":16},{"field":"app_version","op":"starts_with","value":"2."}],
           "paywall":{"paywall":\(screen),"paywallId":"p2"}}]}
        """)!
        let vn = TargetingInput(attributes: [:], locale: "vi-VN", device: "mobile", platform: "ios", osVersion: "17", appVersion: "2.3.1")
        XCTAssertEqual(Delivery.decide(body, input: vn, memory: memory).context?.paywallId, "p2")
        var old = vn
        old.osVersion = "15"
        XCTAssertEqual(Delivery.decide(body, input: old, memory: memory).context?.paywallId, "p1")
        var oldApp = vn
        oldApp.appVersion = "1.9"
        XCTAssertEqual(Delivery.decide(body, input: oldApp, memory: memory).context?.paywallId, "p1")
        var us = vn
        us.locale = "en-US"
        XCTAssertEqual(Delivery.decide(body, input: us, memory: memory).context?.paywallId, "p1")
        var none = vn
        none.osVersion = nil
        XCTAssertEqual(Delivery.decide(body, input: none, memory: memory).context?.paywallId, "p1")
    }
}

final class DownloadLimitsTests: XCTestCase {
    private func stream(_ count: Int) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for i in 0..<count { continuation.yield(UInt8(truncatingIfNeeded: i)) }
            continuation.finish()
        }
    }

    func testLimitsAreTenMegabytesForImagesAndFiveForFonts() {
        XCTAssertEqual(DownloadLimits.maxImageBytes, 10 * 1024 * 1024)
        XCTAssertEqual(DownloadLimits.maxFontBytes, 5 * 1024 * 1024)
    }

    func testDeclaredLengthOverTheLimitIsRefused() {
        XCTAssertTrue(DownloadLimits.declaredTooLarge(101, max: 100))
        XCTAssertFalse(DownloadLimits.declaredTooLarge(100, max: 100))
        XCTAssertFalse(DownloadLimits.declaredTooLarge(-1, max: 100))
    }

    func testReadsABodyWithinTheLimit() async throws {
        let data = try await DownloadLimits.readLimited(stream(1000), max: 1000)
        XCTAssertEqual(data?.count, 1000)
        let empty = try await DownloadLimits.readLimited(stream(0), max: 10)
        XCTAssertEqual(empty?.count, 0)
    }

    func testRefusesBeforeReadingWhenContentLengthIsTooLarge() async throws {
        let data = try await DownloadLimits.readLimited(stream(10), max: 100, contentLength: 5000)
        XCTAssertNil(data)
    }

    func testAbortsWhenTheStreamPassesTheLimitEvenIfNoLengthWasDeclared() async throws {
        let data = try await DownloadLimits.readLimited(stream(101), max: 100, contentLength: 100)
        XCTAssertNil(data)
    }

    func testLimitedBufferKeepsChunksUpToTheLimit() {
        var buffer = LimitedBuffer(max: 10, expectedLength: 10)
        XCTAssertTrue(buffer.append(Data(repeating: 1, count: 4)))
        XCTAssertTrue(buffer.append(Data(repeating: 2, count: 6)))
        XCTAssertEqual(buffer.count, 10)
        XCTAssertFalse(buffer.exceeded)
        XCTAssertEqual(buffer.data.count, 10)
    }

    func testLimitedBufferRefusesTheChunkThatPassesTheLimitAndNeverStoresIt() {
        var buffer = LimitedBuffer(max: 10)
        XCTAssertTrue(buffer.append(Data(repeating: 1, count: 8)))
        XCTAssertFalse(buffer.append(Data(repeating: 2, count: 3)))
        XCTAssertTrue(buffer.exceeded)
        XCTAssertEqual(buffer.data.count, 8)
        XCTAssertFalse(buffer.append(Data()), "once exceeded, always exceeded")
    }

    func testLimitedBufferAcceptsEmptyChunksAndAnEmptyBody() {
        var buffer = LimitedBuffer(max: 0)
        XCTAssertTrue(buffer.append(Data()))
        XCTAssertFalse(buffer.exceeded)
        XCTAssertEqual(buffer.data.count, 0)
    }
}
