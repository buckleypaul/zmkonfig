import Foundation

/// A `zmk,behavior-*` node the keymap defines for itself — `&hml`, a tap dance,
/// a mod-morph.
///
/// Like ``KeymapCombo`` and unlike a layer, a behavior can be added and removed,
/// so its identity is a UUID rather than its position in the file, and
/// ``KeymapFile`` matches it back to the node it was read from by that id.
public struct KeymapBehavior: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// The devicetree node name, `hold_tap_left`.
    public var nodeName: String
    /// The label, `hml` — what `&hml` refers to. Required: a behavior with no
    /// label cannot be referenced by a binding, so it would be unusable.
    public var label: String
    /// `compatible`, e.g. `zmk,behavior-hold-tap`.
    public var compatible: String
    /// `#binding-cells`, 0–2.
    public var bindingCells: Int
    /// The `bindings = <&kp>, <&mo>;` list, one entry per `<…>` group. An entry
    /// may carry parameters — a mod-morph writes `<&kp MINUS>, <&kp UNDER>`.
    public var bindings: [String]
    /// Everything else, in source order: `tapping-term-ms`, `flavor`,
    /// `quick-tap-ms`, `require-prior-idle-ms`, `hold-trigger-key-positions`, …
    public var properties: [BehaviorProperty]
    /// What this behavior is *for*, in the user's own words — the
    /// ``BehaviorNote`` comment in the node body, or nil when it has none.
    ///
    /// Not a property, and not derived from one. Everything else on this type
    /// is read out of the devicetree and can be said back by
    /// ``BehaviorNarrator``; this is the part no amount of reading the node
    /// could recover, so it is the only part worth storing.
    public var note: String?

    public init(
        id: UUID = UUID(),
        nodeName: String,
        label: String,
        compatible: String,
        bindingCells: Int,
        bindings: [String],
        properties: [BehaviorProperty],
        note: String? = nil
    ) {
        self.id = id
        self.nodeName = nodeName
        self.label = label
        self.compatible = compatible
        self.bindingCells = bindingCells
        self.bindings = bindings
        self.properties = properties
        self.note = note
    }

    /// The kind this behavior's `compatible` names, or nil when it is one this
    /// editor has no table entry for.
    public var kind: BehaviorKind? { BehaviorKind.kind(forCompatible: compatible) }

    /// Devicetree labels are the subset of node names that can follow a `&`:
    /// ASCII letters, digits and `_`. ``KeymapCombo/isValidNodeName(_:)`` also
    /// admits `,.+-`, which is legal in a node *name* but would produce a
    /// reference — `&hm-l` — that ZMK cannot resolve, so a label is checked
    /// against the narrower rule as well.
    public static func isValidLabel(_ label: String) -> Bool {
        guard KeymapCombo.isValidNodeName(label) else { return false }
        return label.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                || ("0"..."9").contains($0) || $0 == "_"
        }
    }
}

/// One property of a behavior node beyond the three every behavior has.
public struct BehaviorProperty: Sendable, Equatable {
    public var name: String
    public var value: BehaviorValue

    public init(name: String, value: BehaviorValue) {
        self.name = name
        self.value = value
    }
}

/// What a behavior — or a macro; ``MacroWriter`` shares this type — says about
/// one of its properties.
public enum BehaviorValue: Sendable, Equatable {
    /// `<175>`.
    case integer(Int)
    /// `"tap-preferred"`, quotes added on write.
    case string(String)
    /// `<0 1 2>` — used by `hold-trigger-key-positions`.
    case integers([Int])
    /// A phandle list: `<&kp>, <&mo>`. Each entry is one `<…>` group and may
    /// carry parameters.
    case references([String])
    /// A `<…>` cell holding tokens that are not numbers — `<KEYS_RIGHT THUMBS>`
    /// is two preprocessor macros this editor cannot resolve. They are kept
    /// verbatim so the property round trips instead of being flattened to the
    /// numbers it happens to expand to.
    case tokens([String])
    /// A boolean property, written as a bare `name;`.
    case flag

