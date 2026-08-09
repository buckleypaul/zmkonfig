import Foundation
import Testing

@testable import ZmkonfigKit

@Suite("Behaviors")
struct BehaviorTests {
    // MARK: Helpers

    /// Parses one node out of a fragment and reads it as a behavior.
    private static func behavior(_ source: String) throws -> KeymapBehavior? {
        let document = try DTDocument(source: Data(source.utf8))
        let node = try #require(Self.firstNode(in: document), "no node parsed from the fragment")
        return BehaviorReader.read(node)
    }

    /// The first node with a `compatible`, wherever the fragment nested it.
    private static func firstNode(in document: DTDocument) -> DTNode? {
        func search(_ nodes: [DTNode]) -> DTNode? {
            for node in nodes {
                if node.compatible != nil { return node }
                if let found = search(node.children) { return found }
            }
            return nil
        }
        return search(document.roots)
    }

    private static func wrap(_ node: String) -> String {
        "/ {\n    behaviors {\n\(node)\n    };\n};\n"
    }

    private static let holdTapSource = wrap("""
                hml: hold_tap_left {
                    compatible = "zmk,behavior-hold-tap";
                    flavor = "tap-preferred";
                    tapping-term-ms = <280>;
                    quick-tap-ms = <175>;
                    #binding-cells = <2>;
                    bindings = <&kp>, <&kp>;
                    hold-trigger-key-positions = <KEYS_RIGHT THUMBS>;
                    hold-trigger-on-release;
                };
        """)

    private static func holdTap() -> KeymapBehavior {
        KeymapBehavior(
            nodeName: "hold_tap_left",
            label: "hml",
            compatible: BehaviorKind.holdTap.compatible,
            bindingCells: 2,
            bindings: ["&kp", "&kp"],
            properties: [
                BehaviorProperty(name: "flavor", value: .string("tap-preferred")),
                BehaviorProperty(name: "tapping-term-ms", value: .integer(280)),
            ]
        )
    }

    /// A minimal valid behavior of `kind`: the bindings its YAML type demands,
    /// with parameters only where `phandle-array` allows them, and every
    /// required property present.
    private static func example(_ kind: BehaviorKind) -> KeymapBehavior {
        let bindings: [String]
        switch kind.bindings {
        case .none: bindings = []
        case .phandles(let count): bindings = Array(repeating: "&kp", count: count)
        case .phandleArray(let count): bindings = (0..<(count ?? 3)).map { "&kp N\($0)" }
        }
        return KeymapBehavior(
            nodeName: "node_\(kind.rawValue.lowercased())",
            label: "lbl_\(kind.rawValue.lowercased())",
            compatible: kind.compatible,
            bindingCells: kind.bindingCells,
            bindings: bindings,
            properties: kind.requiredProperties.map {
                BehaviorProperty(name: $0, value: .tokens(["STOCK_VALUE"]))
            }
        )
    }

    /// Compares everything but the id, which is fresh on every read.
    private static func matches(_ first: KeymapBehavior, _ second: KeymapBehavior) -> Bool {
        first.nodeName == second.nodeName && first.label == second.label
            && first.compatible == second.compatible && first.bindingCells == second.bindingCells
            && first.bindings == second.bindings && first.properties == second.properties
    }

    // MARK: Reading

