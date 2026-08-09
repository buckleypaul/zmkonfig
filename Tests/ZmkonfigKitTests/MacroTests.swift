import Foundation
import Testing

@testable import ZmkonfigKit

@Suite("Macros")
struct MacroTests {
    // MARK: Helpers

    /// Parses one macro node written inside a `macros { }` section.
    private static func node(_ text: String) throws -> DTNode {
        let source = """
            / {
                macros {
            \(text)
                };
            };
            """
        let document = try DTDocument(source: Data(source.utf8))
        return try #require(
            document.allNodes().first { MacroReader.read($0) != nil }, "no macro node parsed"
        )
    }

    private static func read(_ text: String) throws -> KeymapMacro {
        try #require(MacroReader.read(try node(text)), "node was not read as a macro")
    }

    /// Everything about a macro except its identity, which is a fresh UUID on
    /// every read and so can never survive a round trip.
    private static func fields(
        _ macro: KeymapMacro
    ) -> [String] {
        [
            macro.nodeName, macro.label, macro.compatible, String(macro.bindingCells),
            macro.bindings.map(\.text).joined(separator: " "),
            macro.waitMs.map(String.init) ?? "-", macro.tapMs.map(String.init) ?? "-",
        ]
    }

    private static func roundTripped(_ macro: KeymapMacro) throws -> KeymapMacro {
        try read(MacroWriter.node(macro, indent: "        ", propertyIndent: "            "))
    }

    // MARK: Reading

    @Test("A multi-step macro reads as one flat binding sequence")
    func readMultiStep() throws {
        let macro = try Self.read(
            """
                    email: email_macro {
                        compatible = "zmk,behavior-macro";
                        #binding-cells = <0>;
                        wait-ms = <30>;
                        tap-ms = <40>;
                        bindings
                            = <&macro_press &kp LSHFT>
                            , <&kp E &kp X &kp C>
                            , <&macro_release &kp LSHFT>
                            ;
                    };
            """
        )

        #expect(macro.nodeName == "email_macro")
        #expect(macro.label == "email")
        #expect(macro.compatible == MacroKind.plain.compatible)
        #expect(macro.bindingCells == 0)
        #expect(macro.waitMs == 30)
        #expect(macro.tapMs == 40)
        #expect(
            macro.bindings.map(\.text) == [
                "&macro_press", "&kp LSHFT", "&kp E", "&kp X", "&kp C",
                "&macro_release", "&kp LSHFT",
            ]
        )
    }

    @Test("A macro with no wait-ms or tap-ms leaves them to ZMK")
    func readWithoutTimings() throws {
        let macro = try Self.read(
            """
                    hi: hi {
                        compatible = "zmk,behavior-macro";
                        #binding-cells = <0>;
                        bindings = <&kp H &kp I>;
                    };
            """
        )
        #expect(macro.waitMs == nil)
        #expect(macro.tapMs == nil)
        #expect(macro.bindings.count == 2)
    }

    @Test("A node that is not a macro is not this reader's")
    func readNonMacro() throws {
        let source = """
            / {
                behaviors {
                    hml: hold_tap_left {
                        compatible = "zmk,behavior-hold-tap";
                        #binding-cells = <2>;
                        bindings = <&kp>, <&kp>;
                    };
                };
            };
            """
        let document = try DTDocument(source: Data(source.utf8))
        #expect(document.allNodes().allSatisfy { MacroReader.read($0) == nil })
    }

    @Test("A macro missing #binding-cells takes the count its compatible implies")
    func readMissingBindingCells() throws {
        let macro = try Self.read(
            """
                    one: one {
                        compatible = "zmk,behavior-macro-one-param";
                        bindings = <&macro_param_1to1 &kp MACRO_PLACEHOLDER>;
                    };
            """
        )
        #expect(macro.bindingCells == 1)
        #expect(MacroWriter.problems(with: macro).isEmpty)
    }

    @Test("Hex wait-ms and tap-ms read as the numbers they are")
    func readHexTimings() throws {
        let macro = try Self.read(
            """
                    email: email_macro {
                        compatible = "zmk,behavior-macro";
                        #binding-cells = <0>;
                        wait-ms = <0x1e>;
                        tap-ms = <0X28>;
                        bindings = <&kp E>;
                    };
            """
        )
        #expect(macro.waitMs == 30)
        #expect(macro.tapMs == 40)
    }

    // MARK: Round tripping

    @Test("Writing a macro and reading it back gives an equal model")
    func roundTrip() throws {
        let macro = try Self.read(
            """
                    email: email_macro {
                        compatible = "zmk,behavior-macro";
                        #binding-cells = <0>;
                        wait-ms = <30>;
                        tap-ms = <40>;
                        bindings
                            = <&macro_press &kp LSHFT>
                            , <&kp E &kp X &kp C>
                            , <&macro_release &kp LSHFT>
                            ;
                    };
            """
        )
        #expect(Self.fields(try Self.roundTripped(macro)) == Self.fields(macro))
    }

    @Test("A written macro is stable under a second round trip")
    func roundTripStable() throws {
        let macro = KeymapMacro(
            nodeName: "shrug", label: "shrug", compatible: MacroKind.plain.compatible,
            bindingCells: 0,
            bindings: BindingParser.parse("&macro_tap &kp A &kp B &macro_wait_time 50 &kp C"),
            waitMs: 10, tapMs: nil
        )
        let once = MacroWriter.node(macro, indent: "        ", propertyIndent: "            ")
        let twice = MacroWriter.node(
            try Self.read(once), indent: "        ", propertyIndent: "            "
        )
        #expect(once == twice)
    }

    @Test("Parameterised macros of both arities round trip")
    func roundTripParameterised() throws {
        for (kind, sequence) in [
            (MacroKind.oneParam, "&macro_param_1to1 &kp MACRO_PLACEHOLDER"),
            (MacroKind.twoParam, "&macro_param_1to1 &kp MACRO_PLACEHOLDER &macro_param_2to1 &kp MACRO_PLACEHOLDER"),
        ] {
            let macro = KeymapMacro(
                nodeName: "wrap", label: "wrap", compatible: kind.compatible,
                bindingCells: kind.bindingCells, bindings: BindingParser.parse(sequence)
            )
            #expect(MacroWriter.problems(with: macro).isEmpty)
            #expect(Self.fields(try Self.roundTripped(macro)) == Self.fields(macro))
        }
    }

    // MARK: Wrapping

    @Test("A long sequence wraps into groups instead of one enormous line")
    func wrapsLongSequence() throws {
        let macro = KeymapMacro(
            nodeName: "alphabet", label: "alphabet", compatible: MacroKind.plain.compatible,
            bindingCells: 0,
            bindings: BindingParser.parse(
                (0..<26).map { "&kp \(Character(UnicodeScalar(65 + $0)!))" }.joined(separator: " ")
            )
        )
        let text = MacroWriter.node(macro, indent: "", propertyIndent: "    ")
        let bindingLines = text.components(separatedBy: "\n").filter { $0.contains("&kp") }
        #expect(bindingLines.count > 1)
        #expect(bindingLines.allSatisfy { $0.count <= 80 })
        #expect(Self.fields(try Self.roundTripped(macro)) == Self.fields(macro))
    }

    @Test("A short sequence stays on the bindings line")
    func shortSequenceIsOneLine() throws {
        let macro = KeymapMacro(
            nodeName: "hi", label: "hi", compatible: MacroKind.plain.compatible,
            bindingCells: 0, bindings: BindingParser.parse("&kp H &kp I")
        )
        let text = MacroWriter.node(macro, indent: "", propertyIndent: "    ")
        #expect(text.contains("    bindings = <&kp H &kp I>;"))
    }

    @Test("Each step behavior opens a new group")
    func groupsBreakOnSteps() {
        let groups = MacroWriter.groups(
            of: BindingParser.parse("&macro_press &kp LSHFT &kp A &macro_release &kp LSHFT")
        )
        #expect(groups == ["&macro_press &kp LSHFT &kp A", "&macro_release &kp LSHFT"])
    }

    @Test("A macros section frames its nodes without a leading blank line")
    func section() throws {
        let macros = ["hi", "yo"].map {
            KeymapMacro(
                nodeName: $0, label: $0, compatible: MacroKind.plain.compatible,
                bindingCells: 0, bindings: BindingParser.parse("&kp A")
            )
        }
        let text = MacroWriter.section(macros, indent: "    ", separator: "\n\n")
        #expect(text.hasPrefix("    macros {\n        hi: hi {\n"))
        #expect(text.contains("        };\n\n        yo: yo {\n"))
        #expect(text.hasSuffix("        };\n    };"))

        let document = try DTDocument(source: Data("/ {\n\(text)\n};\n".utf8))
        #expect(document.allNodes().compactMap(MacroReader.read).map(\.nodeName) == ["hi", "yo"])
    }

    // MARK: Validation

    @Test("A macro with no label is rejected")
    func problemNoLabel() {
        let macro = KeymapMacro(
            nodeName: "hi", label: "", compatible: MacroKind.plain.compatible,
            bindingCells: 0, bindings: BindingParser.parse("&kp H")
        )
        #expect(MacroWriter.problems(with: macro).contains { $0.contains("no label") })
    }

    @Test("An invalid node name is rejected")
    func problemNodeName() {
        let macro = KeymapMacro(
            nodeName: "my macro!", label: "hi", compatible: MacroKind.plain.compatible,
            bindingCells: 0, bindings: BindingParser.parse("&kp H")
        )
        #expect(MacroWriter.problems(with: macro).contains { $0.contains("valid devicetree node name") })
    }

    @Test("An invalid label is rejected")
    func problemLabel() {
        let macro = KeymapMacro(
            nodeName: "hi", label: "my-macro", compatible: MacroKind.plain.compatible,
            bindingCells: 0, bindings: BindingParser.parse("&kp H")
        )
        #expect(MacroWriter.problems(with: macro).contains { $0.contains("usable label") })
    }

    @Test("A macro label is held to the same rule a behavior label is")
    func problemLabelMatchesBehaviors() {
        func rejected(_ label: String) -> Bool {
            let macro = KeymapMacro(
                nodeName: "hi", label: label, compatible: MacroKind.plain.compatible,
                bindingCells: 0, bindings: BindingParser.parse("&kp H")
            )
            return MacroWriter.problems(with: macro).contains { $0.contains("usable label") }
        }
        // A leading underscore is not a legal node name, so `&_email` is not a
        // reference a behavior label would be allowed to be either.
        #expect(rejected("_email"))
        #expect(!rejected("email_2"))
        for label in ["_email", "email_2", "my-macro", "1email"] {
            #expect(rejected(label) == !KeymapBehavior.isValidLabel(label))
        }
    }

    @Test("A compatible that is not a macro is rejected")
    func problemCompatible() {
        let macro = KeymapMacro(
            nodeName: "hi", label: "hi", compatible: "zmk,behavior-hold-tap",
            bindingCells: 0, bindings: BindingParser.parse("&kp H")
        )
        #expect(MacroWriter.problems(with: macro).contains { $0.contains("is not a macro") })
    }

    @Test("#binding-cells must agree with compatible")
    func problemBindingCells() {
        for kind in MacroKind.allCases {
            let macro = KeymapMacro(
                nodeName: "hi", label: "hi", compatible: kind.compatible,
                bindingCells: kind.bindingCells + 1, bindings: BindingParser.parse("&kp H")
            )
            #expect(MacroWriter.problems(with: macro).contains { $0.contains("`#binding-cells`") })
        }
    }

    @Test("An empty binding sequence is rejected")
    func problemNoBindings() {
        let macro = KeymapMacro(
            nodeName: "hi", label: "hi", compatible: MacroKind.plain.compatible,
            bindingCells: 0, bindings: []
        )
        #expect(MacroWriter.problems(with: macro).contains { $0.contains("no bindings") })
    }

    @Test("A parameter binding in a macro that takes none is rejected")
    func problemParameterInPlainMacro() {
        let macro = KeymapMacro(
            nodeName: "hi", label: "hi", compatible: MacroKind.plain.compatible,
            bindingCells: 0,
            bindings: BindingParser.parse("&macro_param_1to1 &kp MACRO_PLACEHOLDER")
        )
        #expect(MacroWriter.problems(with: macro).contains { $0.contains("takes none") })
    }

    @Test("A second parameter in a one-parameter macro is rejected")
    func problemSecondParameter() {
        let macro = KeymapMacro(
            nodeName: "hi", label: "hi", compatible: MacroKind.oneParam.compatible,
            bindingCells: 1,
            bindings: BindingParser.parse("&macro_param_2to1 &kp MACRO_PLACEHOLDER")
        )
        #expect(MacroWriter.problems(with: macro).contains { $0.contains("takes only 1") })
    }

    @Test("A well-formed macro has no problems")
    func problemsNone() {
        let macro = KeymapMacro(
            nodeName: "email_macro", label: "email", compatible: MacroKind.plain.compatible,
            bindingCells: 0, bindings: BindingParser.parse("&kp E &kp X"), waitMs: 30, tapMs: 40
        )
        #expect(MacroWriter.problems(with: macro).isEmpty)
    }
}
