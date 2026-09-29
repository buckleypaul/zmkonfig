import Foundation
import Testing

@testable import ZmkonfigKit

/// What a binding *means*: which tokens are modifier wrappers, how a parameter
/// comes apart and goes back together, what a keycap says, and which behaviors
/// a keymap makes bindable.
///
/// All of it used to sit in the app target, where the test target could not
/// reach it — the layer deciding what `&hml LEFT_GUI A` means had no test while
/// the parser next door had sixty.
@Suite("Binding semantics")
struct BindingSemanticsTests {

    // MARK: - Structure versus display

    /// The bug this split exists to prevent: `decompose` used to ask the glyph
    /// table whether a token was a modifier wrapper, so adding a glyph changed
    /// how bindings parse — and therefore how they are recomposed on save.
    @Test("Only the structural table decides what is a modifier wrapper")
    func modifierStructureIsNotTheGlyphTable() {
        // `LEFT_SHIFT` has a glyph and is not a wrapper: it is a keycode you
        // press, not a function you wrap something in.
        #expect(BindingLabel.keycodeSymbols["LEFT_SHIFT"] == "⇧")
        #expect(!ModifierFunction.isModifier("LEFT_SHIFT"))

        let wrapped = BindingParam(value: "LEFT_SHIFT", params: [BindingParam(value: "A")])
        let decomposed = BindingAlgebra.decompose(wrapped)
        #expect(decomposed.mods.isEmpty)
        #expect(decomposed.base == wrapped)

        // Every glyph that is not also a structural modifier is inert to
        // parsing, so a new one cannot change what a keymap means.
        for token in BindingLabel.keycodeSymbols.keys where !ModifierFunction.isModifier(token) {
            let param = BindingParam(value: token, params: [BindingParam(value: "A")])
            #expect(BindingAlgebra.decompose(param).mods.isEmpty, "\(token) parsed as a modifier")
        }
    }

    @Test("Every structural modifier peels off, short and long spellings alike")
    func everyModifierDecomposes() {
        for name in ModifierFunction.names {
            let param = BindingParam(value: name, params: [BindingParam(value: "A")])
            #expect(BindingAlgebra.decompose(param).mods == [name], "\(name) did not peel off")
        }
    }

    /// A wrapper is still a wrapper without a glyph; it just draws as itself.
    @Test("A modifier with no glyph shows its own spelling")
    func glyphFallsBackToTheToken() {
        #expect(ModifierFunction.glyph(for: "LG") == "⌘")
        #expect(ModifierFunction.glyph(for: "RALT") == "⌥")
        #expect(ModifierFunction.glyph(for: "LG_BUT_NEWER") == "LG_BUT_NEWER")
    }

    // MARK: - decompose / compose

