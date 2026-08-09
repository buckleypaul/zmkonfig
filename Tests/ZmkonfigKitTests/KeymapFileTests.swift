import Foundation
import Testing

@testable import ZmkonfigKit

@Suite("Keymap round trip")
struct KeymapFileTests {
    // MARK: The gating test

    @Test("Re-serializing an unedited keymap reproduces it byte for byte")
    func roundTripIsByteIdentical() throws {
        let source = try Fixture.cradioSource()
        let keymap = try KeymapFile(source: source)
        let output = try keymap.serialized(layout: Fixture.cradioLayout())

        if output != source {
            // Point at the first difference rather than dumping 8 KB of keymap.
            let before = String(decoding: source, as: UTF8.self).components(separatedBy: "\n")
            let after = String(decoding: output, as: UTF8.self).components(separatedBy: "\n")
            for (index, pair) in zip(before, after).enumerated() where pair.0 != pair.1 {
                Issue.record("line \(index + 1)\n  want: \(pair.0.debugDescription)\n  got:  \(pair.1.debugDescription)")
                break
            }
            #expect(before.count == after.count, "line count changed")
        }
        #expect(output == source)
    }

    // MARK: Structure

    @Test("Every layer is found, in order, with all 34 keys")
    func layers() throws {
        let keymap = try Fixture.cradio()
        #expect(keymap.layers.map(\.nodeName) == [
            "default_layer", "nav", "num", "symbols", "settings_layer",
        ])
        #expect(keymap.layers.map(\.id) == [0, 1, 2, 3, 4])
        #expect(keymap.layers[0].bindings.count == 34)
        #expect(keymap.layers.allSatisfy { $0.bindings.count == 34 })
    }

    @Test("Node names are humanized for display")
    func displayNames() throws {
        let keymap = try Fixture.cradio()
        #expect(keymap.layers.map(\.displayName) == [
            "Default Layer", "Nav", "Num", "Symbols", "Settings Layer",
        ])
    }

    @Test("A layer's own display-name wins over the humanized node name")
    func explicitDisplayName() throws {
        let keymap = try KeymapFile(source: Data("""
            / {
                keymap {
                    compatible = "zmk,keymap";
                    default_layer {
                        display-name = "Base";
                        bindings = <&kp A>;
                    };
                };
            };
            """.utf8))
        #expect(keymap.layers.map(\.displayName) == ["Base"])
        #expect(keymap.layers.map(\.nodeName) == ["default_layer"])
    }

    @Test("A file indented differently round trips on its own terms")
    func alternativeIndentation() throws {
        // Nothing about the twelve-space indent of the real file is baked in:
        // the framing whitespace comes from whatever the cell already had.
        let source = """
            / {
              keymap {
                compatible = "zmk,keymap";
                base {
                  bindings = <
            &kp A    &kp B
            &kp CCC  &kp D
                  >;
                };
              };
            };

            """
        let layout = [
            KeyPosition(row: 0, col: 0, x: 0, y: 0), KeyPosition(row: 0, col: 1, x: 1, y: 0),
            KeyPosition(row: 1, col: 0, x: 0, y: 1), KeyPosition(row: 1, col: 1, x: 1, y: 1),
        ]
        let keymap = try KeymapFile(source: Data(source.utf8))
        #expect(keymap.layers.count == 1)
        #expect(keymap.layers[0].bindings.count == 4)
        #expect(String(decoding: try keymap.serialized(layout: layout), as: UTF8.self) == source)
    }

    @Test("Bindings parse into behavior plus parameters")
    func bindingsParse() throws {
        let keymap = try Fixture.cradio()
        let base = keymap.layers[0].bindings
        #expect(base[0] == KeyBinding(behavior: "&kp", params: [BindingParam(value: "Q")]))
        #expect(base[10] == KeyBinding(
            behavior: "&hml",
            params: [BindingParam(value: "LEFT_GUI"), BindingParam(value: "A")]
        ))
        #expect(base[33].text == "&lt 1 ENTER")
        #expect(keymap.layers[1].bindings[0] == KeyBinding(behavior: "&trans"))
        #expect(keymap.layers[1].bindings[0].params.isEmpty)
    }

    @Test("Combos are read with their bindings and key positions")
    func combos() throws {
        let keymap = try Fixture.cradio()
        #expect(keymap.combos.count == 13)
        #expect(keymap.combos.first?.nodeName == "escape-combo")
        #expect(keymap.combos.first?.binding.text == "&kp ESC")
        #expect(keymap.combos.first?.keyPositions == [1, 3])
        let homerow = try #require(keymap.combos.first { $0.nodeName == "homerow-open" })
        #expect(homerow.binding.text == "&kp LG(LS(SPACE))")
        #expect(homerow.keyPositions == [13, 16])
    }

    @Test("Nested parameters survive a round trip")
    func nestedParameters() throws {
        let binding = BindingParser.parse("&kp LG(LS(SPACE))")
        #expect(binding.count == 1)
        #expect(binding[0].params == [
            BindingParam(value: "LG", params: [
                BindingParam(value: "LS", params: [BindingParam(value: "SPACE")])
            ])
        ])
        #expect(binding[0].text == "&kp LG(LS(SPACE))")
    }

    // MARK: Everything the editor must not touch

    @Test("Includes, defines, behaviors, overrides and combos are untouched")
    func nonLayerContentSurvives() throws {
        var keymap = try Fixture.cradio()
        try keymap.setBinding(layer: 0, index: 0, to: KeyBinding(
            behavior: "&kp", params: [BindingParam(value: "ESCAPE")]
        ))
        let output = try Fixture.write(keymap)

        for fragment in [
            "#include \"keymap_italian.h\"",
            "#include <dt-bindings/zmk/bt.h>",
            "#define POS_LH_T1 30",
            "#define THUMBS POS_LH_T1 POS_LH_T2 POS_RH_T1 POS_RH_T2",
            "&mt {\n    //  flavor = \"tap-preferred\";",
            "&sk { ignore-modifiers; };",
            "hml: hold_tap_left {",
            "hold-trigger-key-positions = <KEYS_RIGHT THUMBS>;",
            "bindings = <&kp>, <&kp>;",
            "// Base alpha layer",
            "        escape-combo {\n            bindings = <&kp ESC>;\n            key-positions = <1 3>;\n        };",
            "bindings = <&kp LG(LS(SPACE))>;",
        ] {
            #expect(output.contains(fragment), "lost: \(fragment.debugDescription)")
        }
    }

    @Test("A single-line combo cell is never reflowed into a table")
    func combosAreNotTables() throws {
        let source = try Fixture.cradioSource()
        let keymap = try KeymapFile(source: source)
        let output = try keymap.serialized(layout: Fixture.cradioLayout())
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("bindings = <&kp C_PLAY_PAUSE>;"))
        #expect(text.contains("bindings = <&mo>, <&tog>;"))
    }

    // MARK: Edits

    @Test("Changing a binding to one the same length is a one-line diff")
    func sameLengthEditIsOneLine() throws {
        let source = try Fixture.cradioText()
        var keymap = try KeymapFile(source: try Fixture.cradioSource())
        #expect(keymap.layers[0].bindings[33].text == "&lt 1 ENTER")
        try keymap.setBinding(layer: 0, index: 33, to: KeyBinding(
            behavior: "&lt", params: [BindingParam(value: "2"), BindingParam(value: "ENTER")]
        ))
        let output = try Fixture.write(keymap)

        let diff = Fixture.differingLines(source, output)
        #expect(diff.count == 1)
        #expect(diff.first?.0.hasSuffix("&lt 3 SPACE  &lt 1 ENTER") == true)
        #expect(diff.first?.1.hasSuffix("&lt 3 SPACE  &lt 2 ENTER") == true)
    }

    @Test("A longer binding reflows its whole column")
    func longerEditReflowsColumn() throws {
        var keymap = try KeymapFile(source: try Fixture.cradioSource())
        let long = KeyBinding(behavior: "&kp", params: [BindingParam(value: "LG(LS(LC(LA(SPACE))))")])
        #expect(long.text.count == 25)
        try keymap.setBinding(layer: 0, index: 0, to: long)
        let output = try Fixture.write(keymap)

        // Column 0 was 17 wide (`&hml LEFT_GUI A` + 2); the new binding makes it 27.
        let lines = try Fixture.bindingLines(of: "default_layer", in: output)
        #expect(lines.count == 4)
        #expect(lines[0] == "&kp LG(LS(LC(LA(SPACE))))  &kp W                &kp E            &kp R              &kp T                 &kp Y        &kp U              &kp I            &kp O                &kp P")
        #expect(lines[1].hasPrefix("&hml LEFT_GUI A            &hml LEFT_CONTROL S"))
        // The thumb row's leading indent grows with column 0.
        #expect(lines[3].prefix(while: { $0 == " " }).count == 27 + 21 + 17)
    }

    @Test("A shorter binding shrinks its column back")
    func shorterEditShrinksColumn() throws {
        var keymap = try KeymapFile(source: try Fixture.cradioSource())
        // `&hml LEFT_CONTROL S` is what makes column 1 twenty-one wide.
        try keymap.setBinding(layer: 0, index: 11, to: KeyBinding(
            behavior: "&kp", params: [BindingParam(value: "S")]
        ))
        let output = try Fixture.write(keymap)
        let lines = try Fixture.bindingLines(of: "default_layer", in: output)
        // Column 1's longest is now `&kp W`, so it falls to the seven-wide floor.
        #expect(lines[0].hasPrefix("&kp Q            &kp W  &kp E"))
    }

    @Test("An edit to one layer leaves the others alone")
    func editIsScopedToItsLayer() throws {
        let source = try Fixture.cradioText()
        var keymap = try KeymapFile(source: try Fixture.cradioSource())
        try keymap.setBinding(layer: 4, index: 0, to: KeyBinding(behavior: "&bootloader"))
        let output = try Fixture.write(keymap)
        #expect(try Fixture.bindingLines(of: "nav", in: output) == (try Fixture.bindingLines(of: "nav", in: source)))
        #expect(try Fixture.bindingLines(of: "symbols", in: output) == (try Fixture.bindingLines(of: "symbols", in: source)))
        #expect(try Fixture.bindingLines(of: "settings_layer", in: output)[0]
            == "&bootloader  &trans  &trans  &trans      &bt BT_SEL 0    &trans  &trans  &trans  &trans  &sys_reset")
    }

    @Test("Editing every layer at once still splices cleanly")
    func editEveryLayer() throws {
        var keymap = try KeymapFile(source: try Fixture.cradioSource())
        for layer in keymap.layers.indices {
            try keymap.setBinding(layer: layer, index: 9, to: KeyBinding(
                behavior: "&kp", params: [BindingParam(value: "SEMICOLON_AND_A_BIT_MORE")]
            ))
        }
        let output = try keymap.serialized(layout: Fixture.cradioLayout())
        let reparsed = try KeymapFile(source: output)
        #expect(reparsed.layers.count == 5)
        for layer in reparsed.layers {
            #expect(layer.bindings.count == 34)
            #expect(layer.bindings[9].text == "&kp SEMICOLON_AND_A_BIT_MORE")
        }
    }

    @Test("A saved file reparses to the same model")
    func saveIsIdempotent() throws {
        var keymap = try KeymapFile(source: try Fixture.cradioSource())
        try keymap.setBinding(layer: 2, index: 20, to: KeyBinding(
            behavior: "&mt",
            params: [BindingParam(value: "LEFT_SHIFT"), BindingParam(value: "TAB")]
        ))
        let once = try keymap.serialized(layout: Fixture.cradioLayout())
        let twice = try KeymapFile(source: once).serialized(layout: Fixture.cradioLayout())
        #expect(once == twice)
    }

    // MARK: Renaming a layer

    /// Two layers, one that names itself and one that leaves it to the node
    /// name, so both halves of the rule can be exercised on one file. The
    /// Cradio fixture has no `display-name` anywhere.
    private static let namedLayers = """
        / {
            keymap {
                compatible = "zmk,keymap";

                default_layer {
                    display-name = "Base";  // what the OLED shows
                    bindings = <&kp A>;
                };

                nav {
                    bindings = <&kp B>;
                };
            };
        };

        """

    private static let oneKey = [KeyPosition(row: 0, col: 0, x: 0, y: 0)]

    @Test("Renaming a layer that has a display-name rewrites just that string")
    func renameExistingDisplayName() throws {
        var keymap = try KeymapFile(source: Data(Self.namedLayers.utf8))
        try keymap.setLayerDisplayName(layer: 0, to: "Alpha")
        let output = String(decoding: try keymap.serialized(layout: Self.oneKey), as: UTF8.self)

        let diff = Fixture.differingLines(Self.namedLayers, output)
        #expect(diff.count == 1)
        // The trailing comment is why the value range is written and not the
        // whole property.
        #expect(diff.first?.1 == #"            display-name = "Alpha";  // what the OLED shows"#)
    }

    @Test("Renaming a layer that has none inserts the property before bindings")
    func renameInsertsDisplayName() throws {
        var keymap = try KeymapFile(source: Data(Self.namedLayers.utf8))
        #expect(keymap.layers[1].displayName == "Nav")
        try keymap.setLayerDisplayName(layer: 1, to: "Navigation")
        let output = String(decoding: try keymap.serialized(layout: Self.oneKey), as: UTF8.self)

        #expect(output.contains("""
                    nav {
                        display-name = "Navigation";
                        bindings = <&kp B>;
            """))
        #expect(try KeymapFile(source: Data(output.utf8)).layers[1].displayName == "Navigation")
        // The layer that was already named is not touched.
        #expect(output.contains(#"display-name = "Base";  // what the OLED shows"#))
    }

    @Test("Renaming a layer and back again is byte identical")
    func renameAndBackIsIdentical() throws {
        let source = Data(Self.namedLayers.utf8)
        var keymap = try KeymapFile(source: source)
        try keymap.setLayerDisplayName(layer: 0, to: "Alpha")
        try keymap.setLayerDisplayName(layer: 1, to: "Navigation")
        try keymap.setLayerDisplayName(layer: 0, to: "Base")
        try keymap.setLayerDisplayName(layer: 1, to: "Nav")
        #expect(try keymap.serialized(layout: Self.oneKey) == source)
    }

    @Test("A renamed layer in the real keymap changes nothing else")
    func renameInFixture() throws {
        let source = try Fixture.cradioText()
        var keymap = try KeymapFile(source: try Fixture.cradioSource())
        try keymap.setLayerDisplayName(layer: 1, to: "Motion")
        let output = try Fixture.write(keymap)

        let inserted = "            display-name = \"Motion\";\n"
        #expect(output.contains("""
                    nav {
                        display-name = "Motion";
                        bindings = <
            """))
        // One line added and nothing else: taking it back out restores the file.
        #expect(output.replacingOccurrences(of: inserted, with: "") == source)
    }

    @Test("An out-of-range layer or an unwritable name throws")
    func renameRejected() throws {
        var keymap = try Fixture.cradio()
        #expect(throws: KeymapError.layerOutOfRange(9)) {
            try keymap.setLayerDisplayName(layer: 9, to: "Nine")
        }
        #expect(throws: KeymapError.invalidDisplayName("")) {
            try keymap.setLayerDisplayName(layer: 0, to: "")
        }
        #expect(throws: KeymapError.invalidDisplayName(#"say "hi""#)) {
            try keymap.setLayerDisplayName(layer: 0, to: #"say "hi""#)
        }
        #expect(throws: KeymapError.invalidDisplayName("two\nlines")) {
            try keymap.setLayerDisplayName(layer: 0, to: "two\nlines")
        }
        #expect(keymap.layers[0].displayName == "Default Layer")
    }

    // MARK: Failure modes

    @Test("A keymap with no zmk,keymap node is rejected")
    func missingKeymapNode() {
        #expect(throws: KeymapError.noKeymapNode) {
            _ = try KeymapFile(source: Data("/ { combos { compatible = \"zmk,combos\"; }; };".utf8))
        }
    }

    @Test("A layout with fewer positions than bindings is rejected")
    func layoutTooSmall() throws {
        let keymap = try KeymapFile(source: try Fixture.cradioSource())
        let short = Array(try Fixture.cradioLayout().prefix(10))
        #expect(throws: KeymapError.self) {
            _ = try keymap.serialized(layout: short)
        }
    }

    @Test("Reshuffling layers behind addLayer's back is still refused")
    func layersMustClaimDistinctNodes() throws {
        var keymap = try Fixture.cradio()
        // Two layers claiming one node would splice both sets of bindings into
        // the same cell, so it is an error rather than a coin toss.
        keymap.layers.append(keymap.layers[0])
        #expect(throws: KeymapError.layerCountChanged(expected: 5, got: 6)) {
            _ = try Fixture.write(keymap)
        }
    }
}

// MARK: - Behaviors

@Suite("Behavior editing")
struct BehaviorEditingTests {
    @Test("Every behavior in the file is read, with its label and properties")
    func read() throws {
        let keymap = try Fixture.cradio()
        #expect(keymap.behaviors.map(\.label) == [
            "rpi", "hml", "hmr", "qt", "ht", "hold_temp_layer", "ht_pref_hold", "sticky_tap",
        ])
        let hml = try #require(keymap.behaviors.first { $0.label == "hml" })
        #expect(hml.nodeName == "hold_tap_left")
        #expect(hml.compatible == "zmk,behavior-hold-tap")
        #expect(hml.bindingCells == 2)
        #expect(hml.bindings == ["&kp", "&kp"])
        #expect(hml.properties.first { $0.name == "tapping-term-ms" }?.value == .integer(280))
        #expect(hml.properties.first { $0.name == "flavor" }?.value == .string("tap-preferred"))
        #expect(hml.properties.first { $0.name == "hold-trigger-on-release" }?.value == .flag)
    }

    @Test("An untouched behavior produces no edit at all")
    func untouchedWritesNothing() throws {
        // `hold-trigger-key-positions = <KEYS_RIGHT THUMBS>;` is the reason
        // this rule exists: those are preprocessor macros, and re-rendering a
        // behavior nobody touched would have to reproduce them.
        var keymap = try Fixture.cradio()
        let hml = try #require(keymap.behaviors.first { $0.label == "hml" })
        try keymap.upsertBehavior(hml)
        #expect(try Fixture.write(keymap) == (try Fixture.cradioText()))
    }

    @Test("Changing one property rewrites only that value")
    func changeProperty() throws {
        let source = try Fixture.cradioText()
        var keymap = try Fixture.cradio()
        var hml = try #require(keymap.behaviors.first { $0.label == "hml" })
        hml.properties = hml.properties.map {
            $0.name == "tapping-term-ms" ? BehaviorProperty(name: $0.name, value: .integer(220)) : $0
        }
        try keymap.upsertBehavior(hml)

        let diff = Fixture.differingLines(source, try Fixture.write(keymap))
        #expect(diff.count == 1)
        #expect(diff.first?.0 == "            tapping-term-ms = <280>;")
        #expect(diff.first?.1 == "            tapping-term-ms = <220>;")
    }

    @Test("A property the node did not have is added, and one it lost comes out")
    func addAndRemoveProperties() throws {
        var keymap = try Fixture.cradio()
        var ht = try #require(keymap.behaviors.first { $0.label == "ht" })
        ht.properties.removeAll { $0.name == "quick-tap-ms" }
        ht.properties.append(BehaviorProperty(name: "retro-tap", value: .flag))
        try keymap.upsertBehavior(ht)

        let output = try Fixture.write(keymap)
        #expect(output.contains("retro-tap;"))

        let reparsed = try KeymapFile(source: Data(output.utf8))
        let saved = try #require(reparsed.behaviors.first { $0.label == "ht" })
        #expect(saved.properties.map(\.name) == ["tapping-term-ms", "flavor", "retro-tap"])
    }

    @Test("Renaming a behavior rewrites its label and its node name")
    func rename() throws {
        var keymap = try Fixture.cradio()
        var qt = try #require(keymap.behaviors.first { $0.label == "qt" })
        qt.label = "quick"
        qt.nodeName = "quick_tap_behavior"
        try keymap.upsertBehavior(qt)

        let output = try Fixture.write(keymap)
        #expect(output.contains("quick: quick_tap_behavior {"))
        #expect(try KeymapFile(source: Data(output.utf8)).behaviors.map(\.label).contains("quick"))
    }

    @Test("A new behavior is appended to the behaviors node and reparses")
    func addBehavior() throws {
        var keymap = try Fixture.cradio()
        try keymap.upsertBehavior(KeymapBehavior(
            nodeName: "shift_morph",
            label: "smorph",
            compatible: BehaviorKind.modMorph.compatible,
            bindingCells: 0,
            bindings: ["&kp COMMA", "&kp SEMICOLON"],
            properties: [BehaviorProperty(name: "mods", value: .tokens(["MOD_LSFT", "MOD_RSFT"]))]
        ))

        let output = try Fixture.write(keymap)
        let reparsed = try KeymapFile(source: Data(output.utf8))
        let added = try #require(reparsed.behaviors.first { $0.label == "smorph" })
        #expect(added.nodeName == "shift_morph")
        #expect(added.compatible == "zmk,behavior-mod-morph")
        #expect(added.bindings == ["&kp COMMA", "&kp SEMICOLON"])
        #expect(added.properties.first?.value == .tokens(["MOD_LSFT", "MOD_RSFT"]))
        // Nothing else moved.
        #expect(reparsed.behaviors.count == keymap.behaviors.count)
        #expect(reparsed.layers.count == 5)
        #expect(reparsed.combos.count == 13)
    }

    @Test("A file with no behaviors node gets one, in front of the keymap")
    func createSection() throws {
        var keymap = try KeymapFile(source: Data(Self.bareKeymap.utf8))
        #expect(keymap.behaviors.isEmpty)
        try keymap.upsertBehavior(KeymapBehavior(
            nodeName: "hold_tap_left", label: "hml",
            compatible: BehaviorKind.holdTap.compatible,
            bindingCells: 2, bindings: ["&kp", "&kp"],
            properties: [BehaviorProperty(name: "tapping-term-ms", value: .integer(280))]
        ))

        let output = String(decoding: try keymap.serialized(layout: Self.twoKeys), as: UTF8.self)
        #expect(output.contains("""
                behaviors {
                    hml: hold_tap_left {
                        compatible = "zmk,behavior-hold-tap";
                        #binding-cells = <2>;
                        bindings = <&kp>, <&kp>;
                        tapping-term-ms = <280>;
                    };
                };

                keymap {
            """))
        let reparsed = try KeymapFile(source: Data(output.utf8))
        #expect(reparsed.behaviors.map(\.label) == ["hml"])
        // A saved file is a fixed point: reading it back and writing it again
        // changes nothing.
        #expect(String(decoding: try reparsed.serialized(layout: Self.twoKeys), as: UTF8.self) == output)
    }

    @Test("Removing a behavior takes its node and its blank line")
    func removeBehavior() throws {
        var keymap = try Fixture.cradio()
        let qt = try #require(keymap.behaviors.first { $0.label == "qt" })
        try keymap.removeBehavior(id: qt.id)

        let output = try Fixture.write(keymap)
        #expect(!output.contains("qt: quick_tap {"))
        #expect(output.contains("""
                    ht: hold_tap {
            """))
        let reparsed = try KeymapFile(source: Data(output.utf8))
        #expect(reparsed.behaviors.map(\.label)
            == ["rpi", "hml", "hmr", "ht", "hold_temp_layer", "ht_pref_hold", "sticky_tap"])
        #expect(reparsed.layers.count == 5)
    }

    @Test("Removing a behavior that is not there is an error, not a no-op")
    func removeMissing() throws {
        var keymap = try Fixture.cradio()
        #expect(throws: KeymapError.behaviorNotFound) {
            try keymap.removeBehavior(id: UUID())
        }
    }

    @Test("A node name another behavior already uses is refused")
    func duplicateName() throws {
        var keymap = try Fixture.cradio()
        #expect(throws: KeymapError.duplicateNodeName("hold_tap_left")) {
            try keymap.upsertBehavior(KeymapBehavior(
                nodeName: "hold_tap_left", label: "other",
                compatible: BehaviorKind.holdTap.compatible,
                bindingCells: 2, bindings: ["&kp", "&kp"], properties: []
            ))
        }
        #expect(throws: KeymapError.invalidNodeName("not a name!")) {
            try keymap.upsertBehavior(KeymapBehavior(
                nodeName: "not a name!", label: "x",
                compatible: BehaviorKind.holdTap.compatible,
                bindingCells: 2, bindings: [], properties: []
            ))
        }
    }

    @Test("Editing behaviors leaves every layer and combo alone")
    func nothingElseMoves() throws {
        let source = try Fixture.cradioText()
        var keymap = try Fixture.cradio()
        var hmr = try #require(keymap.behaviors.first { $0.label == "hmr" })
        hmr.bindingCells = 2
        hmr.properties.append(BehaviorProperty(name: "retro-tap", value: .flag))
        try keymap.upsertBehavior(hmr)

        let output = try Fixture.write(keymap)
        for layer in ["default_layer", "nav", "num", "symbols", "settings_layer"] {
            #expect(try Fixture.bindingLines(of: layer, in: output)
                == (try Fixture.bindingLines(of: layer, in: source)))
        }
        // The macros in the sibling behavior are untouched.
        #expect(output.contains("hold-trigger-key-positions = <KEYS_LEFT THUMBS>;"))
    }

    static let bareKeymap = """
        / {
            keymap {
                compatible = "zmk,keymap";

                base {
                    bindings = <
        &kp A  &kp B
                    >;
                };
            };
        };

        """

    static let twoKeys = [
        KeyPosition(row: 0, col: 0, x: 0, y: 0), KeyPosition(row: 0, col: 1, x: 1, y: 0),
    ]
}

// MARK: - Macros

@Suite("Macro editing")
struct MacroEditingTests {
    /// The fixture has no macros, so the cases that need an existing one work
    /// from this — a real multi-step macro plus a parameterised one.
    static let withMacros = """
        / {
            macros {
                em: email {
                    compatible = "zmk,behavior-macro";
                    #binding-cells = <0>;
                    wait-ms = <30>;
                    tap-ms = <30>;
                    bindings = <&kp M &kp E>;
                };

                lp: layer_param {
                    compatible = "zmk,behavior-macro-one-param";
                    #binding-cells = <1>;
                    bindings
                        = <&macro_press>
                        , <&macro_param_1to1 &mo MACRO_PLACEHOLDER>
                        ;
                };
            };

            keymap {
                compatible = "zmk,keymap";

                base {
                    bindings = <
        &kp A  &kp B
                    >;
                };
            };
        };

        """

    static let twoKeys = BehaviorEditingTests.twoKeys

    private static func file() throws -> KeymapFile {
        try KeymapFile(source: Data(withMacros.utf8))
    }

    @Test("A macro is read as a flat sequence of real bindings")
    func read() throws {
        let keymap = try Self.file()
        #expect(keymap.macros.map(\.label) == ["em", "lp"])
        let email = try #require(keymap.macros.first { $0.label == "em" })
        #expect(email.nodeName == "email")
        #expect(email.compatible == "zmk,behavior-macro")
        #expect(email.bindingCells == 0)
        #expect(email.waitMs == 30)
        #expect(email.tapMs == 30)
        #expect(email.bindings.map(\.text) == ["&kp M", "&kp E"])

        // The groups a macro is split across carry no meaning; ZMK
        // concatenates them, so they read back as one sequence.
        let param = try #require(keymap.macros.first { $0.label == "lp" })
        #expect(param.bindings.map(\.text)
            == ["&macro_press", "&macro_param_1to1", "&mo MACRO_PLACEHOLDER"])
        #expect(param.bindingCells == 1)
    }

    @Test("A macro is not also read as a behavior")
    func macrosAreNotBehaviors() throws {
        // Both readers claiming a node would put two splices on the same bytes.
        let keymap = try Self.file()
        #expect(keymap.behaviors.isEmpty)
    }

    @Test("An untouched keymap with macros round trips byte for byte")
    func roundTrip() throws {
        let keymap = try Self.file()
        let output = try keymap.serialized(layout: Self.twoKeys)
        #expect(String(decoding: output, as: UTF8.self) == Self.withMacros)
    }

    @Test("Changing a macro's wait time rewrites only that value")
    func changeWait() throws {
        var keymap = try Self.file()
        var email = try #require(keymap.macros.first { $0.label == "em" })
        email.waitMs = 10
        try keymap.upsertMacro(email)

        let output = String(decoding: try keymap.serialized(layout: Self.twoKeys), as: UTF8.self)
        let diff = Fixture.differingLines(Self.withMacros, output)
        #expect(diff.count == 1)
        #expect(diff.first?.1 == "            wait-ms = <10>;")
    }

    @Test("Changing a macro's sequence rewrites the whole bindings property")
    func changeBindings() throws {
        var keymap = try Self.file()
        var email = try #require(keymap.macros.first { $0.label == "em" })
        email.bindings = BindingParser.parse("&kp H &kp I &kp EXCL")
        try keymap.upsertMacro(email)

        let output = String(decoding: try keymap.serialized(layout: Self.twoKeys), as: UTF8.self)
        #expect(output.contains("bindings = <&kp H &kp I &kp EXCL>;"))
        let reparsed = try KeymapFile(source: Data(output.utf8))
        #expect(try #require(reparsed.macros.first).bindings.map(\.text)
            == ["&kp H", "&kp I", "&kp EXCL"])
    }

    @Test("A new macro is appended and reparses to the same sequence")
    func addMacro() throws {
        var keymap = try Self.file()
        try keymap.upsertMacro(KeymapMacro(
            nodeName: "shrug", label: "shrug",
            compatible: MacroKind.plain.compatible,
            bindingCells: 0,
            bindings: BindingParser.parse("&kp LS(N9) &kp MINUS &kp LS(N0)"),
            waitMs: nil, tapMs: 5
        ))

        let output = String(decoding: try keymap.serialized(layout: Self.twoKeys), as: UTF8.self)
        let reparsed = try KeymapFile(source: Data(output.utf8))
        #expect(reparsed.macros.map(\.label) == ["em", "lp", "shrug"])
        let added = try #require(reparsed.macros.last)
        #expect(added.bindings.map(\.text) == ["&kp LS(N9)", "&kp MINUS", "&kp LS(N0)"])
        #expect(added.tapMs == 5)
        #expect(added.waitMs == nil)
        #expect(reparsed.layers.count == 1)
    }

    @Test("A file with no macros node gets one, in front of the keymap")
    func createSection() throws {
        var keymap = try KeymapFile(source: Data(BehaviorEditingTests.bareKeymap.utf8))
        #expect(keymap.macros.isEmpty)
        try keymap.upsertMacro(KeymapMacro(
            nodeName: "hi", label: "hi",
            compatible: MacroKind.plain.compatible, bindingCells: 0,
            bindings: BindingParser.parse("&kp H &kp I"), waitMs: nil, tapMs: nil
        ))

        let output = String(decoding: try keymap.serialized(layout: Self.twoKeys), as: UTF8.self)
        #expect(output.contains("    macros {\n        hi: hi {"))
        let reparsed = try KeymapFile(source: Data(output.utf8))
        #expect(reparsed.macros.map(\.label) == ["hi"])
        #expect(reparsed.layers.map(\.nodeName) == ["base"])
        #expect(String(decoding: try reparsed.serialized(layout: Self.twoKeys), as: UTF8.self) == output)
    }

    @Test("Removing a macro takes its node with it")
    func removeMacro() throws {
        var keymap = try Self.file()
        try keymap.removeMacro(id: try #require(keymap.macros.first).id)

        let output = String(decoding: try keymap.serialized(layout: Self.twoKeys), as: UTF8.self)
        #expect(!output.contains("em: email"))
        #expect(try KeymapFile(source: Data(output.utf8)).macros.map(\.label) == ["lp"])
    }

    @Test("Removing a macro that is not there is an error")
    func removeMissing() throws {
        var keymap = try Self.file()
        #expect(throws: KeymapError.macroNotFound) { try keymap.removeMacro(id: UUID()) }
    }

    @Test("Saving a macro edit twice produces the same bytes")
    func saveIsIdempotent() throws {
        var keymap = try Self.file()
        var email = try #require(keymap.macros.first)
        email.bindings = BindingParser.parse("&kp A &kp B &kp C &kp D")
        email.tapMs = nil
        try keymap.upsertMacro(email)

        let once = try keymap.serialized(layout: Self.twoKeys)
        let twice = try KeymapFile(source: once).serialized(layout: Self.twoKeys)
        #expect(once == twice)
        #expect(!String(decoding: once, as: UTF8.self).contains("tap-ms"))
    }
}

// MARK: - Adding and removing layers

@Suite("Layer structure")
struct LayerStructureTests {
    @Test("A new layer is written at the end and reparses at its own number")
    func appendLayer() throws {
        var keymap = try Fixture.cradio()
        try keymap.addLayer(
            nodeName: "gaming", displayName: "Gaming",
            bindings: Array(repeating: KeyBinding(behavior: "&trans"), count: 34),
            at: keymap.layers.count
        )
        #expect(keymap.layers.map(\.id) == [0, 1, 2, 3, 4, 5])
        #expect(keymap.layers.last?.sourceIndex == nil)

        let reparsed = try KeymapFile(source: Data(try Fixture.write(keymap).utf8))
        #expect(reparsed.layers.map(\.nodeName) == [
            "default_layer", "nav", "num", "symbols", "settings_layer", "gaming",
        ])
        #expect(reparsed.layers.map(\.id) == [0, 1, 2, 3, 4, 5])
        #expect(reparsed.layers[5].displayName == "Gaming")
        #expect(reparsed.layers[5].bindings.count == 34)
        #expect(reparsed.combos.count == 13)
    }

    @Test("A layer inserted in the middle renumbers the ones after it")
    func insertLayer() throws {
        var keymap = try Fixture.cradio()
        try keymap.addLayer(
            nodeName: "media", displayName: nil,
            bindings: Array(repeating: KeyBinding(behavior: "&trans"), count: 34),
            at: 1
        )
        #expect(keymap.layers.map(\.nodeName) == [
            "default_layer", "media", "nav", "num", "symbols", "settings_layer",
        ])
        #expect(keymap.layers.map(\.id) == [0, 1, 2, 3, 4, 5])
        // The layers that came from the file still point at their own nodes.
        #expect(keymap.layers.map(\.sourceIndex) == [0, nil, 1, 2, 3, 4])

        let output = try Fixture.write(keymap)
        let reparsed = try KeymapFile(source: Data(output.utf8))
        #expect(reparsed.layers.map(\.nodeName) == [
            "default_layer", "media", "nav", "num", "symbols", "settings_layer",
        ])
        // A display name equal to the humanized node name is not written.
        #expect(!output.contains("display-name = \"Media\""))
        #expect(reparsed.layers[1].displayName == "Media")
        // Every other layer's bindings came through untouched, which is what
        // the old positional zip could not do.
        for name in ["default_layer", "nav", "num", "symbols", "settings_layer"] {
            #expect(try Fixture.bindingLines(of: name, in: output)
                == (try Fixture.bindingLines(of: name, in: try Fixture.cradioText())))
        }
    }

    @Test("An explicit display name is written as a property")
    func explicitDisplayName() throws {
        var keymap = try Fixture.cradio()
        try keymap.addLayer(
            nodeName: "fn", displayName: "Function Keys",
            bindings: [KeyBinding(behavior: "&trans")], at: 5
        )
        let output = try Fixture.write(keymap)
        #expect(output.contains("""
                    fn {
                        display-name = "Function Keys";
                        bindings = <
            """))
    }

    @Test("Removing a layer takes its node and renumbers the rest")
    func removeLayer() throws {
        let source = try Fixture.cradioText()
        var keymap = try Fixture.cradio()
        try keymap.removeLayer(at: 2)
        #expect(keymap.layers.map(\.nodeName) == ["default_layer", "nav", "symbols", "settings_layer"])
        #expect(keymap.layers.map(\.id) == [0, 1, 2, 3])
        #expect(keymap.layers.map(\.sourceIndex) == [0, 1, 3, 4])

        let output = try Fixture.write(keymap)
        let reparsed = try KeymapFile(source: Data(output.utf8))
        #expect(reparsed.layers.map(\.nodeName) == ["default_layer", "nav", "symbols", "settings_layer"])
        // `symbols` kept its own bindings rather than inheriting `num`'s.
        #expect(try Fixture.bindingLines(of: "symbols", in: output)
            == (try Fixture.bindingLines(of: "symbols", in: source)))
        #expect(reparsed.combos.count == 13)
        #expect(reparsed.behaviors.count == 8)
    }

    @Test("The last layer cannot be removed")
    func lastLayer() throws {
        var keymap = try KeymapFile(source: Data(BehaviorEditingTests.bareKeymap.utf8))
        #expect(throws: KeymapError.lastLayerRemoved) { try keymap.removeLayer(at: 0) }
        #expect(keymap.layers.count == 1)
    }

    @Test("An out-of-range index is refused for both add and remove")
    func outOfRange() throws {
        var keymap = try Fixture.cradio()
        #expect(throws: KeymapError.layerIndexOutOfRange(9)) { try keymap.removeLayer(at: 9) }
        #expect(throws: KeymapError.layerIndexOutOfRange(9)) {
            try keymap.addLayer(nodeName: "x", displayName: nil, bindings: [], at: 9)
        }
        #expect(throws: KeymapError.duplicateNodeName("nav")) {
            try keymap.addLayer(nodeName: "nav", displayName: nil, bindings: [], at: 0)
        }
        #expect(throws: KeymapError.invalidNodeName("two words")) {
            try keymap.addLayer(nodeName: "two words", displayName: nil, bindings: [], at: 0)
        }
        #expect(throws: KeymapError.invalidDisplayName(#"say "hi""#)) {
            try keymap.addLayer(nodeName: "ok", displayName: #"say "hi""#, bindings: [], at: 0)
        }
        #expect(keymap.layers.count == 5)
    }

    @Test("Adding and removing layers saves to a fixed point")
    func saveIsIdempotent() throws {
        var keymap = try Fixture.cradio()
        try keymap.removeLayer(at: 1)
        try keymap.addLayer(
            nodeName: "media", displayName: "Media Keys",
            bindings: Array(repeating: KeyBinding(behavior: "&trans"), count: 34), at: 1
        )
        try keymap.addLayer(
            nodeName: "gaming", displayName: nil,
            bindings: Array(repeating: KeyBinding(behavior: "&trans"), count: 34), at: 4
        )

        let once = try keymap.serialized(layout: Fixture.cradioLayout())
        let twice = try KeymapFile(source: once).serialized(layout: Fixture.cradioLayout())
        #expect(once == twice)

        let reparsed = try KeymapFile(source: once)
        #expect(reparsed.layers.map(\.nodeName) == [
            "default_layer", "media", "num", "symbols", "gaming", "settings_layer",
        ])
        #expect(reparsed.layers.map(\.id) == [0, 1, 2, 3, 4, 5])
    }

    // MARK: References to the numbers that move

    @Test("Removing a layer reports every reference to a number that shifts")
    func referencesOnRemoval() throws {
        let keymap = try Fixture.cradio()
        let affected = keymap.layerReferencesAffected(byRemoving: 1)
        #expect(affected.contains { $0.contains("`&lt 1 ENTER`") && $0.contains("layer 0") })
        #expect(affected.contains { $0.contains("`&lt 3 SPACE`") })
        #expect(affected.contains { $0.contains("`&sl 4`") })
        #expect(affected.contains { $0.contains("combo `layer-nums`") && $0.contains("&mo 2") })
        // Layer 0 is below the cut, so nothing points at it from here.
        #expect(!affected.contains { $0.contains("`&mo 0`") })
    }

    @Test("Inserting a layer reports the references at and after it")
    func referencesOnInsertion() throws {
        let keymap = try Fixture.cradio()
        #expect(keymap.layerReferencesAffected(byInsertingAt: 4).allSatisfy {
            $0.contains(" 4") || $0.contains("layer 4")
        })
        // Appending after the last layer moves nothing.
        #expect(keymap.layerReferencesAffected(byInsertingAt: 5).isEmpty)
    }

    @Test("An index that is not a layer reports nothing rather than guessing")
    func referencesOutOfRange() throws {
        let keymap = try Fixture.cradio()
        #expect(keymap.layerReferencesAffected(byRemoving: 9).isEmpty)
        #expect(keymap.layerReferencesAffected(byInsertingAt: 9).isEmpty)
    }

    @Test("A combo's layers property counts as a reference")
    func comboLayersAreReferences() throws {
        var keymap = try Fixture.cradio()
        var escape = try Fixture.combo(keymap, named: "escape-combo")
        escape.layers = [0, 2]
        keymap.updateCombo(escape)
        let affected = keymap.layerReferencesAffected(byRemoving: 2)
        #expect(affected.contains("combo `escape-combo` is limited to layer 2"))
    }
}
