import Foundation
import Testing

@testable import ZmkonfigKit

/// `AssistantTools.usage(of:in:)` is the sentence the model reads before it
/// stages a removal, so what it misses it acts on. It used to walk layers and
/// combos only: a hold-tap wrapping the thing being removed, or a macro playing
/// it, was reported as nothing binding it at all.
@Suite("Assistant usage of a behavior")
struct AssistantUsageTests {
    /// A snapshot around a keymap and nothing else — no layout, no keycodes.
    /// `usage` reads only `layers`, `combos`, `behaviors` and `macros`.
    private static func context(_ source: String) throws -> KeymapContext {
        KeymapContext(keymap: try KeymapFile(source: Data(source.utf8)))
    }

    private static func usage(of behavior: String, in source: String) throws -> String {
        AssistantTools.usage(of: behavior, in: try context(source))
    }

    // MARK: - One kind of site at a time

    @Test("A behavior bound only from another behavior's bindings is reported, by name")
    func fromAnotherBehavior() throws {
        let note = try Self.usage(of: "&sk_shift", in: Self.wrapping)
        #expect(note.contains("the `bindings` of the behavior `&sticky_tap`"))
        #expect(!note.contains("No layer"))
        // The layer binds `&sticky_tap`, not `&sk_shift`, so no layer is named.
        #expect(!note.contains("layer 0"))
    }

    @Test("A phandle-list property of another behavior counts, and names the property")
    func fromABehaviorProperty() throws {
        let note = try Self.usage(of: "&inner", in: Self.wrapping)
        #expect(note.contains("`sensor-bindings` on the behavior `&sticky_tap`"))
    }

    @Test("A behavior played only from a macro's sequence is reported, by macro and step count")
    func fromAMacro() throws {
        let note = try Self.usage(of: "&ht", in: Self.wrapping)
        #expect(note.contains("the sequence of the macro `&email` (2 steps)"))
        #expect(!note.contains("No layer"))
    }

    @Test("One step reads as one step")
    func singularStep() throws {
        let note = try Self.usage(of: "&sk_shift", in: Self.wrapping)
        #expect(note.contains("the sequence of the macro `&wrap` (1 step)"))
    }

    @Test("A behavior nothing refers to says so, and says what was not checked")
    func fromNowhere() throws {
        let note = AssistantTools.usage(of: "&qt", in: try AssistantUsageTests.cradioContext())
        #expect(note.hasPrefix("No layer, combo, other behavior or macro refers to it."))
        // The honesty about scope has to survive: the sentence still says where
        // it did not look rather than declaring `&qt` unused.
        #expect(note.contains("does not model"))
        #expect(note.contains("node override"))
        #expect(note.contains("`#define`"))
    }

    /// The real fixture defines `sticky_tap: bindings = <&mo>, <&sk>;` and binds
    /// `&sk` nowhere else — exactly the case the old sentence got wrong.
    @Test("In the real keymap, a behavior only a hold-tap wraps is no longer called unused")
    func cradioHoldTapWrapper() throws {
        let note = AssistantTools.usage(of: "&sk", in: try AssistantUsageTests.cradioContext())
        #expect(note.contains("the `bindings` of the behavior `&sticky_tap`"))
        #expect(!note.contains("No layer"))
    }

    // MARK: - Several kinds at once

    @Test("Every kind of site is listed when a behavior is referred to from all of them")
    func everyKindAtOnce() throws {
        let note = try Self.usage(of: "&kp", in: Self.wrapping)
        for site in [
            "layer 0 keys 0, 2",
            "combo `combo-kp`",
            "the `bindings` of the behavior `&sk_shift`",
            "the `bindings` of the behavior `&inner`",
            "the `bindings` of the behavior `&ht`",
            "the sequence of the macro `&email` (1 step)",
        ] {
            #expect(note.contains(site), "\(note) does not mention \(site)")
        }
        #expect(note.contains("will not build once it is gone"))
    }

    @Test("A behavior is not reported as referring to itself")
    func noSelfReference() throws {
        // `ht` binds `&kp`, not `&ht`; naming `&ht` in its own removal note
        // would be noise about a node that is going away.
        let note = try Self.usage(of: "&ht", in: Self.wrapping)
        #expect(!note.contains("behavior `&ht`"))
    }

    // MARK: - Through the tool

    @Test("remove_behavior carries the wider check into what the model is told")
    func throughRemoveBehavior() throws {
        let outcome = AssistantTools.run(
            ClaudeToolUse(
                id: "toolu_test",
                name: AssistantTools.Name.removeBehavior,
                input: .object(["label": .string("sk_shift")])
            ),
            context: try Self.context(Self.wrapping),
            staged: []
        )
        #expect(!outcome.result.isError)
        #expect(outcome.result.content.contains("the `bindings` of the behavior `&sticky_tap`"))
    }