    /// True for a value that would render as an empty `<>`, which devicetree
    /// does not accept. The three list cases each reach it the same way, so the
    /// check is here rather than repeated per case at the one call site.
    public var isEmptyCell: Bool {
        switch self {
        case .integers(let numbers): numbers.isEmpty
        case .tokens(let tokens): tokens.isEmpty
        case .references(let references): references.isEmpty
        case .integer, .string, .flag: false
        }
    }
}

/// Why a behavior node could not be modelled.
///
/// ``BehaviorReader/read(_:)`` reports "not mine" by returning nil rather than
/// by throwing, so these describe a node that *is* a behavior and still cannot
/// be edited. The node is then left out of the model entirely, which means
/// nothing ever splices into it and it survives byte for byte.
public enum BehaviorParseError: Error, CustomStringConvertible, Equatable {
    /// A property value in a form this editor cannot re-render — a bare phandle
    /// `foo = &bar;`, or a mixed value the parser kept as source text.
    case unsupportedValue(property: String, text: String)

    public var description: String {
        switch self {
        case .unsupportedValue(let property, let text):
            "`\(property) = \(text);` is a value this editor cannot rewrite, "
                + "so the node it is in is left untouched."
        }
    }
}

/// The property names every behavior node has. Anything else lands in
/// ``KeymapBehavior/properties`` in source order and is written back as it was.
enum BehaviorPropertyName {
    static let compatible = "compatible"
    static let bindingCells = "#binding-cells"
    static let bindings = "bindings"
}

/// What a kind's `bindings` property may hold.
///
/// Three states, because a `bindings` count alone cannot say what ZMK needs: a
/// tap dance's length is free, a hold-tap's is exactly two, and a key-repeat has
/// no `bindings` property at all. Collapsing the last two — "zero entries" and
/// "no property" — was the bug this type exists to prevent.
public enum BehaviorBindings: Sendable, Equatable {
    /// The kind declares no `bindings` property. Caps-word and key-repeat are
    /// configured entirely by their other properties, and a `bindings` on one is
    /// a devicetree error rather than a harmless extra.
    case none
    /// The YAML type `phandles`: bare behavior references carrying **no**
    /// parameters, `bindings = <&kp>, <&mo>;`. The parameters come from the
    /// invocation site — `&hml LSHFT A` — not from the node.
    case phandles(count: Int)
    /// The YAML type `phandle-array`: whole bindings, parameters included,
    /// `bindings = <&kp N1>, <&kp N2>;`. `count` is nil where the length is the
    /// point, as a tap dance's length is the number of taps it distinguishes.
    case phandleArray(count: Int?)

    /// Whether an entry may carry parameters. False for `phandles`, where a
    /// parameter is a mistake rather than an extra.
    public var allowsParameters: Bool {
        if case .phandleArray = self { return true }
        return false
    }

    /// Whether the property may appear on the node at all.
    public var isWritten: Bool {
        if case .none = self { return false }
        return true
    }
}

/// The `compatible` strings this editor can offer, with what each needs.
///
/// Every row is ZMK's own, from the bindings in
/// `zmk/app/dts/bindings/behaviors/` — the `bindings` YAML type and its
/// `required`, the `const` on `#binding-cells` that `zero_param.yaml`,
/// `one_param.yaml` and `two_param.yaml` impose, and each kind's required
/// properties. The hold-tap row is corroborated by the eight hold-taps in the
/// test fixture.
///
/// `hold-while-undecided`, `hold-while-undecided-linger` and `keep-mods` are
/// recent upstream additions: a repo pinned to an older ZMK will not have them,
/// so offering one is not a guarantee that the user's tree accepts it.
public enum BehaviorKind: String, Sendable, CaseIterable {
    case holdTap, tapDance, modMorph, stickyKey, macroBehavior, capsWord, keyRepeat

