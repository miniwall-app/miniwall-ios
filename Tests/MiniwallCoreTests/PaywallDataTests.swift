import Foundation
import XCTest
@testable import MiniwallCore

final class PaywallDataTests: XCTestCase {
    private func decode(_ json: String) throws -> PaywallData {
        try PaywallData.decode(Data(json.utf8))
    }

    func testDecodesRootStackAndLocalizations() throws {
        let paywall = try decode("""
        {"id":"p1","default_locale":"fr_FR",
         "components_config":{"colors":{"primary":"#112233"},"base":{"stack":{"type":"stack","id":"root","components":[],
           "size":{"width":{"type":"fill"},"height":{"type":"fixed","value":120}},
           "dimension":{"type":"horizontal","alignment":"bottom","distribution":"space_between"},
           "spacing":8,"padding":{"top":1,"bottom":2,"leading":3,"trailing":4},"border":{"width":2,"color":{"light":{"type":"hex","value":"#000"}}}}}},
         "components_localizations":{"fr_FR":{"k":"Bonjour"}}}
        """)
        XCTAssertEqual(paywall.id, "p1")
        XCTAssertEqual(paywall.defaultLocale, "fr_FR")
        XCTAssertEqual(paywall.colors["primary"], "#112233")
        XCTAssertEqual(paywall.localizations["fr_FR"]?["k"], "Bonjour")
        let root = paywall.base.stack
        XCTAssertEqual(root.width, .fill)
        XCTAssertEqual(root.height, .fixed(120))
        XCTAssertEqual(root.dimension, .horizontal(alignment: .end, distribution: .spaceBetween))
        XCTAssertEqual(root.padding, Spacing(top: 1, bottom: 2, leading: 3, trailing: 4))
        XCTAssertEqual(root.borderWidth, 2)
    }

    func testUnknownNodeUsesFallbackAndHiddenNodesAreDropped() throws {
        let paywall = try decode("""
        {"components_config":{"base":{"stack":{"type":"stack","id":"root","dimension":{"type":"vertical","alignment":"leading","distribution":"start"},
          "size":{"width":{"type":"fill"},"height":{"type":"fill"}},"components":[
            {"type":"future_widget","id":"x","fallback":{"type":"stack","id":"fb","components":[],"size":{"width":{"type":"fixed","value":10},"height":{"type":"fixed","value":10}}}},
            {"type":"future_widget","id":"y"},
            {"type":"stack","id":"hidden","visible":false,"components":[]}
          ]}}}}
        """)
        let root = try XCTUnwrap(LayoutNode.from(.stack(paywall.base.stack)))
        XCTAssertEqual(root.children.map(\.id), ["fb"])
    }

    func testMissingRootStackThrows() {
        XCTAssertThrowsError(try decode(#"{"components_config":{"base":{}}}"#))
        XCTAssertThrowsError(try decode("not json"))
    }

    func testUnknownDimensionTypeIsARowLikeTheWeb() {
        XCTAssertEqual(StackDimension.decode(.object(["type": .string("diagonal"), "alignment": .string("top")])),
                       .horizontal(alignment: .start, distribution: .center))
    }
}
