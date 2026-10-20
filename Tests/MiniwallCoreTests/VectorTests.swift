import Foundation
import XCTest
@testable import MiniwallCore

/// Every case in the spec's vectors must give the web's exact output.
/// Same suite on every platform SDK.
final class VectorTests: XCTestCase {
    private func cases(_ name: String) throws -> [JSONValue] {
        let url = Spec.dir.appendingPathComponent("vectors/\(name).json")
        return try XCTUnwrap(JSONValue.parse(Data(contentsOf: url)).arr("cases"))
    }

    private func check(_ name: String, _ actual: (JSONValue) -> JSONValue, file: StaticString = #filePath, line: UInt = #line) throws {
        var failures: [String] = []
        for (i, c) in try cases(name).enumerated() {
            let got = actual(c["input"]!)
            let expected = c["expected"]!
            if got != expected { failures.append("#\(i) \(c["input"]!.jsonString)\n  expected \(expected.jsonString)\n  got      \(got.jsonString)") }
        }
        XCTAssertTrue(failures.isEmpty, "\(name): \(failures.count) mismatches\n" + failures.prefix(15).joined(separator: "\n"), file: file, line: line)
    }

    private func stringMap(_ v: JSONValue?) -> [String: String] { (v?.objectValue ?? [:]).compactMapValues(\.stringValue) }
    private func str(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }

    func testReplaceVariables() throws {
        try check("replace-variables") { .string(TextLogic.replaceVariables($0.str("template"), stringMap($0["variables"]))) }
    }

    func testMarkdownHtml() throws {
        try check("markdown-html") { .string(TextLogic.htmlFromMarkdown($0.str("text"))) }
    }

    func testOpenableURL() throws {
        try check("openable-url") { .bool(TextLogic.isOpenableURL($0.str("url")!)) }
    }

    func testFontName() throws {
        try check("font-name") { i in
            TextLogic.parseFontName(i.str("name")!).map { .object(["family": .string($0.family), "weight": .number(Double($0.weight))]) } ?? .null
        }
    }

    func testVisibilityConditions() throws {
        try check("visibility-conditions") { i in
            let ctx = i["context"]!
            let info = ctx.obj("packageInfo").map {
                PackageInfo(hasIntroOffer: $0.bool("hasIntroOffer") == true, hasTrial: $0.bool("hasTrial") == true, hasPromoOffer: $0.bool("hasPromoOffer") == true)
            }
            return .bool(Overrides.isVisible(i["overrides"], baseVisible: i.bool("baseVisible"), selectedPackageId: ctx.str("selectedPackageId"),
                                             packageInfo: info, variables: stringMap(ctx["variables"])))
        }
    }

    func testTargetingMatch() throws {
        try check("targeting-match") { i in
            let c = i["condition"]!
            return .bool(Targeting.matches(op: c.str("op")!, expected: c["value"], actual: i["actual"]))
        }
    }

    func testABBucket() throws {
        try check("ab-bucket") { .number(Double(Targeting.bucketOf($0.str("experimentId")!, $0.str("visitorId")!))) }
    }

    func testScreenLink() throws {
        try check("screen-link") { i in
            switch Flow.screenLink(i.str("actionId")!) {
            case nil: return .null
            case .back?: return .object(["kind": .string("back")])
            case let .goTo(id)?: return .object(["kind": .string("goto"), "id": .string(id)])
            }
        }
    }

    func testApplyAnswer() throws {
        try check("apply-answer") { i in
            let answers: [String: Flow.Answer] = (i.obj("answers")?.objectValue ?? [:]).mapValues {
                if let a = $0.arrayValue { return .many(a.compactMap(\.stringValue)) }
                return .one($0.stringValue ?? "")
            }
            let kind: Flow.FieldKind? = ["single": .single, "multiple": .multiple, "text": .text][i.str("kind") ?? ""]
            let result = Flow.applyAnswer(answers, kind: kind, fieldId: i.str("fieldId")!, value: i.str("value")!)
            return .object(result.mapValues {
                switch $0 {
                case let .one(v): return .string(v)
                case let .many(vs): return .array(vs.map(JSONValue.string))
                }
            })
        }
    }

    func testCountdown() throws {
        try check("countdown") { i in
            let now = Countdown.parseDate(i.str("now")!)!
            let target = Countdown.parseDate(i.str("target")!)!
            return .object(Countdown.values(targetMs: target, nowMs: now).mapValues(JSONValue.string))
        }
    }

    func testProductVariables() throws {
        func period(_ v: JSONValue?) -> Period? {
            switch v {
            case nil, .null?: return nil
            case let .string(s)? where s == "lifetime": return .lifetime
            case let .string(s)?: return .every(Period.Unit(rawValue: s)!)
            case let o?: return .every(Period.Unit(rawValue: o.str("unit")!)!, count: Int(o.num("count")!))
            }
        }
        try check("product-variables") { i in
            let products = (i.obj("products")?.objectValue ?? [:]).mapValues { p in
                ProductInfo(price: p.num("price")!, currency: p.str("currency")!, period: period(p["period"]), title: p.str("title"),
                            offer: p.obj("offer").map { ProductInfo.Offer(price: $0.num("price")!, period: period($0["period"])!) })
            }
            let result = Pricing.productVariables(products, locale: i.str("locale"))
            return .object(result.mapValues { .object($0.mapValues(JSONValue.string)) })
        }
    }
}