    public var compatible: String {
        switch self {
        case .holdTap: "zmk,behavior-hold-tap"
        case .tapDance: "zmk,behavior-tap-dance"
        case .modMorph: "zmk,behavior-mod-morph"
        case .stickyKey: "zmk,behavior-sticky-key"
        case .macroBehavior: "zmk,behavior-macro"
        case .capsWord: "zmk,behavior-caps-word"
        case .keyRepeat: "zmk,behavior-key-repeat"
        }
    }

    public var displayName: String {
        switch self {
        case .holdTap: "Hold-tap"
        case .tapDance: "Tap dance"
        case .modMorph: "Mod-morph"
        case .stickyKey: "Sticky key"
        case .macroBehavior: "Macro"
        case .capsWord: "Caps word"
        case .keyRepeat: "Key repeat"
        }
    }

    /// The term ``Glossary`` files this kind under — `hold-tap`, `caps-word`.
    ///
    /// Derived from ``compatible`` rather than written out again, so a kind
    /// cannot be added to this enum without also having somewhere to look its
    /// explanation up; the coverage test in `GlossaryTests` is what turns that
    /// into a failure rather than a blank popover.
    public var glossaryTerm: String {
        String(compatible.dropFirst("zmk,behavior-".count))
    }

    /// What this kind's `bindings` property holds, if it has one at all.
    public var bindings: BehaviorBindings {
        switch self {
        case .holdTap: .phandles(count: 2)
        case .stickyKey: .phandles(count: 1)
        case .modMorph: .phandleArray(count: 2)
        case .tapDance, .macroBehavior: .phandleArray(count: nil)
        case .capsWord, .keyRepeat: .none
        }
    }

    /// The `#binding-cells` this kind takes: the number of parameters an
    /// invocation passes, so `&hml LSHFT A` is 2 and `&caps_word` is 0.
    ///
    /// Fixed, not a default. Upstream declares it `required: true` with a
    /// `const`, so a node disagreeing with this is a node ZMK rejects.
    public var bindingCells: Int {
        switch self {
        case .holdTap: 2
        case .stickyKey: 1
        case .tapDance, .modMorph, .macroBehavior, .capsWord, .keyRepeat: 0
        }
    }

    /// Properties upstream marks `required` beyond the three every behavior has.
    /// Omitting one produces firmware that does not build, so
    /// ``BehaviorWriter/problems(with:)`` treats a missing one as a refusal
    /// rather than a warning.
    public var requiredProperties: [String] {
        switch self {
        case .modMorph: ["mods"]
        case .stickyKey: ["release-after-ms"]
        case .capsWord: ["continue-list"]
        case .keyRepeat: ["usage-pages"]
        case .holdTap, .tapDance, .macroBehavior: []
        }
    }

    /// Properties a UI can offer for this kind, past the required ones.
    ///
    /// Deprecated upstream and deliberately absent: `tapping_term_ms` and
    /// `quick_tap_ms` (the underscored spellings), `global-quick-tap`, and
    /// `label`.
    public var optionalProperties: [String] {
        switch self {
        case .holdTap: [
            "tapping-term-ms", "quick-tap-ms", "require-prior-idle-ms", "flavor", "retro-tap",
            "hold-trigger-key-positions", "hold-trigger-on-release",
            "hold-while-undecided", "hold-while-undecided-linger",
        ]
        case .tapDance: ["tapping-term-ms"]
        case .modMorph: ["keep-mods"]
        case .stickyKey: ["quick-release", "lazy", "ignore-modifiers"]
        case .capsWord: ["mods"]
        case .macroBehavior: ["wait-ms", "tap-ms"]
        case .keyRepeat: []
        }
    }

    public static func kind(forCompatible compatible: String) -> BehaviorKind? {
        allCases.first { $0.compatible == compatible }
    }
}

