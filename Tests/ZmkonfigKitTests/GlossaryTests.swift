import Foundation
import Testing

@testable import ZmkonfigKit

@Suite("Glossary")
struct GlossaryTests {
    /// The point of the glossary is that a term the user can meet always has an
    /// explanation behind it. Nothing in the app can tell the difference
    /// between a term nobody wrote up and one that does not exist — both come
    /// back nil and draw nothing — so coverage has to be checked here or not at
    /// all.
    @Test("Every vendored behavior has an entry")
    func behaviorsAreCovered() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        let missing = try ZMKMetadata.loadBehaviors()
            .map(\.code)
            .filter { glossary.entry(for: $0) == nil }
        #expect(missing.isEmpty, "no glossary entry for \(missing.joined(separator: ", "))")
    }

    @Test("Every behavior kind a keymap can define has an entry")
    func kindsAreCovered() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        let missing = BehaviorKind.allCases
            .map(\.glossaryTerm)
            .filter { glossary.entry(for: $0) == nil }
        #expect(missing.isEmpty, "no glossary entry for \(missing.joined(separator: ", "))")
    }

    /// `BehaviorEditorView` offers every property one of the kinds names, and
    /// each of those gets a help badge.
    @Test("Every property the editor offers has an entry")
    func propertiesAreCovered() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        let offered = Set(BehaviorKind.allCases.flatMap { $0.requiredProperties + $0.optionalProperties })
        let missing = offered.filter { glossary.entry(for: $0) == nil }.sorted()
        #expect(missing.isEmpty, "no glossary entry for \(missing.joined(separator: ", "))")
    }

    /// A `flavor` entry with no values leaves the picker with four options and
    /// nothing to say about any of them, which is the exact confusion this is
    /// meant to end.
    @Test("Flavor explains each of the flavors ZMK accepts")
    func flavorValuesAreCovered() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        let explained = glossary.entry(for: "flavor")?.values?.map(\.value) ?? []
        #expect(Set(explained) == Set(BehaviorPropertyShape.flavors))
    }

    /// Every binding slot in the inspector offers a badge for what goes in it,
    /// and a term with no entry behind it draws nothing — a silent gap rather
    /// than a visible one.
    @Test("Every slot kind that names a term has one")
    func slotTermsResolve() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        let missing = ParamKind.allCases
            .compactMap(\.glossaryTerm)
            .filter { glossary.entry(for: $0) == nil }
        #expect(missing.isEmpty, "no glossary entry for \(missing.joined(separator: ", "))")
    }

    /// `&lt` takes a layer and then a keycode, and numbering slots by their
    /// position in the binding called that keycode "Keycode 2" — a second of
    /// something there was only one of.
    @Test("A slot is numbered among its own kind, not by its position")
    func slotTitlesCountTheirOwnKind() {
        #expect(BindingAlgebra.slotTitle(kind: .code, slot: 1, in: [.layer, .code]) == "Keycode")
        #expect(BindingAlgebra.slotTitle(kind: .layer, slot: 0, in: [.layer, .code]) == "Layer")
        #expect(BindingAlgebra.slotTitle(kind: .code, slot: 0, in: [.code, .code]) == "Keycode 1")
        #expect(BindingAlgebra.slotTitle(kind: .code, slot: 1, in: [.code, .code]) == "Keycode 2")
        #expect(BindingAlgebra.slotTitle(kind: .code, slot: 2, in: [.mod, .code, .code]) == "Keycode 2")
    }

    /// The inspector shows this term's summary under the behavior picker, and
    /// a real keymap binds its own behaviors far more often than ZMK's — so
    /// without the fall-through to the kind, the explanation is missing from
    /// exactly the keys people most need it on.
    @Test("A keymap's own behavior is explained by the kind it was defined as")
    func keymapBehaviorsFallBackToTheirKind() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        let keymap = try Fixture.cradio()

        // ZMK's own behavior wins, and is explained as itself.
        #expect(glossary.term(forBehavior: "&kp", in: keymap) == "&kp")
        // The fixture's home-row mods are hold-taps it defines for itself.
        #expect(glossary.term(forBehavior: "&hml", in: keymap) == "hold-tap")
        // With no keymap to consult there is no kind to fall back to.
        #expect(glossary.term(forBehavior: "&hml", in: nil) == nil)
        #expect(glossary.term(forBehavior: "&nonexistent", in: keymap) == nil)
    }

    @Test("The line under the picker prefers a saved note, then the node, then nothing")
    func explanationPrefersTheSavedNote() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        var keymap = try Fixture.cradio()

        // One of ZMK's own: the stored summary, because every `&kp` is alike.
        #expect(glossary.explanation(forBehavior: "&kp", in: keymap)
            == glossary.entry(for: "&kp")?.summary)

        // One of the keymap's own with no note: derived from the node, and
        // distinct from the generic hold-tap summary that used to be shown.
        let derived = try #require(glossary.explanation(forBehavior: "&hml", in: keymap))
        #expect(derived.contains("280 ms"))
        #expect(derived != glossary.summary(for: "hold-tap"))

        // With a note, the note — it is the one thing here that could not have
        // been worked out from the node.
        var hml = try #require(keymap.behaviors.first { $0.label == "hml" })
        hml.note = "Left-hand home-row mod."
        try keymap.upsertBehavior(hml)
        #expect(glossary.explanation(forBehavior: "&hml", in: keymap)
            == "Left-hand home-row mod.")

        // A note that is only whitespace is not a note.
        hml.note = "   "
        try keymap.upsertBehavior(hml)
        #expect(glossary.explanation(forBehavior: "&hml", in: keymap) == derived)

        #expect(glossary.explanation(forBehavior: "&hml", in: nil) == nil)
        #expect(glossary.explanation(forBehavior: "&nonexistent", in: keymap) == nil)
    }

    /// ``BehaviorNarrator`` builds its clauses out of these, and a property
    /// with no clause is silently left out of the description — so a missing
    /// one costs the user a fact rather than showing a gap.
    @Test("Every property carries a clause, or explains one per value")
    func propertiesCarryClauses() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        let missing = glossary.all
            .filter { $0.section == .property }
            .filter { entry in
                entry.clause == nil && entry.values?.allSatisfy { $0.clause != nil } != true
            }
            .map(\.term)
        #expect(missing.isEmpty, "no clause for \(missing.joined(separator: ", "))")
    }

    @Test("A clause that takes a value has somewhere to put it")
    func valueClausesHaveAPlaceholder() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        for entry in glossary.all where entry.section == .property {
            guard let clause = entry.clause else { continue }
            // A flag property is written or absent and has no value to show; a
            // clause for anything else that drops `{value}` silently loses the
            // number the user is reading the line for.
            let isFlag = BehaviorPropertyShape.shape(of: entry.term) == .choiceless
            #expect(
                clause.contains("{value}") != isFlag,
                "\(entry.term): clause and value-ness disagree — \(clause)"
            )
        }
    }

    @Test("Cross-references point at terms that exist")
    func crossReferencesResolve() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        let dangling = glossary.all
            .flatMap { entry in (entry.seeAlso ?? []).map { (entry.term, $0) } }
            .filter { glossary.entry(for: $0.1) == nil }
        #expect(dangling.isEmpty, "dangling: \(dangling.map { "\($0.0) → \($0.1)" }.joined(separator: ", "))")
    }

    @Test("Terms are unique")
    func termsAreUnique() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        #expect(Set(glossary.all.map(\.term)).count == glossary.all.count)
    }

    /// A summary is drawn on its own under a picker, so one that trails off into
    /// its `detail` reads as a truncation. Keeping it to a sentence is the whole
    /// reason the two fields are separate.
    @Test("Summaries are one short sentence and details are longer")
    func prosePassesItsOwnRules() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        for entry in glossary.all {
            #expect(entry.summary.count <= 100, "\(entry.term) summary is too long for a caption")
            #expect(entry.summary.hasSuffix("."), "\(entry.term) summary is not a sentence")
            #expect(entry.detail.count > entry.summary.count, "\(entry.term) detail adds nothing")
        }
    }

    @Test("Sections come back in display order with nothing empty")
    func sectionsAreOrdered() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        let sections = glossary.sections.map(\.section)
        #expect(sections == GlossarySection.allCases)
        #expect(glossary.sections.allSatisfy { !$0.entries.isEmpty })
    }

    @Test("Search narrows to matching entries and finds prose, not just names")
    func searchMatchesProse() throws {
        let glossary = try ZMKMetadata.loadGlossary()
        let hits = glossary.sections(matching: "home-row").flatMap(\.entries)
        #expect(hits.contains { $0.term == "&mt" })
        #expect(glossary.sections(matching: "  ").count == GlossarySection.allCases.count)
        #expect(glossary.sections(matching: "zzzznothing").isEmpty)
    }
}