    @Test("A parameter comes apart into modifiers and a base, and goes back together")
    func decomposeRoundTrip() {
        let cases: [(param: BindingParam, mods: [String], base: String)] = [
            (BindingParam(value: "A"), [], "A"),
            (BindingParam(value: "LG", params: [BindingParam(value: "A")]), ["LG"], "A"),
            (
                BindingParam(value: "LG", params: [
                    BindingParam(value: "LS", params: [BindingParam(value: "SPACE")])
                ]),
                ["LG", "LS"], "SPACE"
            ),
            (
                BindingParam(value: "LCTL", params: [
                    BindingParam(value: "RALT", params: [BindingParam(value: "N1")])
                ]),
                ["LCTL", "RALT"], "N1"
            ),
        ]
        for (param, mods, base) in cases {
            let decomposed = BindingAlgebra.decompose(param)
            #expect(decomposed.mods == mods, "\(param.text)")
            #expect(decomposed.base == BindingParam(value: base), "\(param.text)")
            #expect(
                BindingAlgebra.compose(mods: decomposed.mods, base: decomposed.base) == param,
                "\(param.text) did not survive the round trip"
            )
        }
    }

    /// `LG(A,B)` is not a modifier wrapping a keycode — a wrapper takes exactly
    /// one thing — and peeling it would throw the second parameter away.
    @Test("A modifier-looking token with two parameters is left whole")
    func twoParametersAreNotAWrapper() {
        let param = BindingParam(value: "LG", params: [
            BindingParam(value: "A"), BindingParam(value: "B"),
        ])
        #expect(BindingAlgebra.decompose(param).base == param)
    }

    @Test("Toggling a family adds the left-hand modifier and removes either hand's")
    func togglingAFamily() throws {
        let shift = try #require(ModifierFunction.families.first { $0.left == "LS" })
        #expect(BindingAlgebra.toggling(shift, in: []) == ["LS"])
        #expect(BindingAlgebra.toggling(shift, in: ["LG"]) == ["LG", "LS"])
        #expect(BindingAlgebra.toggling(shift, in: ["LG", "LS"]) == ["LG"])
        // The right-hand twin is the same family, so the button clears it too
        // rather than stacking a left modifier on top of a right one.
        #expect(BindingAlgebra.toggling(shift, in: ["RS"]) == [])
    }

    // MARK: - Labels

    @Test("A keycode parameter draws as its glyph")
    func keycodeLabels() {
        let cases = [
            ("A", "A"),
            ("N1", "1"),
            ("NUMBER_7", "7"),
            ("LEFT_ARROW", "←"),
            ("C_VOL_UP", "🔊+"),
            ("KP_NUMLOCK", "KP NUMLOCK"),
            ("SOME_UNKNOWN_KEY", "SOME UNKNOWN KEY"),
        ]
        for (raw, expected) in cases {
            #expect(BindingLabel.keycodeLabel(BindingParam(value: raw)) == expected, "\(raw)")
        }
    }

    @Test("A wrapped keycode draws as glyphs then the base")
    func wrappedKeycodeLabel() {
        let param = BindingParam(value: "LG", params: [
            BindingParam(value: "LS", params: [BindingParam(value: "SPACE")])
        ])
        #expect(BindingLabel.keycodeLabel(param) == "⌘⇧␣")
    }

    @Test("A key's label is its tap value, with the hold value above it")
    func keycapLabels() throws {
        let index = try Self.cradioIndex()
        let layers = try Fixture.cradio().layers

        func label(_ text: String) throws -> BindingLabel.Label {
            let binding = try #require(BindingParser.parse(text).first)
            return BindingLabel.make(binding, behavior: index.behavior(for: binding.behavior), layers: layers)
        }

        #expect(try label("&trans").kind == .transparent)
        #expect(try label("&none").kind == .unbound)

        let press = try label("&kp A")
        #expect(press.tap == "A")
        // The behavior name is noise on a plain key press.
        #expect(press.hold == nil)

        let homeRow = try label("&hml LEFT_GUI A")
        #expect(homeRow.tap == "A")
        #expect(homeRow.hold == "⌘")

        let momentary = try label("&mo 1")
        #expect(momentary.tap == layers[1].displayName)
        #expect(momentary.hold == "MO")
    }

    @Test("A chord names its keys off a layer, and keeps the token when it cannot")
    func chordKeyNames() throws {
        let index = try Self.cradioIndex()
        let layers = try Fixture.cradio().layers
        let base = layers.first

        func names(_ tokens: [String]) -> [String] {
            BindingLabel.keyNames(for: tokens, on: base, layers: layers, behaviors: index)
        }

        // A position the base layer binds is named by what it types.
        let first = try #require(base?.bindings.first)
        let firstLabel = BindingLabel.make(first, behavior: index.behavior(for: first.behavior), layers: layers)
        #expect(names(["0"]) == [firstLabel.tap])

        // A macro this editor cannot resolve has no position to name.
        #expect(names(["POS_LH_T1"]) == ["POS_LH_T1"])
        // Nor has a position off the end of the layer.
        #expect(names(["9999"]) == ["9999"])
        // `&trans`/`&none` label as ▽ and ✕, which say less than the number.
        let quiet = KeymapLayer(
            id: 0, nodeName: "quiet", displayName: "Quiet",
            bindings: [KeyBinding(behavior: "&trans", params: []), KeyBinding(behavior: "&none", params: [])]
        )
        #expect(BindingLabel.keyNames(for: ["0", "1"], on: quiet, layers: layers, behaviors: index) == ["0", "1"])
        // No layer at all — an empty keymap — leaves every token alone.
        #expect(BindingLabel.keyNames(for: ["0"], on: nil, layers: [], behaviors: index) == ["0"])
    }

    // MARK: - Which keycap kit a binding belongs to

    @Test("A plain key press of a letter, digit or printable character is an alpha")
    func alphasAreTheKeysThatType() {
        for token in ["A", "Q", "Z", "N1", "N0", "NUMBER_7", "COMMA", "DOT", "FSLH", "SEMI", "SQT", "MINUS", "GRAVE"] {
            let binding = KeyBinding(behavior: "&kp", params: [BindingParam(value: token)])
            #expect(KeycapKit.of(binding) == .alpha, "&kp \(token) should be an alpha")
        }
    }

    @Test("Modifiers, the nav cluster, the editing keys and unknown codes are mods")
    func everythingElseIsAMod() {
        let tokens = [
            "LEFT_SHIFT", "LCTRL", "RIGHT_GUI", "LALT", "CAPS",
            "LEFT", "RIGHT", "UP", "DOWN", "HOME", "END", "PG_UP", "PG_DN",
            "BSPC", "DEL", "RET", "ENTER", "SPACE", "TAB", "ESC",
            "F5", "KP_N1", "C_MUTE", "PSCRN", "SOME_FUTURE_KEYCODE",
        ]
        for token in tokens {
            let binding = KeyBinding(behavior: "&kp", params: [BindingParam(value: token)])
            #expect(KeycapKit.of(binding) == .mods, "&kp \(token) should be a mod")
        }
    }

    /// The rule is about the behavior first: `&mt LSHIFT A` types an `A` but it
    /// is a hold-tap, and a keyset would not put it in the alpha colour.
    @Test("Any behavior that is not a plain key press is a mod")
    func behaviorsOtherThanKeyPressAreMods() {
        let bindings = [
            KeyBinding(behavior: "&mo", params: [BindingParam(value: "1")]),
            KeyBinding(behavior: "&tog", params: [BindingParam(value: "2")]),
            KeyBinding(behavior: "&lt", params: [BindingParam(value: "1"), BindingParam(value: "SPACE")]),
            KeyBinding(behavior: "&mt", params: [BindingParam(value: "LSHIFT"), BindingParam(value: "A")]),
            KeyBinding(behavior: "&hml", params: [BindingParam(value: "LGUI"), BindingParam(value: "A")]),
            KeyBinding(behavior: "&bt", params: [BindingParam(value: "BT_CLR")]),
            KeyBinding(behavior: "&trans"),
            KeyBinding(behavior: "&none"),
            KeyBinding(behavior: "&kp"),
        ]
        for binding in bindings {
            #expect(KeycapKit.of(binding) == .mods, "\(binding.text) should be a mod")
        }
    }

    @Test("A modifier-wrapped keycode is a shortcut, not an alpha")
    func wrappedKeycodesAreMods() {
        let binding = KeyBinding(
            behavior: "&kp",
            params: [BindingParam(value: "LC", params: [BindingParam(value: "C")])]
        )
        #expect(KeycapKit.of(binding) == .mods)
    }

    /// The kit is decided by structure, so a token gaining a glyph must not
    /// move it between the two colours — the same split `ModifierFunction`
    /// keeps between what a binding means and what it says.
    @Test("Every printable-character token this app can draw is an alpha")
    func printableTokensAgreeWithTheirGlyphs() {
        for token in KeycapKit.alphaPunctuation {
            #expect(KeycapKit.of(keycode: token) == .alpha, "\(token) fell out of the alpha kit")
            // Every one of them draws as a single character, which is what
            // "printable" means here.
            let drawn = BindingLabel.prettyKeycode(token)
            #expect(drawn.count == 1, "\(token) draws as \"\(drawn)\", which is not one character")
        }
    }

    // MARK: - Which layer a binding switches to

    @Test("The layer-switching behaviors resolve their first parameter as a layer id")
    func layerTargetResolvesTheFirstParameter() {
        let cases: [(KeyBinding, Int?)] = [
            (KeyBinding(behavior: "&mo", params: [BindingParam(value: "1")]), 1),
            (KeyBinding(behavior: "&tog", params: [BindingParam(value: "2")]), 2),
            (KeyBinding(behavior: "&sl", params: [BindingParam(value: "3")]), 3),
            (KeyBinding(behavior: "&to", params: [BindingParam(value: "0")]), 0),
            // `&lt` takes a layer and then a keycode; only the layer counts.
            (KeyBinding(behavior: "&lt", params: [BindingParam(value: "4"), BindingParam(value: "SPACE")]), 4),
        ]
        for (binding, expected) in cases {
            #expect(KeycapKit.isLayerSwitch(binding), "\(binding.text) should be a layer switch")
            #expect(KeycapKit.layerTarget(of: binding) == expected, "\(binding.text)")
        }
    }

    @Test("A binding that does not switch layers, or names one this editor cannot resolve, targets nothing")
    func layerTargetIsNilOtherwise() {
        let notLayerSwitching = [
            KeyBinding(behavior: "&kp", params: [BindingParam(value: "A")]),
            KeyBinding(behavior: "&mt", params: [BindingParam(value: "LSHIFT"), BindingParam(value: "A")]),
            KeyBinding(behavior: "&trans"),
            KeyBinding(behavior: "&mo"), // declared with no parameter at all
        ]
        for binding in notLayerSwitching {
            #expect(KeycapKit.layerTarget(of: binding) == nil, "\(binding.text)")
        }

        // A layer number never carries parameters of its own, so this is not a
        // switch to layer 1 — it is something the editor does not understand.
        let nested = KeyBinding(
            behavior: "&mo",
            params: [BindingParam(value: "FOO", params: [BindingParam(value: "1")])]
        )
        #expect(KeycapKit.layerTarget(of: nested) == nil)

        // A `#define LAYER_NAV 1` style token this editor cannot resolve.
        let named = KeyBinding(behavior: "&mo", params: [BindingParam(value: "LAYER_NAV")])
        #expect(KeycapKit.isLayerSwitch(named))
        #expect(KeycapKit.layerTarget(of: named) == nil)
    }

    // MARK: - Reshaping a binding

    private static let keyPress = ZMKBehavior(code: "&kp", name: "Key press", params: [.code])
    private static let holdTap = ZMKBehavior(code: "&lt", name: "Layer tap", params: [.layer, .code])
    private static let bluetooth = ZMKBehavior(
        code: "&bt", name: "Bluetooth", params: [.command],
        commands: [ZMKCommand(code: "BT_CLR", description: nil, additionalParams: nil)]
    )

    @Test("Changing the behavior keeps the parameters that still fit")
    func rebuildKeepsWhatFits() {
        let layers = [KeymapLayer(id: 3, nodeName: "base", displayName: "Base", bindings: [])]
        let press = KeyBinding(behavior: "&kp", params: [BindingParam(value: "TAB")])

        // A slot the old binding filled survives; the slot it never had is
        // filled with something valid rather than left empty.
        let layerTap = BindingAlgebra.rebuild(press, as: Self.holdTap, layers: layers)
        #expect(layerTap.text == "&lt TAB A")

        // Fewer slots than before drops the extras rather than smuggling them
        // into a behavior that does not take them.
        #expect(BindingAlgebra.rebuild(layerTap, as: Self.keyPress, layers: layers).text == "&kp TAB")

        // A default layer number is a layer that exists, not 0 on a keymap
        // whose first layer is 3.
        let empty = KeyBinding(behavior: "&none")
        #expect(BindingAlgebra.rebuild(empty, as: Self.holdTap, layers: layers).text == "&lt 3 A")
        #expect(BindingAlgebra.rebuild(empty, as: Self.bluetooth, layers: layers).text == "&bt BT_CLR")
    }

    @Test("A behavior that declares no parameters gets one keycode slot per parameter bound")
    func slotKindsFallBack() {
        let binding = KeyBinding(behavior: "&custom", params: [
            BindingParam(value: "LGUI"), BindingParam(value: "A"),
        ])
        #expect(BindingAlgebra.slotKinds(for: binding, declaring: nil) == [.code, .code])

        let declared = ZMKBehavior(code: "&custom", name: "Custom", params: [])
        #expect(BindingAlgebra.slotKinds(for: binding, declaring: declared) == [.code, .code])

        #expect(
            BindingAlgebra.slotKinds(for: binding, declaring: Self.holdTap) == [.layer, .code]
        )
    }

    // MARK: - The behavior index

    private static func cradioIndex() throws -> BehaviorIndex {
        BehaviorIndex(stock: try ZMKMetadata.loadBehaviors(), keymap: try Fixture.cradio())
    }

    @Test("The keymap's own hold-taps are bindable, with the arity they declare")
    func definedBehaviorsAreIndexed() throws {
        let index = try Self.cradioIndex()

        let hml = try #require(index.behavior(for: "&hml"))
        #expect(hml.name == "hold tap left")
        #expect(hml.params == [.code, .code])
        #expect(!index.isDocumented("&hml"))

        // What each slot means comes from the behaviors the hold-tap wraps:
        // `bindings = <&mo>, <&tog>` is two layer numbers, not two keycodes.
        #expect(index.behavior(for: "&hold_temp_layer")?.params == [.layer, .layer])
        #expect(index.behavior(for: "&sticky_tap")?.params == [.layer, .code])

        // Stock metadata still wins, and is still marked as stock.
        let stockPress = try #require(try ZMKMetadata.loadBehaviors().first { $0.code == "&kp" })
        #expect(index.behavior(for: "&kp") == stockPress)
        #expect(index.isDocumented("&kp"))
    }

    @Test("A behavior nothing defines but something binds is inferred from its use")
    func inferredFromUse() throws {
        let keymap = try KeymapFile(source: Data(Self.macroKeymap.utf8))
        let index = BehaviorIndex(stock: try ZMKMetadata.loadBehaviors(), keymap: keymap)

        // `&mystery` is declared in an include this editor never sees; the only
        // thing known about it is that it is bound with one parameter.
        let mystery = try #require(index.behavior(for: "&mystery"))
        #expect(mystery.params == [.code])
        #expect(!index.isDocumented("&mystery"))
    }

    /// `definedBehaviors` reads `behaviors + macros` rather than re-walking the
    /// tree for `zmk,behavior-` nodes, which is what used to list a macro as if
    /// it were a configurable behavior.
    @Test("Macros are bindable and say they are macros")
    func macrosAreSplitOut() throws {
        let keymap = try KeymapFile(source: Data(Self.macroKeymap.utf8))
        let defined = keymap.definedBehaviors(stock: [:])

        let email = try #require(defined.first { $0.code == "&email" })
        #expect(email.name == "email macro (macro)")
        #expect(email.params == [])

        // A parameterised macro takes its slots from `#binding-cells`, not from
        // the length of the sequence it plays.
        let wrap = try #require(defined.first { $0.code == "&wrap" })
        #expect(wrap.name == "wrap macro (macro)")
        #expect(wrap.params == [.code])

        // The hold-tap is a behavior and is not labelled as a macro.
        #expect(defined.first { $0.code == "&ht" }?.name == "hold tap")
        #expect(defined.count == 3)
    }

    private static let macroKeymap = """
        / {
            behaviors {
                ht: hold_tap {
                    compatible = "zmk,behavior-hold-tap";
                    #binding-cells = <2>;
                    bindings = <&kp>, <&kp>;
                };
            };

            macros {
                email: email_macro {
                    compatible = "zmk,behavior-macro";
                    #binding-cells = <0>;
                    bindings = <&kp E &kp X>;
                };

                wrap: wrap_macro {
                    compatible = "zmk,behavior-macro-one-param";
                    #binding-cells = <1>;
                    bindings = <&macro_param_1to1 &kp MACRO_PLACEHOLDER>;
                };
            };

            keymap {
                compatible = "zmk,keymap";

                base_layer {
                    bindings = <
                        &kp A  &mystery B  &ht LSHFT C  &email
                    >;
                };
            };
        };
        """
}