/// Reads behaviors out of parsed devicetree nodes.
public enum BehaviorReader {
    /// Reads a behavior out of a parsed node, or nil when the node is not a
    /// `zmk,behavior-*` node this editor can model.
    ///
    /// Nil covers three cases, and they are all "not mine" rather than a
    /// failure: a node with no `zmk,behavior-` `compatible` at all; a macro,
    /// which ``MacroReader`` owns so that a macro node is never claimed twice;
    /// and a behavior carrying a property value this editor could not write
    /// back unchanged, which is left whole rather than risk rewriting it wrong.
    public static func read(_ node: DTNode) -> KeymapBehavior? {
        guard let compatible = node.compatible,
              compatible.hasPrefix("zmk,behavior-"),
              !compatible.hasPrefix(BehaviorKind.macroBehavior.compatible)
        else { return nil }

        var bindings: [String] = []
        if let property = node.property(BehaviorPropertyName.bindings) {
            guard case .references(let entries) = value(of: property) else { return nil }
            bindings = entries
        }

        var properties: [BehaviorProperty] = []
        for property in node.properties {
            switch property.name {
            case BehaviorPropertyName.compatible,
                 BehaviorPropertyName.bindingCells,
                 BehaviorPropertyName.bindings:
                continue
            default:
                guard let value = value(of: property) else { return nil }
                properties.append(BehaviorProperty(name: property.name, value: value))
            }
        }

        return KeymapBehavior(
            nodeName: node.name,
            label: node.label ?? "",
            compatible: compatible,
            bindingCells: bindingCells(node),
            bindings: bindings,
            properties: properties
        )
    }

    /// `#binding-cells` as written, falling back to what the kind normally
    /// takes. The fallback only reaches a node that omitted the property, which
    /// ZMK itself would reject; writing the conventional value back is more
    /// useful than modelling it as zero.
    private static func bindingCells(_ node: DTNode) -> Int {
        if case .integer(let cells)? = node.property(BehaviorPropertyName.bindingCells)
            .flatMap(value(of:)) {
            return cells
        }
        return node.compatible.flatMap(BehaviorKind.kind(forCompatible:))?.bindingCells ?? 0
    }


    /// Maps one parsed property onto a ``BehaviorValue``, or nil when it is in a
    /// form this editor cannot render back.
    static func value(of property: DTProperty) -> BehaviorValue? {
        switch property.value {
        case .none:
            return .flag
        case .string(let text):
            return .string(text)
        case .cells(let cells):
            let groups = cells.map { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
            if groups.contains(where: { $0.first?.hasPrefix("&") == true }) {
                return .references(groups.map { $0.joined(separator: " ") })
            }
            let fields = groups.flatMap { $0 }
            let numbers = fields.compactMap(DTCell.integer)
            if numbers.count == fields.count {
                return fields.count == 1 ? .integer(numbers[0]) : .integers(numbers)
            }
            return .tokens(fields)
        case .reference, .other:
            // `foo = &bar;` and anything the parser kept as raw text would have
            // to be re-rendered in a shape this type cannot express, so the
            // whole node is declined rather than rewritten into a different one.
            return nil
        }
    }
}

/// Renders behaviors back into devicetree text, matching ``ComboWriter``.
public enum BehaviorWriter {
    /// The whole node, ready to splice into a `behaviors { }` body.
    public static func node(
        _ behavior: KeymapBehavior, indent: String, propertyIndent: String
    ) -> String {
        var lines = ["\(indent)\(behavior.label): \(behavior.nodeName) {"]
        // First line of the body, so it introduces the node rather than
        // interrupting it — and so a reader meets the sentence before the
        // milliseconds.
        if let note = behavior.note,
           let comment = BehaviorNote.comment(note, indent: propertyIndent) {
            lines.append(propertyIndent + comment)
        }
        for property in properties(of: behavior) {
            lines.append(propertyIndent + line(property.name, property.value))
        }
        lines.append("\(indent)};")
        return lines.joined(separator: "\n")
    }

    /// A `behaviors { }` section containing these, for a file that has none.
    ///
    /// Unlike `combos { }` the section carries no `compatible` of its own, so
    /// the first node follows the brace directly and only the nodes after it are
    /// spaced by `separator`.
    public static func section(
        _ behaviors: [KeymapBehavior], indent: String, separator: String
    ) -> String {
        let nodeIndent = indent + "    "
        var text = "\(indent)behaviors {"
        for (offset, behavior) in behaviors.enumerated() {
            text += (offset == 0 ? "\n" : separator)
            text += node(behavior, indent: nodeIndent, propertyIndent: nodeIndent + "    ")
        }
        return text + "\n\(indent)};"
    }