@Suite("Binding narration")
struct BindingNarratorTests {
    private func narrate(_ binding: KeyBinding, layers: [KeymapLayer] = []) throws -> String? {
        let behaviors = try ZMKMetadata.loadBehaviors()
        return BindingNarrator.sentence(
            for: binding,
            behavior: behaviors.first { $0.code == binding.behavior },
            layers: layers,
            glossary: try ZMKMetadata.loadGlossary()
        )
    }

    @Test("A mod-tap reads as its two halves")
    func modTap() throws {
        let binding = KeyBinding(behavior: "&mt", params: [
            BindingParam(value: "LSHFT"), BindingParam(value: "A"),
        ])
        #expect(try narrate(binding) == "Hold for Left Shift, tap for A.")
    }

    @Test("A layer parameter is said by name")
    func layerName() throws {
        let layers = [
            KeymapLayer(id: 0, nodeName: "default_layer", displayName: "Base", bindings: []),
            KeymapLayer(id: 1, nodeName: "nav_layer", displayName: "Nav", bindings: []),
        ]
        let binding = KeyBinding(behavior: "&mo", params: [BindingParam(value: "1")])
        #expect(try narrate(binding, layers: layers) == "While held, switches to Nav.")
    }

    /// Words rather than the glyphs `BindingLabel` draws — the person reading a
    /// sentence is the one who did not recognise ⌘ on the keycap.
    @Test("Modifier functions are spelled out")
    func modifierFunctions() throws {
        let binding = KeyBinding(behavior: "&kp", params: [
            BindingParam(value: "LG", params: [
                BindingParam(value: "LS", params: [BindingParam(value: "N4")]),
            ]),
        ])
        #expect(try narrate(binding) == "Presses Command + Shift + 4.")
    }

