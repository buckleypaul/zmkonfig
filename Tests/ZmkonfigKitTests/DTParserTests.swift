import Foundation
import Testing

@testable import ZmkonfigKit

@Suite("Devicetree parser")
struct DTParserTests {
    @Test("Top-level blocks are kept separate and in source order")
    func rootsPreserveOrder() throws {
        let document = try Fixture.cradioDocument()
        #expect(document.roots.map(\.name) == ["&mt", "&sk", "/", "/"])
    }

    @Test("Labelled nodes keep both the label and the node name")
    func labelsAndNames() throws {
        let document = try Fixture.cradioDocument()
        let behaviors = try #require(document.allNodes().first { $0.name == "behaviors" })
        #expect(behaviors.children.map(\.label) == [
            "rpi", "hml", "hmr", "qt", "ht", "hold_temp_layer", "ht_pref_hold", "sticky_tap",
        ])
        #expect(behaviors.children.map(\.name) == [
            "require_prior_idle", "hold_tap_left", "hold_tap_right", "quick_tap", "hold_tap",
            "hold_temp_layer", "ht_pref_hold", "sticky_tap",
        ])
    }

    @Test("A node's range covers itself exactly")
    func nodeRanges() throws {
        let document = try Fixture.cradioDocument()
        let combo = try #require(document.allNodes().first { $0.name == "escape-combo" })
        #expect(document.text(combo.range) == [
            "escape-combo {",
            "            bindings = <&kp ESC>;",
            "            key-positions = <1 3>;",
            "        };",
        ].joined(separator: "\n"))
        #expect(document.text(combo.bodyRange).contains("bindings = <&kp ESC>;"))
    }

    @Test("`bindings = <&kp>, <&kp>;` is two cells, not one")
    func multipleCells() throws {
        let document = try Fixture.cradioDocument()
        let hml = try #require(document.allNodes().first { $0.label == "hml" })
        guard case .cells(let cells)? = hml.property("bindings")?.value else {
            Issue.record("expected cells")
            return
        }
        #expect(cells.count == 2)
        #expect(cells.map(\.text) == ["&kp", "&kp"])
    }

    @Test("A property with no value is a boolean, not an empty string")
    func booleanProperty() throws {
        let document = try Fixture.cradioDocument()
        let hml = try #require(document.allNodes().first { $0.label == "hml" })
        let flag = try #require(hml.property("hold-trigger-on-release"))
        #expect(flag.value == .none)
        #expect(flag.valueRange == nil)
        #expect(document.text(flag.range) == "hold-trigger-on-release;")
    }

    @Test("`#binding-cells` is a property name, not a preprocessor directive")
    func bindingCellsProperty() throws {
        let document = try Fixture.cradioDocument()
        let hml = try #require(document.allNodes().first { $0.label == "hml" })
        let cells = try #require(hml.property("#binding-cells"))
        #expect(cells.value.cellTexts == ["2"])
        #expect(document.text(cells.range) == "#binding-cells = <2>;")
    }

    @Test("String, cell and reference values are told apart")
    func valueKinds() throws {
        let document = try DTDocument(source: """
            / {
                node {
                    compatible = "zmk,behavior-hold-tap";
                    tapping-term-ms = <280>;
                    #binding-cells = <2>;
                    other = &label;
                    flag;
                };
            };
            """.data(using: .utf8)!)
        let node = try #require(document.allNodes().first { $0.name == "node" })
        #expect(node.compatible == "zmk,behavior-hold-tap")
        #expect(node.property("tapping-term-ms")?.value.cellTexts == ["280"])
        #expect(node.property("#binding-cells")?.value.cellTexts == ["2"])
        #expect(node.property("other")?.value == .reference("&label"))
        #expect(node.property("flag")?.value == DTValue.none)
    }

    @Test("A property's valueRange spans the value and nothing else")
    func valueRange() throws {
        let document = try Fixture.cradioDocument()
        let escape = try #require(document.allNodes().first { $0.name == "escape-combo" })
        let bindings = try #require(escape.property("bindings"))
        #expect(document.text(try #require(bindings.valueRange)) == "<&kp ESC>")
    }

    @Test("Overrides outside a root block parse as nodes")
    func overrideNodes() throws {
        let document = try Fixture.cradioDocument()
        let sk = try #require(document.roots.first { $0.name == "&sk" })
        #expect(sk.properties.map(\.name) == ["ignore-modifiers"])
        // `&mt`'s body is entirely commented out, so it has nothing in it.
        let mt = try #require(document.roots.first { $0.name == "&mt" })
        #expect(mt.properties.isEmpty)
        #expect(mt.children.isEmpty)
    }

    @Test("Compatible lookup finds the keymap and combos nodes")
    func compatibleLookup() throws {
        let document = try Fixture.cradioDocument()
        #expect(document.nodes(compatible: "zmk,keymap").map(\.name) == ["keymap"])
        #expect(document.nodes(compatible: "zmk,combos").map(\.name) == ["combos"])
        #expect(document.nodes(compatible: "zmk,behavior-hold-tap").count == 8)
    }

    @Test("An unterminated node is an error, not a silent truncation")
    func unterminatedNode() {
        #expect(throws: DTParseError.self) {
            _ = try DTDocument(source: Data("/ { keymap { bindings = <&kp A>;".utf8))
        }
    }
}