    @Test("A hold-tap reads with its label, cells, bindings and other properties")
    func readHoldTap() throws {
        let behavior = try #require(try Self.behavior(Self.holdTapSource))
        #expect(behavior.nodeName == "hold_tap_left")
        #expect(behavior.label == "hml")
        #expect(behavior.kind == .holdTap)
        #expect(behavior.bindingCells == 2)
        #expect(behavior.bindings == ["&kp", "&kp"])
        #expect(behavior.properties.map(\.name) == [
            "flavor", "tapping-term-ms", "quick-tap-ms",
            "hold-trigger-key-positions", "hold-trigger-on-release",
        ])
        #expect(behavior.properties[0].value == .string("tap-preferred"))
        #expect(behavior.properties[1].value == .integer(280))
        #expect(behavior.properties[3].value == .tokens(["KEYS_RIGHT", "THUMBS"]))
        #expect(behavior.properties[4].value == .flag)
    }

    @Test("Every hold-tap in the real keymap reads")
    func readFixtureHoldTaps() throws {
        let document = try Fixture.cradioDocument()
        var read: [String] = []
        func visit(_ nodes: [DTNode]) {
            for node in nodes {
                if let behavior = BehaviorReader.read(node) { read.append(behavior.label) }
                visit(node.children)
            }
        }
        visit(document.roots)
        #expect(read == [
            "rpi", "hml", "hmr", "qt", "ht", "hold_temp_layer", "ht_pref_hold", "sticky_tap",
        ])
    }

    @Test("A tap dance reads with a free-length bindings list")
    func readTapDance() throws {
        let behavior = try #require(try Self.behavior(Self.wrap("""
                    td: tap_dance_layer {
                        compatible = "zmk,behavior-tap-dance";
                        #binding-cells = <0>;
                        tapping-term-ms = <200>;
                        bindings = <&mo 1>, <&to 1>, <&to 0>;
                    };
            """)))
        #expect(behavior.kind == .tapDance)
        #expect(behavior.bindings == ["&mo 1", "&to 1", "&to 0"])
        #expect(behavior.kind?.bindings == .phandleArray(count: nil))
        #expect(BehaviorWriter.problems(with: behavior).isEmpty)
    }

    @Test("A mod-morph reads its parameterised bindings and mods mask")
    func readModMorph() throws {
        let behavior = try #require(try Self.behavior(Self.wrap("""
                    bspc_del: backspace_delete {
                        compatible = "zmk,behavior-mod-morph";
                        #binding-cells = <0>;
                        bindings = <&kp BACKSPACE>, <&kp DELETE>;
                        mods = <(MOD_LSFT|MOD_RSFT)>;
                    };
            """)))
        #expect(behavior.kind == .modMorph)
        #expect(behavior.bindings == ["&kp BACKSPACE", "&kp DELETE"])
        #expect(behavior.properties == [
            BehaviorProperty(name: "mods", value: .tokens(["(MOD_LSFT|MOD_RSFT)"]))
        ])
    }

    @Test("A sticky key reads with one binding and one cell")
    func readStickyKey() throws {
        let behavior = try #require(try Self.behavior(Self.wrap("""
                    sk_long: sticky_key_long {
                        compatible = "zmk,behavior-sticky-key";
                        #binding-cells = <1>;
                        bindings = <&kp>;
                        release-after-ms = <2000>;
                        quick-release;
                    };
            """)))
        #expect(behavior.kind == .stickyKey)
        #expect(behavior.bindingCells == 1)
        #expect(behavior.bindings == ["&kp"])
        #expect(BehaviorWriter.problems(with: behavior).isEmpty)
    }

    @Test("Caps word and key repeat read, bindings or not")
    func readZeroAndOneBindingKinds() throws {
        let capsWord = try #require(try Self.behavior(Self.wrap("""
                    cw: caps_word_custom {
                        compatible = "zmk,behavior-caps-word";
                        #binding-cells = <0>;
                        continue-list = <UNDERSCORE MINUS>;
                    };
            """)))
        #expect(capsWord.kind == .capsWord)
        #expect(capsWord.bindings.isEmpty)
        #expect(BehaviorWriter.problems(with: capsWord).isEmpty)

        let keyRepeat = try #require(try Self.behavior(Self.wrap("""
                    kr: key_repeat_custom {
                        compatible = "zmk,behavior-key-repeat";
                        #binding-cells = <0>;
                        usage-pages = <HID_USAGE_KEY>;
                    };
            """)))
        #expect(keyRepeat.kind == .keyRepeat)
        #expect(keyRepeat.bindings.isEmpty)
        #expect(BehaviorWriter.problems(with: keyRepeat).isEmpty)
    }

    @Test("A `#binding-cells` the node omits falls back to what the kind takes")
    func readMissingBindingCells() throws {
        let behavior = try #require(try Self.behavior(Self.wrap("""
                    ht: hold_tap {
                        compatible = "zmk,behavior-hold-tap";
                        bindings = <&kp>, <&kp>;
                    };
            """)))
        #expect(behavior.bindingCells == 2)
    }

    // MARK: Not mine

    @Test("A node that is not a behavior reads as nil")
    func readNonBehavior() throws {
        #expect(try Self.behavior("""
            / {
                combos {
                    compatible = "zmk,combos";
                };
            };
            """) == nil)
    }

    @Test("A macro belongs to the macro reader, not this one")
    func readMacroIsNotMine() throws {
        #expect(try Self.behavior(Self.wrap("""
                    hello: hello_macro {
                        compatible = "zmk,behavior-macro";
                        #binding-cells = <0>;
                        bindings = <&kp H &kp I>;
                    };
            """)) == nil)
    }

    @Test("A value this editor could not write back declines the whole node")
    func readUnsupportedValue() throws {
        #expect(try Self.behavior(Self.wrap("""
                    weird: weird_behavior {
                        compatible = "zmk,behavior-hold-tap";
                        #binding-cells = <2>;
                        bindings = <&kp>, <&kp>;
                        delegate = &other;
                    };
            """)) == nil)
    }

    // MARK: Writing

    @Test("A written node puts compatible, cells and bindings first")
    func writeNode() {
        let text = BehaviorWriter.node(Self.holdTap(), indent: "    ", propertyIndent: "        ")
        #expect(text == """
                hml: hold_tap_left {
                    compatible = "zmk,behavior-hold-tap";
                    #binding-cells = <2>;
                    bindings = <&kp>, <&kp>;
                    flavor = "tap-preferred";
                    tapping-term-ms = <280>;
                };
            """)
    }

    @Test("A section frames its nodes without a compatible of its own")
    func writeSection() {
        let text = BehaviorWriter.section([Self.holdTap()], indent: "    ", separator: "\n\n")
        #expect(text == """
                behaviors {
                    hml: hold_tap_left {
                        compatible = "zmk,behavior-hold-tap";
                        #binding-cells = <2>;
                        bindings = <&kp>, <&kp>;
                        flavor = "tap-preferred";
                        tapping-term-ms = <280>;
                    };
                };
            """)
    }

    @Test("Every value shape renders the way devicetree writes it")
    func writeLines() {
        #expect(BehaviorWriter.line("tapping-term-ms", .integer(280)) == "tapping-term-ms = <280>;")
        #expect(BehaviorWriter.line("flavor", .string("balanced")) == "flavor = \"balanced\";")
        #expect(
            BehaviorWriter.line("hold-trigger-key-positions", .integers([0, 1, 2]))
                == "hold-trigger-key-positions = <0 1 2>;"
        )
        #expect(
            BehaviorWriter.line("hold-trigger-key-positions", .tokens(["KEYS_RIGHT", "THUMBS"]))
                == "hold-trigger-key-positions = <KEYS_RIGHT THUMBS>;"
        )
        #expect(
            BehaviorWriter.line("bindings", .references(["&kp BACKSPACE", "&kp DELETE"]))
                == "bindings = <&kp BACKSPACE>, <&kp DELETE>;"
        )
        #expect(BehaviorWriter.line("hold-trigger-on-release", .flag) == "hold-trigger-on-release;")
    }

    @Test("A binding written without its `&` still writes as a phandle")
    func writeBareReference() {
        #expect(BehaviorWriter.line("bindings", .references(["kp"])) == "bindings = <&kp>;")
    }

    @Test("An emptied bindings list asks to be deleted rather than written as `<>`")
    func writeEmptyBindings() {
        var behavior = Self.holdTap()
        behavior.bindings = []
        #expect(!BehaviorWriter.properties(of: behavior).contains { $0.name == "bindings" })
    }

    // MARK: Round trips

    @Test("A hold-tap written and reparsed is the same model")
    func roundTripHoldTap() throws {
        let original = try #require(try Self.behavior(Self.holdTapSource))
        let text = BehaviorWriter.node(original, indent: "        ", propertyIndent: "            ")
        let reparsed = try #require(try Self.behavior("/ {\n    behaviors {\n\(text)\n    };\n};\n"))
        #expect(Self.matches(original, reparsed))
    }

    @Test("Writing a reparsed hold-tap reproduces the same text")
    func roundTripHoldTapIsStable() throws {
        let original = try #require(try Self.behavior(Self.holdTapSource))
        let once = BehaviorWriter.node(original, indent: "  ", propertyIndent: "    ")
        let reparsed = try #require(try Self.behavior("/ {\n behaviors {\n\(once)\n };\n};\n"))
        #expect(BehaviorWriter.node(reparsed, indent: "  ", propertyIndent: "    ") == once)
    }

    @Test("Every kind round-trips through the shape upstream demands of it")
    func roundTripEveryKind() throws {
        for kind in BehaviorKind.allCases where kind != .macroBehavior {
            let behavior = Self.example(kind)
            #expect(BehaviorWriter.problems(with: behavior).isEmpty, "\(kind) should be writable")
            let text = BehaviorWriter.node(behavior, indent: "    ", propertyIndent: "        ")
            let reparsed = try #require(
                try Self.behavior("/ {\n behaviors {\n\(text)\n };\n};\n"), "\(kind) did not reparse"
            )
            #expect(Self.matches(behavior, reparsed), "\(kind) changed across a round trip")
        }
    }

    // MARK: Validation

    @Test("A behavior with no label cannot be referenced, so it is refused")
    func problemMissingLabel() {
        var behavior = Self.holdTap()
        behavior.label = ""
        let problems = BehaviorWriter.problems(with: behavior)
        #expect(problems.count == 1)
        #expect(problems[0].contains("has no label"))
    }

    @Test("A label with characters `&` cannot name is refused")
    func problemInvalidLabel() {
        var behavior = Self.holdTap()
        behavior.label = "hm-l"
        let problems = BehaviorWriter.problems(with: behavior)
        #expect(problems.count == 1)
        #expect(problems[0].contains("`hm-l` is not a valid label"))
        #expect(!KeymapBehavior.isValidLabel("hm-l"))
        #expect(KeymapBehavior.isValidLabel("hml_2"))
    }

    @Test("An invalid node name is refused")
    func problemInvalidNodeName() {
        var behavior = Self.holdTap()
        behavior.nodeName = "hold tap!"
        let problems = BehaviorWriter.problems(with: behavior)
        #expect(problems.count == 1)
        #expect(problems[0].contains("not a valid devicetree node name"))
        #expect(KeymapCombo.sanitizeNodeName("hold tap!") == "hold-tap")
    }

    @Test("`#binding-cells` outside 0–2 is refused")
    func problemBindingCells() {
        var behavior = Self.holdTap()
        behavior.bindingCells = 3
        #expect(BehaviorWriter.problems(with: behavior).contains { $0.contains("takes 0, 1 or 2") })
        behavior.bindingCells = -1
        #expect(BehaviorWriter.problems(with: behavior).contains { $0.contains("takes 0, 1 or 2") })
    }

    @Test("A `#binding-cells` that disagrees with the kind is refused")
    func problemBindingCellsConst() {
        var behavior = Self.holdTap()
        behavior.bindingCells = 1
        let problems = BehaviorWriter.problems(with: behavior)
        #expect(problems.count == 1)
        #expect(problems[0].contains("`#binding-cells = <2>`"))
        #expect(problems[0].contains("which ZMK fixes"))
    }

    @Test("A bindings count that contradicts the compatible is refused")
    func problemBindingCount() {
        var behavior = Self.holdTap()
        behavior.bindings = ["&kp"]
        let problems = BehaviorWriter.problems(with: behavior)
        #expect(problems.count == 1)
        #expect(problems[0].contains("needs exactly 2 bindings"))
        #expect(problems[0].contains("has 1"))
    }

    @Test("A free-length kind is not held to a bindings count")
    func problemFreeBindingCount() {
        var behavior = Self.holdTap()
        behavior.compatible = BehaviorKind.tapDance.compatible
        behavior.bindingCells = BehaviorKind.tapDance.bindingCells
        behavior.bindings = ["&mo 1", "&to 1", "&to 0"]
        #expect(BehaviorWriter.problems(with: behavior).isEmpty)
    }

    @Test("A parameter on a `phandles` kind's binding is refused")
    func problemParameterisedPhandle() {
        var behavior = Self.holdTap()
        behavior.bindings = ["&kp A", "&kp B"]
        let problems = BehaviorWriter.problems(with: behavior)
        #expect(problems.count == 2)
        #expect(problems[0].contains("bare behavior references"))
        #expect(problems[0].contains("`&kp A`"))
        #expect(problems[0].contains("`&hml LSHFT A`"))
    }

    @Test("A `phandle-array` kind keeps its parameters")
    func phandleArrayAllowsParameters() {
        let modMorph = Self.example(.modMorph)
        #expect(modMorph.bindings == ["&kp N0", "&kp N1"])
        #expect(BehaviorWriter.problems(with: modMorph).isEmpty)
    }

    @Test("A `bindings` on a kind that declares none is refused")
    func problemBindingsOnKindWithNone() {
        for kind in [BehaviorKind.capsWord, .keyRepeat] {
            var behavior = Self.example(kind)
            behavior.bindings = ["&kp"]
            let problems = BehaviorWriter.problems(with: behavior)
            #expect(problems.count == 1, "\(kind)")
            #expect(problems.first?.contains("has no `bindings` property at all") == true, "\(kind)")
        }
    }

    @Test("A kind with no `bindings` never writes the property")
    func kindsWithNoBindingsWriteNone() {
        for kind in [BehaviorKind.capsWord, .keyRepeat] {
            let names = BehaviorWriter.properties(of: Self.example(kind)).map(\.name)
            #expect(!names.contains("bindings"), "\(kind) should not write bindings")
            #expect(names.contains(kind.requiredProperties[0]), "\(kind) should write its required property")
        }
    }

    @Test("A missing required property is refused, per kind")
    func problemMissingRequiredProperty() {
        let expected: [BehaviorKind: String] = [
            .modMorph: "mods",
            .stickyKey: "release-after-ms",
            .capsWord: "continue-list",
            .keyRepeat: "usage-pages",
        ]
        for (kind, property) in expected {
            #expect(kind.requiredProperties == [property])
            var behavior = Self.example(kind)
            behavior.properties = []
            let problems = BehaviorWriter.problems(with: behavior)
            #expect(problems.count == 1, "\(kind)")
            #expect(problems.first?.contains("needs `\(property)`") == true, "\(kind)")
        }
        #expect(BehaviorKind.holdTap.requiredProperties.isEmpty)
        #expect(BehaviorKind.tapDance.requiredProperties.isEmpty)
    }

    @Test("An unwritable property value is refused")
    func problemUnparseableValue() {
        var behavior = Self.holdTap()
        behavior.properties = [
            BehaviorProperty(name: "hold-trigger-key-positions", value: .integers([])),
            BehaviorProperty(name: "flavor", value: .string("bal\"anced")),
            BehaviorProperty(name: "mods", value: .tokens(["MOD_LSFT>;"])),
            BehaviorProperty(name: "", value: .flag),
        ]
        let problems = BehaviorWriter.problems(with: behavior)
        #expect(problems.count == 4)
        #expect(problems.contains { $0.contains("would write as `<>`") })
        #expect(problems.contains { $0.contains("has a quote in its value") })
        #expect(problems.contains { $0.contains("`MOD_LSFT>;`") })
        #expect(problems.contains { $0.contains("has no name") })
    }

    @Test("An empty binding entry is refused")
    func problemEmptyBinding() {
        var behavior = Self.holdTap()
        behavior.bindings = ["&kp", "  "]
        #expect(BehaviorWriter.problems(with: behavior).contains { $0.contains("Binding 2") })
    }

    @Test("A behavior read out of the real keymap has no problems")
    func fixtureBehaviorsAreValid() throws {
        let behavior = try #require(try Self.behavior(Self.holdTapSource))
        #expect(BehaviorWriter.problems(with: behavior).isEmpty)
    }

    // MARK: The kind table

    @Test("The kind table matches upstream's YAML bindings")
    func kindTable() {
        let compatibles = BehaviorKind.allCases.map(\.compatible)
        #expect(Set(compatibles).count == compatibles.count)
        #expect(compatibles.allSatisfy { $0.hasPrefix("zmk,behavior-") })

        #expect(BehaviorKind.holdTap.bindings == .phandles(count: 2))
        #expect(BehaviorKind.stickyKey.bindings == .phandles(count: 1))
        #expect(BehaviorKind.modMorph.bindings == .phandleArray(count: 2))
        #expect(BehaviorKind.tapDance.bindings == .phandleArray(count: nil))
        #expect(BehaviorKind.macroBehavior.bindings == .phandleArray(count: nil))
        #expect(BehaviorKind.capsWord.bindings == BehaviorBindings.none)
        #expect(BehaviorKind.keyRepeat.bindings == BehaviorBindings.none)

        #expect(!BehaviorKind.holdTap.bindings.allowsParameters)
        #expect(BehaviorKind.modMorph.bindings.allowsParameters)
        #expect(!BehaviorKind.keyRepeat.bindings.isWritten)

        #expect(BehaviorKind.allCases.map(\.bindingCells) == [2, 0, 0, 1, 0, 0, 0])

        // Deprecated upstream: never offered.
        for kind in BehaviorKind.allCases {
            let offered = Set(kind.requiredProperties + kind.optionalProperties)
            #expect(offered.isDisjoint(with: [
                "tapping_term_ms", "quick_tap_ms", "global-quick-tap", "label",
            ]), "\(kind) offers a deprecated property")
        }

        for kind in BehaviorKind.allCases {
            #expect(BehaviorKind.kind(forCompatible: kind.compatible) == kind)
        }
        #expect(BehaviorKind.kind(forCompatible: "zmk,behavior-not-a-thing") == nil)
    }
}
