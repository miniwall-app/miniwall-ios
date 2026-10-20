// Template sweep: presents every template of the library (<spec>/fixtures/templates) in the sample app and checks that
// the app is still alive, that no error was reported, and that the screen is not blank. It found a crash of every banner and toast
// on iOS 27 and the stale icon of a selected option, neither of which the stubbed paywall of the other UI tests can show.
//
// Slow (about 9 s per template in light mode, 77 templates; the largest text size runs about as fast), so it is skipped unless asked for. Run on a Mac:
//   cd Example && xcodegen generate
//   TEST_RUNNER_MINIWALL_TEMPLATES=all xcodebuild test -project MiniwallExample.xcodeproj -scheme MiniwallExample \
//     -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MiniwallExampleUITests/MiniwallTemplateTests
// `TEST_RUNNER_MINIWALL_TEMPLATES=calm-money,streak` runs just those. The screenshots are attached to the result bundle (Xcode shows
// them under each test); a blank or crashed template fails with its name.
import UIKit
import XCTest

final class MiniwallTemplateTests: XCTestCase {
    /// <spec>/fixtures/templates: `.spec` in the repository (scripts/fetch-spec.sh), or $MINIWALL_SPEC_DIR. The open spec has a small set
    /// of templates; put (or link) a spec folder with more at `.spec` to sweep a bigger library. Keep it the same folder the app was
    /// built with (Example/project.yml bundles `.spec/fixtures`).
    private static var templatesDir: URL {
        if let path = ProcessInfo.processInfo.environment["MINIWALL_SPEC_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path).appendingPathComponent("fixtures/templates")
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // UITests
            .deletingLastPathComponent() // Example
            .deletingLastPathComponent() // repository
            .appendingPathComponent(".spec/fixtures/templates")
    }

    /// <spec>/fixtures/components: the small carousel / tabs / video / multiple-choice screens (B156).
    private static var componentsDir: URL { templatesDir.deletingLastPathComponent().appendingPathComponent("components") }

    private func jsonNames(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// `all` = every template of the spec, `components` = the component screens, otherwise a comma list of names from either folder.
    private func templateNames() throws -> [String] {
        let wanted = ProcessInfo.processInfo.environment["MINIWALL_TEMPLATES"] ?? ""
        try XCTSkipIf(wanted.isEmpty, "Slow: set TEST_RUNNER_MINIWALL_TEMPLATES=all (or components, or a comma list of template names) to run the template sweep")
        let all = try jsonNames(in: Self.templatesDir)
        XCTAssertFalse(all.isEmpty, "no templates in \(Self.templatesDir.path)")
        let components = try jsonNames(in: Self.componentsDir)
        XCTAssertFalse(components.isEmpty, "no component screens in \(Self.componentsDir.path)")
        switch wanted {
        case "all": return all
        case "components": return components
        default: return (all + components).filter { wanted.split(separator: ",").map(String.init).contains($0) }
        }
    }

    override func setUp() { continueAfterFailure = true }

    func testEveryTemplatePresentsInLightMode() throws {
        try sweep(extraArguments: [])
    }

    /// The largest text size the Settings app offers: layouts and clipped text show up here first.
    func testEveryTemplatePresentsAtTheLargestTextSize() throws {
        try sweep(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }

    private func sweep(extraArguments: [String]) throws {
        let names = try templateNames()
        for name in names {
            XCTContext.runActivity(named: name) { activity in
                let app = XCUIApplication()
                app.launchArguments = ["-uitest", "-tpl", name] + extraArguments
                app.launch()
                // The screen is presented after a short delay; give it and its images and icons time to appear.
                Thread.sleep(forTimeInterval: 3.5)

                XCTAssertEqual(app.state, .runningForeground, "\(name): the app is not running (crashed?)")
                let result = app.staticTexts["result"]
                if result.exists, result.label.hasPrefix("error") { XCTFail("\(name): \(result.label)") }

                let shot = XCUIScreen.main.screenshot()
                let attachment = XCTAttachment(screenshot: shot)
                attachment.name = name
                attachment.lifetime = .keepAlways
                activity.add(attachment)
                XCTAssertFalse(Self.isBlank(shot.image), "\(name): the screen is blank")
                app.terminate()
            }
        }
    }

    /// A screen with fewer than a handful of distinct colors in a coarse sample is a flat fill: a white launch screen or black cover.
    private static func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let w = 48, h = 96
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .low
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var seen = Set<UInt32>()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            // 4 bits per channel: anti-aliasing and gradients do not count as different colors.
            seen.insert(UInt32(pixels[i] >> 4) << 8 | UInt32(pixels[i + 1] >> 4) << 4 | UInt32(pixels[i + 2] >> 4))
        }
        return seen.count < 6
    }
}
