import Foundation
import Testing

@testable import ZmkonfigKit

@Suite("Combo editing")
struct ComboEditingTests {
    // MARK: Helpers

    /// The `escape-combo` node, which the fixture writes in the usual shape.
    private static let escapeCombo = """
                escape-combo {
                    bindings = <&kp ESC>;
                    key-positions = <1 3>;
                };
        """

    // MARK: Editing what is already there

    @Test("Changing a combo's binding rewrites only that line")
    func editBinding() throws {
        let source = try Fixture.cradioText()
        var keymap = try Fixture.cradio()
        var escape = try Fixture.combo(keymap, named: "escape-combo")
        escape.binding = KeyBinding(behavior: "&kp", params: [BindingParam(value: "CAPSLOCK")])
        keymap.updateCombo(escape)

        let output = try Fixture.write(keymap)
        let diff = Fixture.differingLines(source, output)
        #expect(diff.count == 1)
        #expect(diff.first?.0 == "            bindings = <&kp ESC>;")
        #expect(diff.first?.1 == "            bindings = <&kp CAPSLOCK>;")
    }

    @Test("Changing key positions rewrites only the key-positions value")
    func editKeyPositions() throws {
        let source = try Fixture.cradioText()
        var keymap = try Fixture.cradio()
        var escape = try Fixture.combo(keymap, named: "escape-combo")
        escape.keyPositions = [2, 3, 4]
        keymap.updateCombo(escape)

        let diff = Fixture.differingLines(source, try Fixture.write(keymap))
        #expect(diff.count == 1)
        #expect(diff.first?.1 == "            key-positions = <2 3 4>;")
    }

    @Test("Renaming a combo touches the name and nothing else")
    func rename() throws {
        let source = try Fixture.cradioText()
        var keymap = try Fixture.cradio()
        var escape = try Fixture.combo(keymap, named: "escape-combo")
        escape.nodeName = "esc"
        keymap.updateCombo(escape)

        let diff = Fixture.differingLines(source, try Fixture.write(keymap))
        #expect(diff.count == 1)
        #expect(diff.first?.0 == "        escape-combo {")
        #expect(diff.first?.1 == "        esc {")
    }