    /// Every property as it would be written, in the order it should appear —
    /// `compatible`, `#binding-cells`, `bindings`, then the rest in source
    /// order.
    ///
    /// This is the complete set the node should end up with: a property the file
    /// has that is missing here is one the behavior no longer wants, which is
    /// how an emptied `bindings` asks to be deleted rather than written as `<>`.
    public static func properties(of behavior: KeymapBehavior) -> [(name: String, value: BehaviorValue)] {
        var result: [(name: String, value: BehaviorValue)] = [
            (BehaviorPropertyName.compatible, .string(behavior.compatible)),
            (BehaviorPropertyName.bindingCells, .integer(behavior.bindingCells)),
        ]
        if !behavior.bindings.isEmpty {
            result.append((BehaviorPropertyName.bindings, .references(behavior.bindings)))
        }
        result += behavior.properties.map { ($0.name, $0.value) }
        return result
    }

    /// `tapping-term-ms = <280>;`, or `hold-trigger-on-release;` for a boolean.
    public static func line(_ name: String, _ value: BehaviorValue) -> String {
        "\(name)\(valueClause(value));"
    }

    /// The same line, with the signature ``MacroWriter/line(_:_:propertyIndent:)``
    /// has so the two can be passed interchangeably. A behavior property always
    /// fits on one line, so the indent is not needed.
    public static func line(
        _ name: String, _ value: BehaviorValue, propertyIndent: String
    ) -> String {
        line(name, value)
    }

    /// The `= …` half of a property line, empty for a flag.
    static func valueClause(_ value: BehaviorValue) -> String {
        valueText(value).map { " = \($0)" } ?? ""
    }

    /// The `<280>` of `tapping-term-ms = <280>;`, or nil for a flag, which has
    /// no value at all.
    ///
    /// Splicing writes through a property's value range to leave the rest of
    /// the line alone, so it needs the value on its own rather than the whole
    /// clause — and getting it by taking `valueClause`'s output back apart was
    /// how the two used to be kept in step.
    public static func valueText(_ value: BehaviorValue) -> String? {
        switch value {
        case .integer(let number): "<\(number)>"
        case .string(let text): "\"\(text)\""
        case .integers(let numbers): cell(numbers.map(String.init))
        case .tokens(let tokens): cell(tokens)
        case .references(let references):
            references.map { cell([reference($0)]) }.joined(separator: ", ")
        case .flag: nil
        }
    }

    static func cell(_ fields: [String]) -> String {
        "<\(fields.joined(separator: " "))>"
    }

    /// A binding entry always writes with its `&`, so a model built from a UI
    /// that dropped it still produces a phandle rather than a bare word.
    private static func reference(_ entry: String) -> String {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("&") ? trimmed : "&" + trimmed
    }

    /// Reasons this behavior could not be written, in the order a reader would
    /// meet them. Empty means it is safe to splice.
    public static func problems(with behavior: KeymapBehavior) -> [String] {
        var problems: [String] = []
        let subject = name(of: behavior)

        if behavior.nodeName.isEmpty {
            problems.append("The behavior has no node name.")
        } else if !KeymapCombo.isValidNodeName(behavior.nodeName) {
            problems.append(
                "`\(behavior.nodeName)` is not a valid devicetree node name: node names are "
                    + "letters, digits and `,._+-`, and start with a letter or a digit."
            )
        }

        if behavior.label.isEmpty {
            problems.append(
                "\(subject) has no label, so no binding could refer to it as `&…` and it would "
                    + "have no effect. Give it one, such as `hml`."
            )
        } else if !KeymapBehavior.isValidLabel(behavior.label) {
            problems.append(
                "`\(behavior.label)` is not a valid label: a label is letters, digits and `_`, "
                    + "because `&\(behavior.label)` has to name it."
            )
        }

        if behavior.compatible.isEmpty {
            problems.append("\(subject) has no `compatible`, so ZMK would not know what it is.")
        }

        if !(0...2).contains(behavior.bindingCells) {
            problems.append(
                "`#binding-cells` is \(behavior.bindingCells); a ZMK behavior takes 0, 1 or 2 "
                    + "parameters."
            )
        } else if let kind = behavior.kind, behavior.bindingCells != kind.bindingCells {
            problems.append(
                "a \(kind.displayName.lowercased()) has `#binding-cells = <\(kind.bindingCells)>`, "
                    + "which ZMK fixes; \(subject) says <\(behavior.bindingCells)>."
            )
        }

        for (offset, binding) in behavior.bindings.enumerated()
        where binding.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("Binding \(offset + 1) of \(subject) is empty.")
        }