    @Test("remove_macro reports the macro's own uses too")
    func throughRemoveMacro() throws {
        let outcome = AssistantTools.run(
            ClaudeToolUse(
                id: "toolu_test",
                name: AssistantTools.Name.removeMacro,
                input: .object(["label": .string("email")])
            ),
            context: try Self.context(Self.wrapping),
            staged: []
        )
        #expect(!outcome.result.isError)
        #expect(outcome.result.content.contains("layer 0 key 3"))
    }

    // MARK: - The structured walk

    /// `AppModel` used to walk the keymap a second time for its delete
    /// confirmation, and that copy never looked at a behavior's phandle-list
    /// properties — so a `sensor-bindings` still pointing at a behavior showed
    /// as nothing referring to it, and the user deleted on that assurance.
    /// Both readers now come through here.
    @Test("A phandle-list property is a site in the structured walk, named as data")
    func propertySiteIsStructured() throws {
        let sites = AssistantTools.references(to: "&inner", in: try Self.context(Self.wrapping))
        #expect(sites.contains { $0.site == .behaviorProperty(label: "sticky_tap", property: "sensor-bindings") })
    }

    @Test("A layer site carries its key positions as numbers, not only as prose")
    func layerSiteCarriesKeys() throws {
        let sites = AssistantTools.references(to: "&kp", in: try Self.context(Self.wrapping))
        #expect(sites.contains { $0.site == .layer(id: 0, keys: [0, 2]) })
    }

    @Test("A macro site carries its step count as a number")
    func macroSiteCarriesSteps() throws {
        let sites = AssistantTools.references(to: "&ht", in: try Self.context(Self.wrapping))
        #expect(sites.contains { $0.site == .macroSequence(label: "email", steps: 2) })
    }

    @Test("A combo site carries its node name")
    func comboSiteCarriesName() throws {
        let sites = AssistantTools.references(to: "&kp", in: try Self.context(Self.wrapping))
        #expect(sites.contains { $0.site == .combo(nodeName: "combo-kp") })
    }

    @Test("Nothing referring to it is an empty list, not a sentence")
    func noSitesIsEmpty() throws {
        #expect(AssistantTools.references(to: "&qt", in: try Self.cradioContext()).isEmpty)
    }

    /// The two must not drift apart: if `usage` ever grows a traversal of its
    /// own again, its sentence will stop being exactly these descriptions.
    @Test("The sentence is rendered from the walk rather than from a second one")
    func proseIsRenderedFromTheWalk() throws {
        let context = try Self.context(Self.wrapping)
        let sites = AssistantTools.references(to: "&kp", in: context)
        let note = AssistantTools.usage(of: "&kp", in: context)
        #expect(!sites.isEmpty)
        #expect(note.contains(sites.map(\.description).joined(separator: "; ")))
    }

    @Test("A bare label and a `&`-prefixed one find the same sites")
    func labelFormsAgree() throws {
        let context = try Self.context(Self.wrapping)
        #expect(
            AssistantTools.references(to: "kp", in: context)
                == AssistantTools.references(to: "&kp", in: context)
        )
    }

    @Test("A reference carrying parameters is matched on its behavior, not its text")
    func matchingGoesThroughTheParser() throws {
        // `sticky_tap` wraps `<&sk_shift LSHFT>`, so a walker comparing strings
        // to `&sk_shift` finds nothing.
        let sites = AssistantTools.references(to: "&sk_shift", in: try Self.context(Self.wrapping))
        #expect(sites.contains { $0.site == .behaviorBindings(label: "sticky_tap") })
    }

    // MARK: - Fixtures

    private static func cradioContext() throws -> KeymapContext {
        KeymapContext(keymap: try Fixture.cradio())
    }

    /// A keymap where each kind of reference site exists on its own:
    /// `&sk_shift` only inside another behavior and a macro, `&inner` only in a
    /// phandle-list property, `&ht` only in a macro's sequence, and `&kp`
    /// everywhere at once.
    private static let wrapping = """
        / {
            behaviors {
                sk_shift: sk_shift {
                    compatible = "zmk,behavior-sticky-key";
                    #binding-cells = <1>;
                    bindings = <&kp>;
                };

                inner: inner_tap {
                    compatible = "zmk,behavior-hold-tap";
                    #binding-cells = <2>;
                    bindings = <&kp>, <&kp>;
                };

                sticky_tap: sticky_tap {
                    compatible = "zmk,behavior-hold-tap";
                    #binding-cells = <2>;
                    bindings = <&mo>, <&sk_shift LSHFT>;
                    sensor-bindings = <&inner>;
                };

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
                    bindings = <&ht LSHFT E &kp X &ht LCTRL Y>;
                };

                wrap: wrap_macro {
                    compatible = "zmk,behavior-macro-one-param";
                    #binding-cells = <1>;
                    bindings = <&sk_shift LSHFT>;
                };
            };

            keymap {
                compatible = "zmk,keymap";

                base_layer {
                    bindings = <
                        &kp A  &sticky_tap 1 2  &kp B  &email
                    >;
                };
            };

            combos {
                compatible = "zmk,combos";

                combo-kp {
                    timeout-ms = <50>;
                    key-positions = <0 1>;
                    bindings = <&kp ESC>;
                };
            };
        };
        """
}
