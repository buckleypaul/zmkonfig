import Foundation

/// Which list an entry belongs to. Declaration order is display order.
///
/// An unknown string fails to decode rather than falling into a catch-all, for
/// the same reason ``ParamKind`` does: the file is vendored and
/// version-controlled, so a new section only appears when someone edits it, and
/// a loud failure then beats an entry that silently files itself nowhere.
public enum GlossarySection: String, Codable, Sendable, CaseIterable {
    case behavior, kind, property, concept

    /// The heading this section is listed under.
    public var title: String {
        switch self {
        case .behavior: "Behaviors"
        case .kind: "Behavior kinds"
        case .property: "Properties"
        case .concept: "Concepts"
        }
    }
}

/// One explained term — a behavior, a kind of behavior a keymap can define, a
/// property one of those kinds sets, or a word this editor's own vocabulary
/// rests on.
///
/// The vendored `zmk-behaviors.json` gives `&kp` the name "Key Press" and stops
/// there, which is no help at all to someone who does not already know what a
/// key press behavior is. This is where the prose lives.
public struct GlossaryEntry: Codable, Equatable, Sendable, Identifiable {
    /// How the term is written wherever the user meets it: `&kp`, `hold-tap`,
    /// `flavor`, `combo`. A behavior keeps its `&` because that is what a
    /// binding spells, and so what a caller has in hand to look it up by.
    public var term: String
    public var title: String
    /// One line, and a whole thought — this is what goes under a picker on its
    /// own, so it cannot be the opening clause of ``detail``.
    public var summary: String
    public var detail: String
    public var section: GlossarySection
    /// This property as a phrase for a list, `{value}` standing in for what the
    /// node sets it to: "holds after 280 ms".
    ///
    /// Separate from ``summary`` because they are different jobs. A summary is
    /// a standalone sentence about the property in general; a clause has to
    /// read as one item among six describing *one* behavior, which is where
    /// ``BehaviorNarrator`` uses it. Only `property` entries carry one.
    public var clause: String?
    public var example: Example?
    /// The values a property accepts, each glossed. A `flavor` picker can then
    /// explain the option being chosen rather than send the user elsewhere.
    public var values: [Value]?
    /// How ``BindingNarrator`` says a binding of this behavior out loud, with
    /// `{0}`, `{1}` … standing in for the rendered parameters. Nil for terms
    /// that are not behaviors.
    public var narration: String?
    /// The upstream page, for when this entry is not enough.
    public var documentation: String?
    /// Terms worth reading next, by ``term``.
    public var seeAlso: [String]?

    public var id: String { term }

    public struct Example: Codable, Equatable, Sendable {
        /// A binding as it would be written, `&mt LSHFT A`.
        public var binding: String
        /// What that one does, in words.
        public var meaning: String
    }

    public struct Value: Codable, Equatable, Sendable, Identifiable {
        public var value: String
        public var summary: String
        /// This choice as a phrase, for the same reason the entry has one:
        /// "tap-preferred (a key pressed first makes it a tap)".
        public var clause: String?
        public var id: String { value }
    }

    /// True when this entry's term, title or prose contains the query.
    /// `foldedQuery` must already be lowercased and trimmed, matching
    /// ``ZMKKeycode/matches(_:)`` — the caller folds once, not once per entry.
    public func matches(_ foldedQuery: String) -> Bool {
        guard !foldedQuery.isEmpty else { return true }
        return term.lowercased().contains(foldedQuery)
            || title.lowercased().contains(foldedQuery)
            || summary.lowercased().contains(foldedQuery)
            || detail.lowercased().contains(foldedQuery)
    }
}

extension ParamKind {
    /// The term explaining what goes in a slot of this kind.
    ///
    /// Nil for a command, whose options are particular to the behavior offering
    /// them — `BT_CLR` is explained by the vendored description beside the
    /// picker, not by a general entry about commands.
    public var glossaryTerm: String? {
        switch self {
        case .code: "keycode"
        case .mod: "modifier"
        case .layer: "layer"
        case .command: nil
        }
    }
}

/// Every explained term, looked up by the token the UI already has.
///
/// Built once and passed down, the way ``BehaviorIndex`` is: a caption under a
/// picker, a hover popover and the glossary window all answer from this, so
/// none of them can drift into wording its own explanation.
public struct Glossary: Sendable {
    /// Every entry, in file order within each section.
    public let all: [GlossaryEntry]
    private let byTerm: [String: GlossaryEntry]

    public static let empty = Glossary(entries: [])

    public init(entries: [GlossaryEntry]) {
        all = entries
        byTerm = Dictionary(entries.map { ($0.term, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func entry(for term: String) -> GlossaryEntry? {
        byTerm[term]
    }

    /// The term that explains a bound behavior: its own entry where ZMK ships
    /// one, and otherwise the *kind* of thing this keymap defined it as.
    ///
    /// `&hml` is nobody's documented behavior and never will be — it is this
    /// keymap's hold-tap, named by whoever wrote the file. But "hold-tap" is
    /// exactly what someone looking at it needs to read, and a keymap's own
    /// behaviors are most of what a real keymap binds, so falling through to
    /// the kind is the difference between the explanation appearing and not.
    public func term(forBehavior code: String, in keymap: KeymapFile?) -> String? {
        if byTerm[code] != nil { return code }
        switch keymap?.node(boundAs: code) {
        case .behavior(let behavior): return behavior.kind?.glossaryTerm
        case .macro: return BehaviorKind.macroBehavior.glossaryTerm
        case nil: return nil
        }
    }

    /// The line shown under a behavior picker — what this particular binding is
    /// bound to, said as well as it can be said.
    ///
    /// Three answers, and they are different in kind. One of ZMK's own
    /// behaviors gets its stored summary, because every `&kp` is the same
    /// `&kp`. A behavior this keymap defines gets the note its author wrote if
    /// there is one, and otherwise a sentence derived from the node — a keymap
    /// with nine hold-taps in it needs to be told how they differ, and the
    /// generic hold-tap summary is true of all nine. A macro gets its opening
    /// steps, which is the most that can be said about one without being told.
    public func explanation(forBehavior code: String, in keymap: KeymapFile?) -> String? {
        if let entry = byTerm[code] { return entry.summary }
        switch keymap?.node(boundAs: code) {
        case .behavior(let behavior):
            if let note = behavior.note?.trimmingCharacters(in: .whitespacesAndNewlines),
               !note.isEmpty {
                return note
            }
            return BehaviorNarrator.description(of: behavior, glossary: self)
        case .macro(let macro):
            return "Macro: \(AssistantTools.summary(of: macro, sequenceLimit: 6))."
        case nil:
            return nil
        }
    }

    /// The one-liner for a term, or nil. Views calling this are deciding
    /// whether there is a caption to draw at all, so a missing term is an
    /// absence rather than a placeholder.
    public func summary(for term: String) -> String? {
        byTerm[term]?.summary
    }

    /// Entries grouped for display, sections in ``GlossarySection`` order and
    /// empty ones dropped.
    public var sections: [(section: GlossarySection, entries: [GlossaryEntry])] {
        GlossarySection.allCases.compactMap { section in
            let entries = all.filter { $0.section == section }
            return entries.isEmpty ? nil : (section, entries)
        }
    }

    /// The same grouping, narrowed to what matches a search.
    public func sections(matching query: String) -> [(section: GlossarySection, entries: [GlossaryEntry])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sections }
        return GlossarySection.allCases.compactMap { section in
            let entries = all.filter { $0.section == section && $0.matches(needle) }
            return entries.isEmpty ? nil : (section, entries)
        }
    }
}
