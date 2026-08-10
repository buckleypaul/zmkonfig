import Foundation

/// Describes a behavior *this keymap defines*, in a sentence or two: what it
/// wraps and what its own properties make it do.
///
/// The glossary explains kinds — what a hold-tap is, what `flavor` means — and
/// that is the right answer once. It is the wrong answer nine times: a keymap
/// with `&hml`, `&hmr`, `&qt`, `&sl_hold` and five more hold-taps got the same
/// generic sentence for every one of them, which said nothing about the only
/// thing the user wanted to know, namely how *this* one differs from *that*
/// one. The differences are all in the parsed model, so they can be read out.
///
/// The wording still lives in the glossary — each property entry carries a
/// ``GlossaryEntry/clause`` phrased for a list — so there is one place where
/// `hold-trigger-on-release` is put into English, not two.
public enum BehaviorNarrator {

    /// One keymap-defined behavior, said out loud.
    ///
    /// Always returns something: a node whose `compatible` this editor does not
    /// model still has a name worth printing, and an empty caption under the
    /// picker would read as a failure rather than as an unknown behavior.
    public static func description(of behavior: KeymapBehavior, glossary: Glossary) -> String {
        let kind = BehaviorKind.kind(forCompatible: behavior.compatible)
        let head = kind?.displayName ?? behavior.compatible
        var sentences: [String] = []

        if let wraps = wrapping(behavior, kind: kind, glossary: glossary) {
            sentences.append("\(head): \(wraps).")
        } else if let summary = kind.flatMap({ glossary.summary(for: $0.glossaryTerm) }) {
            // Caps-word and key-repeat wrap nothing, so the generic line is all
            // there is to lead with — but the clauses below still separate one
            // from another.
            sentences.append(summary)
        } else {
            sentences.append("\(head).")
        }

        let clauses = ordered(behavior.properties, glossary: glossary)
            .compactMap { clause(for: $0, glossary: glossary) }
        if !clauses.isEmpty {
            sentences.append(sentenceCasing(clauses.joined(separator: "; ")) + ".")
        }
        return sentences.joined(separator: " ")
    }

    // MARK: - What it wraps

    /// The `bindings` list in words: "hold for a key press, tap for a sticky
    /// layer". Nil for a kind that wraps nothing, or one whose list does not
    /// have the arity its kind requires — a half-written node should fall back
    /// to the generic line rather than describe a binding that is not there.
    private static func wrapping(
        _ behavior: KeymapBehavior, kind: BehaviorKind?, glossary: Glossary
    ) -> String? {
        let wrapped = behavior.bindings.map { name(of: $0, glossary: glossary) }
        switch kind {
        case .holdTap where wrapped.count == 2:
            // Hold first, tap second. Getting that round the wrong way is worse
            // than not saying it at all.
            return "hold for \(wrapped[0]), tap for \(wrapped[1])"
        case .stickyKey where wrapped.count == 1:
            return "makes \(wrapped[0]) stick until the next key you press"
        case .modMorph where wrapped.count == 2:
            return "sends \(wrapped[0]), or \(wrapped[1]) while a listed modifier is held"
        case .tapDance where !wrapped.isEmpty:
            let taps = wrapped.enumerated().map { "\(ordinal($0.offset)) for \($0.element)" }
            return taps.joined(separator: ", ")
        default:
            return nil
        }
    }

    /// One entry of a `bindings` list.
    ///
    /// A bare behavior reads as its glossary title — `&kp` as "a key press" —
    /// because that is the whole point of this exercise. One that carries
    /// parameters keeps its own text: "a key press MINUS" is worse than
    /// `&kp MINUS`, which the user can at least search the file for.
    private static func name(of binding: String, glossary: Glossary) -> String {
        let fields = binding.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let head = fields.first else { return binding }
        guard fields.count == 1, let title = glossary.entry(for: head)?.title else { return binding }
        return "\(article(for: title)) \(title.lowercased())"
    }

    private static func article(for word: String) -> String {
        "aeiouAEIOU".contains(word.first ?? "x") ? "an" : "a"
    }

    private static func ordinal(_ index: Int) -> String {
        switch index {
        case 0: "tap once"
        case 1: "twice"
        case 2: "three times"
        case 3: "four times"
        default: "\(index + 1) times"
        }
    }

    // MARK: - What its properties do

    /// Source order, except that a property chosen from a fixed set of options
    /// comes first.
    ///
    /// In practice that means `flavor`, the only such property ZMK has and the
    /// one that most decides how a hold-tap feels. Two nodes are compared by
    /// reading their descriptions side by side, and source order alone put
    /// flavor first in one and last in another purely because of how the file
    /// happened to be typed. Ordering on "was chosen from a set" rather than on
    /// a hardcoded list of names means a future choice-valued property sorts
    /// itself without this needing to be revisited.
    private static func ordered(
        _ properties: [BehaviorProperty], glossary: Glossary
    ) -> [BehaviorProperty] {
        let isChoice = { (property: BehaviorProperty) in
            glossary.entry(for: property.name)?.values?.isEmpty == false
        }
        return properties.filter(isChoice) + properties.filter { !isChoice($0) }
    }

    /// One property as a phrase, or nil where the glossary has no clause for it
    /// — a property nobody wrote up is left out rather than printed raw.
    private static func clause(for property: BehaviorProperty, glossary: Glossary) -> String? {
        guard let entry = glossary.entry(for: property.name) else { return nil }
        let value = text(of: property.value)
        // A property with a fixed set of options is explained by the option the
        // node actually chose, which is the whole difference between a
        // tap-preferred hold-tap and a hold-preferred one.
        if let chosen = entry.values?.first(where: { $0.value == value })?.clause {
            return chosen
        }
        guard let clause = entry.clause else { return nil }
        return clause.replacingOccurrences(of: "{value}", with: value)
    }

    /// A property's value as it goes inside a clause.
    ///
    /// Unquoted, unlike `AssistantTools.text`: that renders a string as
    /// `"tap-preferred"` for a sentence about devicetree, and the quotes are
    /// noise in "holds after 280 ms".
    private static func text(of value: BehaviorValue) -> String {
        switch value {
        case .flag: ""
        case .integer(let number): String(number)
        case .string(let text): text
        case .integers(let numbers): numbers.map(String.init).joined(separator: " ")
        case .tokens(let tokens), .references(let tokens): tokens.joined(separator: " ")
        }
    }

    private static func sentenceCasing(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