    @Test("A property the combo did not have is added after the ones it did")
    func addProperty() throws {
        var keymap = try Fixture.cradio()
        var escape = try Fixture.combo(keymap, named: "escape-combo")
        escape.timeoutMs = 40
        escape.layers = [0, 1]
        escape.requirePriorIdleMs = 125
        escape.isSlowRelease = true
        keymap.updateCombo(escape)

        let output = try Fixture.write(keymap)
        #expect(output.contains("""
                    escape-combo {
                        bindings = <&kp ESC>;
                        key-positions = <1 3>;
                        timeout-ms = <40>;
                        layers = <0 1>;
                        require-prior-idle-ms = <125>;
                        slow-release;
                    };
            """))
    }

    @Test("Clearing a property takes its whole line out")
    func removeProperty() throws {
        var keymap = try Fixture.cradio()
        var escape = try Fixture.combo(keymap, named: "escape-combo")
        escape.timeoutMs = 40
        keymap.updateCombo(escape)
        let withTimeout = try KeymapFile(source: try keymap.serialized(layout: Fixture.cradioLayout()))

        var cleared = try Fixture.combo(withTimeout, named: "escape-combo")
        #expect(cleared.timeoutMs == 40)
        cleared.timeoutMs = nil
        var second = withTimeout
        second.updateCombo(cleared)

        let output = try Fixture.write(second)
        #expect(!output.contains("timeout-ms"))
        #expect(output.contains(ComboEditingTests.escapeCombo))
    }

    @Test("Changing an existing property's value leaves its line's shape alone")
    func changeExistingProperty() throws {
        let source = """
            / {
                combos {
                    compatible = "zmk,combos";

                    esc {
                        bindings = <&kp ESC>;
                        key-positions = <1 3>;
                        timeout-ms = <50>;  // deliberately slow
                    };
                };

                keymap {
                    compatible = "zmk,keymap";
                    base {
                        bindings = <&kp A>;
                    };
                };
            };

            """
        var keymap = try KeymapFile(source: Data(source.utf8))
        var esc = try Fixture.combo(keymap, named: "esc")
        #expect(esc.timeoutMs == 50)
        esc.timeoutMs = 75
        keymap.updateCombo(esc)

        let output = String(
            decoding: try keymap.serialized(layout: [KeyPosition(row: 0, col: 0, x: 0, y: 0)]),
            as: UTF8.self
        )
        #expect(output.contains("timeout-ms = <75>;  // deliberately slow"))
    }

    // MARK: Adding

    @Test("A new combo is appended to the combos node and reparses")
    func addCombo() throws {
        var keymap = try Fixture.cradio()
        keymap.addCombo(KeymapCombo(
            nodeName: "caps-word",
            binding: KeyBinding(behavior: "&caps_word"),
            keyPositions: [12, 17],
            timeoutMs: 40
        ))

        let output = try Fixture.write(keymap)
        #expect(output.contains("""
                    layer-nums {
                        bindings = <&mo 2>;
                        key-positions = <31 32>;
                    };

                    caps-word {
                        bindings = <&caps_word>;
                        key-positions = <12 17>;
                        timeout-ms = <40>;
                    };
                };
            """))

        let reparsed = try KeymapFile(source: Data(output.utf8))
        #expect(reparsed.combos.count == 14)
        let added = try Fixture.combo(reparsed, named: "caps-word")
        #expect(added.binding.text == "&caps_word")
        #expect(added.keyPositions == [12, 17])
        #expect(added.timeoutMs == 40)
        #expect(reparsed.layers.count == 5)
    }

    @Test("Several new combos keep the order they were added in")
    func addSeveral() throws {
        var keymap = try Fixture.cradio()
        for (index, name) in ["first", "second", "third"].enumerated() {
            keymap.addCombo(KeymapCombo(
                nodeName: name,
                binding: KeyBinding(behavior: "&kp", params: [BindingParam(value: "F\(index + 1)")]),
                keyPositions: [index, index + 1]
            ))
        }
        let reparsed = try KeymapFile(source: Data(try Fixture.write(keymap).utf8))
        #expect(reparsed.combos.suffix(3).map(\.nodeName) == ["first", "second", "third"])
        #expect(reparsed.combos.suffix(3).map(\.binding.text) == ["&kp F1", "&kp F2", "&kp F3"])
    }

    @Test("A keymap with no combos node gets one, in front of the keymap")
    func createCombosSection() throws {
        let source = """
            #include <behaviors.dtsi>

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
        var keymap = try KeymapFile(source: Data(source.utf8))
        #expect(keymap.combos.isEmpty)
        keymap.addCombo(KeymapCombo(
            nodeName: "ab-tab",
            binding: KeyBinding(behavior: "&kp", params: [BindingParam(value: "TAB")]),
            keyPositions: [0, 1]
        ))

        let layout = [
            KeyPosition(row: 0, col: 0, x: 0, y: 0), KeyPosition(row: 0, col: 1, x: 1, y: 0),
        ]
        let output = String(decoding: try keymap.serialized(layout: layout), as: UTF8.self)
        #expect(output.contains("""
                combos {
                    compatible = "zmk,combos";

                    ab-tab {
                        bindings = <&kp TAB>;
                        key-positions = <0 1>;
                    };
                };