    /// ``BindingNarrator`` reads a modifier's name off ``ModifierFunction``
    /// rather than out of a table of its own, by taking the first two
    /// characters of a spelling as its family — `LGUI` as `LG`. That holds for
    /// every spelling ZMK ships today; this is what fails if a future one
    /// breaks the agreement, rather than the modifier quietly narrating as its
    /// own token.
    @Test("Every modifier spelling resolves to a family and a hand")
    func everyModifierSpellingResolves() throws {
        for token in ModifierFunction.names {
            let resolved = try #require(
                ModifierFunction.family(for: token), "no family for \(token)"
            )
            #expect(resolved.isRight == token.hasPrefix("R"), "\(token) got the wrong hand")
        }
        #expect(ModifierFunction.family(for: "A") == nil)
        #expect(ModifierFunction.family(for: "LEFT") == nil)
    }

    @Test("A behavior taking no parameters still narrates")
    func noParameters() throws {
        #expect(try narrate(KeyBinding(behavior: "&trans")) == "Falls through to the layer underneath.")
    }

    /// A command says what its own documentation says, cut to the first
    /// sentence — the rest is usually a caveat the inspector shows in full.
    @Test("A command is said in its own words")
    func command() throws {
        let binding = KeyBinding(behavior: "&bt", params: [BindingParam(value: "BT_NXT")])
        #expect(try narrate(binding)?.hasPrefix("Bluetooth — Switch to the next profile") == true)
    }

    /// A keymap's own `&hml` has no narration to give, and dressing its
    /// parameters up as prose would be worse than the binding text it replaced.
    @Test("An undocumented behavior narrates as nothing, and falls back to its text")
    func undocumentedBehavior() throws {
        let binding = KeyBinding(behavior: "&hml", params: [
            BindingParam(value: "LGUI"), BindingParam(value: "A"),
        ])
        #expect(try narrate(binding) == nil)
        let described = BindingNarrator.keyDescription(
            for: binding, behavior: nil, layers: [], glossary: try ZMKMetadata.loadGlossary()
        )
        #expect(described == "&hml LGUI A")
    }

    /// A half-filled binding should read as an unfinished sentence rather than
    /// leak the placeholder into the UI.
    @Test("A placeholder with no parameter behind it is dropped")
    func missingParameter() throws {
        let binding = KeyBinding(behavior: "&mt", params: [BindingParam(value: "LSHFT")])
        let sentence = try #require(try narrate(binding))
        #expect(!sentence.contains("{"))
        #expect(sentence.contains("Left Shift"))
    }

    @Test("The keycap description keeps the binding text underneath the sentence")
    func keyDescriptionCarriesBothLines() throws {
        let binding = KeyBinding(behavior: "&kp", params: [BindingParam(value: "SPACE")])
        let behaviors = try ZMKMetadata.loadBehaviors()
        let described = BindingNarrator.keyDescription(
            for: binding,
            behavior: behaviors.first { $0.code == "&kp" },
            layers: [],
            glossary: try ZMKMetadata.loadGlossary()
        )
        #expect(described == "Presses Space.\n&kp SPACE")
    }
}