        if let kind = behavior.kind {
            problems += bindingProblems(behavior, kind)
            for required in kind.requiredProperties
            where !behavior.properties.contains(where: { $0.name == required }) {
                problems.append(
                    "a \(kind.displayName.lowercased()) needs `\(required)`, and \(subject) has none. "
                        + "Without it the firmware does not build."
                )
            }
        }

        problems += valueProblems(behavior)
        return problems
    }

    /// What the kind's `bindings` type allows: how many entries, and whether an
    /// entry may carry parameters.
    private static func bindingProblems(
        _ behavior: KeymapBehavior, _ kind: BehaviorKind
    ) -> [String] {
        var problems: [String] = []
        let kindName = kind.displayName.lowercased()

        switch kind.bindings {
        case .none where !behavior.bindings.isEmpty:
            problems.append(
                "a \(kindName) has no `bindings` property at all — it is configured by "
                    + "`\(kind.requiredProperties.first ?? "its other properties")` — so writing "
                    + "one would be a devicetree error."
            )
        case .phandles(let count) where behavior.bindings.count != count,
             .phandleArray(.some(let count)) where behavior.bindings.count != count:
            problems.append(
                "a \(kindName) needs exactly \(count) \(count == 1 ? "binding" : "bindings"), "
                    + "but \(name(of: behavior)) has \(behavior.bindings.count)."
            )
        case .none, .phandles, .phandleArray:
            break
        }

        if !kind.bindings.allowsParameters {
            for binding in behavior.bindings
            where binding.trimmingCharacters(in: .whitespaces).contains(where: \.isWhitespace) {
                problems.append(
                    "a \(kindName)'s bindings are bare behavior references, so `\(binding)` cannot "
                        + "carry a parameter — the parameters come from the key that invokes it, "
                        + "as in `&\(behavior.label) LSHFT A`."
                )
            }
        }
        return problems
    }

    private static func name(of behavior: KeymapBehavior) -> String {
        behavior.nodeName.isEmpty ? "the behavior" : "`\(behavior.nodeName)`"
    }

    /// Values that would render into something devicetree cannot parse: an
    /// empty `<>`, a quote inside a string, a token carrying the punctuation
    /// that frames a property.
    private static func valueProblems(_ behavior: KeymapBehavior) -> [String] {
        var problems: [String] = []
        for property in behavior.properties {
            if property.name.isEmpty {
                problems.append("A property of `\(behavior.nodeName)` has no name.")
                continue
            }
            guard !property.value.isEmptyCell else {
                problems.append("`\(property.name)` has no values, so it would write as `<>`.")
                continue
            }
            switch property.value {
            case .tokens(let tokens):
                for token in tokens where token.contains(where: isPunctuation) {
                    problems.append("`\(property.name)` has an unwritable value, `\(token)`.")
                }
            case .string(let text) where text.contains("\""):
                problems.append("`\(property.name)` has a quote in its value, `\(text)`.")
            case .integer, .integers, .string, .references, .flag:
                break
            }
        }
        return problems
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character == "<" || character == ">" || character == ";" || character == "\""
            || character.isWhitespace
    }
}