                keymap {
            """))

        let reparsed = try KeymapFile(source: Data(output.utf8))
        #expect(reparsed.combos.map(\.nodeName) == ["ab-tab"])
        #expect(reparsed.layers.map(\.nodeName) == ["base"])
        #expect(String(decoding: try reparsed.serialized(layout: layout), as: UTF8.self) == output)
    }

    @Test("A new combo's node name is made unique against the ones already there")
    func uniqueNames() throws {
        let keymap = try Fixture.cradio()
        #expect(keymap.uniqueComboName(startingFrom: "delete") == "delete-2")
        #expect(keymap.uniqueComboName(startingFrom: "Caps Word!") == "caps-word")
        #expect(keymap.uniqueComboName(startingFrom: "") == "combo")
    }

    @Test("A new combo's node name also avoids the behaviors, macros and layers")
    func uniqueNamesAcrossKinds() throws {
        let keymap = try Fixture.cradio()
        // `quick_tap` is a behavior node, not a combo. Checking only the combos
        // let a new combo be minted with a name a sibling node already had.
        #expect(keymap.behaviors.contains { $0.nodeName == "quick_tap" })
        #expect(keymap.uniqueComboName(startingFrom: "quick_tap") == "quick_tap-2")
        #expect(keymap.uniqueComboName(startingFrom: "default_layer") == "default_layer-2")
    }

    @Test("A hex timeout-ms is a number, not a missing property")
    func hexTimeout() throws {
        let source = """
            / {
                combos {
                    compatible = "zmk,combos";

                    escape-combo {
                        bindings = <&kp ESC>;
                        key-positions = <1 3>;
                        timeout-ms = <0x1e>;
                        require-prior-idle-ms = <0XA>;
                    };
                };

                keymap {
                    compatible = "zmk,keymap";

                    base {
                        bindings = <&kp A &kp B>;
                    };
                };
            };
            """
        let keymap = try KeymapFile(source: Data(source.utf8))
        let combo = try #require(keymap.combos.first)
        #expect(combo.timeoutMs == 30)
        #expect(combo.requirePriorIdleMs == 10)

        // Reading it as a number is only safe if writing it back leaves the
        // hex alone: the value did not change, so nothing is spliced.
        let layout = (0..<2).map { KeyPosition(row: 0, col: $0, x: Double($0), y: 0) }
        #expect(String(decoding: try keymap.serialized(layout: layout), as: UTF8.self) == source)
    }

    // MARK: Removing

    @Test("Removing a combo takes its node and the blank line after it")
    func removeCombo() throws {
        var keymap = try Fixture.cradio()
        let volumeUp = try Fixture.combo(keymap, named: "volume-up")
        keymap.removeCombo(id: volumeUp.id)

        let output = try Fixture.write(keymap)
        #expect(!output.contains("volume-up"))
        #expect(output.contains("""
                    delete {
                        bindings = <&kp DEL>;
                        key-positions = <13 14>;
                    };

                    volume-down {
            """))
        #expect(try KeymapFile(source: Data(output.utf8)).combos.count == 12)
    }

    @Test("Removing the last combo takes the blank line before it instead")
    func removeLastCombo() throws {
        var keymap = try Fixture.cradio()
        keymap.removeCombo(id: try Fixture.combo(keymap, named: "layer-nums").id)

        let output = try Fixture.write(keymap)
        #expect(output.contains("""
                    tab-next {
                        bindings = <&kp LC(TAB)>;
                        key-positions = <23 22>;
                    };
                };
            """))
    }

    @Test("Emptying the combos node and adding one back still writes valid text")
    func replaceEveryCombo() throws {
        var keymap = try Fixture.cradio()
        for existing in keymap.combos { keymap.removeCombo(id: existing.id) }
        keymap.addCombo(KeymapCombo(
            nodeName: "only",
            binding: KeyBinding(behavior: "&kp", params: [BindingParam(value: "ESC")]),
            keyPositions: [1, 3]
        ))

        let reparsed = try KeymapFile(source: Data(try Fixture.write(keymap).utf8))
        #expect(reparsed.combos.map(\.nodeName) == ["only"])
        #expect(reparsed.layers.count == 5)
    }

    // MARK: Positions the editor cannot resolve

    @Test("Positions written as macros are kept when only the binding changes")
    func macroPositionsSurvive() throws {
        let source = """
            #define POS_LH_T1 30

            / {
                combos {
                    compatible = "zmk,combos";

                    thumbs {
                        bindings = <&kp ESC>;
                        key-positions = <POS_LH_T1 1>;
                    };
                };

                keymap {
                    compatible = "zmk,keymap";
                    base {
                        bindings = <&kp A>;
                    };
                };
            };

            """
        var keymap = try KeymapFile(source: Data(source.utf8))
        var thumbs = try Fixture.combo(keymap, named: "thumbs")
        #expect(thumbs.keyPositions == [1])
        #expect(thumbs.unresolvedPositions == ["POS_LH_T1"])

        thumbs.binding = KeyBinding(behavior: "&kp", params: [BindingParam(value: "TAB")])
        keymap.updateCombo(thumbs)

        let layout = [KeyPosition(row: 0, col: 0, x: 0, y: 0)]
        let output = String(decoding: try keymap.serialized(layout: layout), as: UTF8.self)
        #expect(output.contains("key-positions = <POS_LH_T1 1>;"))
        #expect(output.contains("bindings = <&kp TAB>;"))
    }

    @Test("An untouched keymap full of macro positions round trips byte for byte")
    func macroPositionsRoundTrip() throws {
        let source = """
            / {
                combos {
                    compatible = "zmk,combos";

                    thumbs {
                        bindings = <&kp ESC>;
                        key-positions = <POS_LH_T1 POS_RH_T1>;
                    };
                };

                keymap {
                    compatible = "zmk,keymap";
                    base {
                        bindings = <&kp A>;
                    };
                };
            };

            """
        let keymap = try KeymapFile(source: Data(source.utf8))
        let output = try keymap.serialized(layout: [KeyPosition(row: 0, col: 0, x: 0, y: 0)])
        #expect(String(decoding: output, as: UTF8.self) == source)
    }

    // MARK: Validation

    @Test("An unedited keymap reports no problems")
    func noProblemsWhenUntouched() throws {
        let keymap = try Fixture.cradio()
        #expect(keymap.comboProblems(positionCount: 34).isEmpty)
        #expect(!keymap.hasComboEdits)
    }

    @Test("A combo with fewer than two key positions is rejected")
    func tooFewPositions() throws {
        var keymap = try Fixture.cradio()
        var escape = try Fixture.combo(keymap, named: "escape-combo")
        escape.keyPositions = [1]
        keymap.updateCombo(escape)

        let problems = keymap.comboProblems(positionCount: 34)
        #expect(problems.count == 1)
        #expect(problems.first?.message.contains("at least two key positions") == true)
        #expect(throws: KeymapError.self) { _ = try Fixture.write(keymap) }
    }

    @Test("A key position outside the layout is rejected")
    func positionOutsideLayout() throws {
        var keymap = try Fixture.cradio()
        var escape = try Fixture.combo(keymap, named: "escape-combo")
        escape.keyPositions = [1, 99]
        keymap.updateCombo(escape)
        #expect(keymap.comboProblems(positionCount: 34).first?.message.contains("99") == true)
    }

    @Test("Two combos with the same name are rejected")
    func duplicateNames() throws {
        var keymap = try Fixture.cradio()
        var escape = try Fixture.combo(keymap, named: "escape-combo")
        escape.nodeName = "delete"
        keymap.updateCombo(escape)
        #expect(keymap.comboProblems(positionCount: 34).first?.message.contains("both named") == true)
    }

    @Test("A name devicetree would not accept is rejected")
    func invalidName() throws {
        var keymap = try Fixture.cradio()
        var escape = try Fixture.combo(keymap, named: "escape-combo")
        escape.nodeName = "esc combo!"
        keymap.updateCombo(escape)
        #expect(keymap.comboProblems(positionCount: 34).first?.message.contains("not a valid node name") == true)
        #expect(KeymapCombo.sanitizeNodeName("esc combo!") == "esc-combo")
        #expect(KeymapCombo.isValidNodeName("esc-combo"))
    }

    // MARK: Stability

    @Test("Saving a combo edit twice produces the same bytes")
    func saveIsIdempotent() throws {
        var keymap = try Fixture.cradio()
        var escape = try Fixture.combo(keymap, named: "escape-combo")
        escape.nodeName = "esc"
        escape.keyPositions = [0, 1, 2]
        escape.timeoutMs = 60
        keymap.updateCombo(escape)
        keymap.removeCombo(id: try Fixture.combo(keymap, named: "delete").id)
        keymap.addCombo(KeymapCombo(
            nodeName: "brand-new",
            binding: KeyBinding(behavior: "&kp", params: [BindingParam(value: "F1")]),
            keyPositions: [5, 6]
        ))

        let once = try keymap.serialized(layout: Fixture.cradioLayout())
        let twice = try KeymapFile(source: once).serialized(layout: Fixture.cradioLayout())
        #expect(once == twice)

        let reparsed = try KeymapFile(source: once)
        #expect(reparsed.combos.map(\.nodeName).contains("esc"))
        #expect(!reparsed.combos.map(\.nodeName).contains("delete"))
        #expect(reparsed.combos.last?.nodeName == "brand-new")
    }

    @Test("Editing combos leaves every layer alone")
    func layersAreUntouched() throws {
        let source = try Fixture.cradioText()
        var keymap = try Fixture.cradio()
        var escape = try Fixture.combo(keymap, named: "escape-combo")
        escape.binding = KeyBinding(behavior: "&kp", params: [BindingParam(value: "GRAVE")])
        keymap.updateCombo(escape)
        keymap.addCombo(KeymapCombo(
            nodeName: "new-one",
            binding: KeyBinding(behavior: "&kp", params: [BindingParam(value: "F5")]),
            keyPositions: [7, 8]
        ))

        let output = try Fixture.write(keymap)
        for layer in ["default_layer", "nav", "num", "symbols", "settings_layer"] {
            #expect(try Fixture.bindingLines(of: layer, in: output)
                == (try Fixture.bindingLines(of: layer, in: source)))
        }
    }
}