@Suite("Behavior narration")
struct BehaviorNarratorTests {
    private func describe(_ label: String) throws -> String {
        let keymap = try Fixture.cradio()
        let behavior = try #require(keymap.behaviors.first { $0.label == label })
        return BehaviorNarrator.description(of: behavior, glossary: try ZMKMetadata.loadGlossary())
    }

    /// The whole reason this exists. The fixture defines eight hold-taps, and
    /// the generic glossary line was true of every one of them — which told the
    /// user nothing about the only question they had, namely which of their
    /// eight this key uses and how it differs.
    @Test("Every hold-tap in a real keymap describes itself differently")
    func realKeymapBehaviorsAreDistinct() throws {
        let keymap = try Fixture.cradio()
        let glossary = try ZMKMetadata.loadGlossary()
        let holdTaps = keymap.behaviors.filter { $0.kind == .holdTap }
        #expect(holdTaps.count > 5, "the fixture should have a crowd of hold-taps to tell apart")
        let described = holdTaps.map { BehaviorNarrator.description(of: $0, glossary: glossary) }
        #expect(Set(described).count == described.count, "two hold-taps read identically")
    }

    /// `hml` and `hmr` are the same behavior but for the half they accept a
    /// hold from — the single most important thing to say about either.
    @Test("Per-hand hold-taps differ by their trigger positions")
    func perHandHoldTaps() throws {
        #expect(try describe("hml").contains("only holds for keys at KEYS_RIGHT THUMBS"))
        #expect(try describe("hmr").contains("only holds for keys at KEYS_LEFT THUMBS"))
    }

    @Test("What a behavior wraps is said in words, hold before tap")
    func wrappedBindings() throws {
        #expect(try describe("hold_temp_layer")
            .hasPrefix("Hold-tap: hold for a momentary layer, tap for a toggle layer."))
        #expect(try describe("sticky_tap")
            .hasPrefix("Hold-tap: hold for a momentary layer, tap for a sticky key."))
    }

    /// Source order put `flavor` first in one node and last in another purely
    /// by how the file was typed, which makes two descriptions read side by
    /// side hard to compare.
    @Test("The chosen flavor leads, whatever order the file sets it in")
    func flavorLeadsTheClauses() throws {
        // `ht` writes flavor last in the file, `hml` writes it first.
        for label in ["ht", "hml"] {
            let sentence = try describe(label)
            let clauses = try #require(sentence.split(separator: ".").dropFirst().first)
            #expect(clauses.trimmingCharacters(in: .whitespaces).hasPrefix("Tap-preferred"),
                    "\(label): \(clauses)")
        }
    }

    @Test("A property with no glossary clause is left out, not printed raw")
    func unknownPropertiesAreOmitted() throws {
        let behavior = KeymapBehavior(
            nodeName: "odd", label: "odd", compatible: BehaviorKind.holdTap.compatible,
            bindingCells: 2, bindings: ["&kp", "&kp"],
            properties: [BehaviorProperty(name: "not-a-real-property", value: .integer(7))]
        )
        let sentence = BehaviorNarrator.description(
            of: behavior, glossary: try ZMKMetadata.loadGlossary()
        )
        #expect(sentence == "Hold-tap: hold for a key press, tap for a key press.")
    }

    /// A `compatible` this editor does not model still has a name worth
    /// printing — an empty caption would read as a failure.
    @Test("An unmodelled behavior still says something")
    func unknownKind() throws {
        let behavior = KeymapBehavior(
            nodeName: "future", label: "future", compatible: "zmk,behavior-not-yet",
            bindingCells: 1, bindings: [], properties: []
        )
        let sentence = BehaviorNarrator.description(
            of: behavior, glossary: try ZMKMetadata.loadGlossary()
        )
        #expect(sentence == "zmk,behavior-not-yet.")
    }
}
