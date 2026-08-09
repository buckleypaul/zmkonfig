import Foundation

/// A `zmk,behavior-macro` node: a labelled sequence of bindings the keymap
/// plays back when the macro is invoked.
///
/// Like a combo and unlike a layer, a macro can be added and removed, so its
/// identity is a UUID rather than its position in the file.
public struct KeymapMacro: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// The devicetree node name, e.g. `email_macro`.
    public var nodeName: String
    /// The label, `email` — what `&email` refers to. Required: a macro with no
    /// label cannot be referenced by a binding, so it would be unusable.
    public var label: String
    /// `compatible` — plain, one-param or two-param.
    public var compatible: String
    /// `#binding-cells`: 0, 1 or 2, matching ``compatible``.
    public var bindingCells: Int
    /// The macro's sequence, in order. These are real bindings — `&kp A`,
    /// `&macro_tap`, `&macro_press`, `&macro_param_1to1` — so they use the same
    /// ``KeyBinding`` the layers and combos do.
    ///
    /// The `<…>` groups the file split them across carry no meaning: ZMK
    /// concatenates the cells, so reading flattens them and writing re-groups
    /// them for legibility.
    public var bindings: [KeyBinding]
    /// `wait-ms`, or nil when the node leaves it to ZMK's default.
    public var waitMs: Int?
    /// `tap-ms`, or nil when unset.
    public var tapMs: Int?

    public init(
        id: UUID = UUID(),
        nodeName: String,
        label: String,
        compatible: String,
        bindingCells: Int,
        bindings: [KeyBinding],
        waitMs: Int? = nil,
        tapMs: Int? = nil
    ) {
        self.id = id
        self.nodeName = nodeName
        self.label = label
        self.compatible = compatible
        self.bindingCells = bindingCells
        self.bindings = bindings
        self.waitMs = waitMs
        self.tapMs = tapMs
    }

    /// The kind this macro's ``compatible`` names, or nil when it is not one
    /// this editor knows.
    public var kind: MacroKind? { MacroKind.kind(forCompatible: compatible) }
}

/// The three macro `compatible` strings ZMK defines, and how many parameters
/// each takes.
public enum MacroKind: String, Sendable, CaseIterable {
    case plain
    case oneParam
    case twoParam

    public var compatible: String {
        switch self {
        case .plain: "zmk,behavior-macro"
        case .oneParam: "zmk,behavior-macro-one-param"
        case .twoParam: "zmk,behavior-macro-two-param"
        }
    }

    public var displayName: String {
        switch self {
        case .plain: "Macro"
        case .oneParam: "Macro (one parameter)"
        case .twoParam: "Macro (two parameters)"
        }
    }

    /// The `#binding-cells` a node of this kind must declare.
    public var bindingCells: Int {
        switch self {
        case .plain: 0
        case .oneParam: 1
        case .twoParam: 2
        }
    }

    public static func kind(forCompatible compatible: String) -> MacroKind? {
        allCases.first { $0.compatible == compatible }
    }
}

/// The property names a macro node uses. Anything else in the node is never
/// read and never written, so it survives untouched.
enum MacroProperty {
    static let compatible = "compatible"
    static let bindingCells = "#binding-cells"
    static let bindings = "bindings"
    static let waitMs = "wait-ms"
    static let tapMs = "tap-ms"
}

/// Reads a macro out of a parsed node.
public enum MacroReader {
    /// The macro this node defines, or nil when the node is not a macro this
    /// editor can model. Nil is "not mine", not a failure: an unmodelled node
    /// is left out entirely, which means nothing ever splices into it and it
    /// survives byte for byte.
    public static func read(_ node: DTNode) -> KeymapMacro? {
        guard let compatible = node.compatible, let kind = MacroKind.kind(forCompatible: compatible)
        else { return nil }

        // A node missing `#binding-cells` is not malformed in a way this editor
        // should invent a complaint about — the kind already says what it is.
        // Only a value that disagrees is a problem, and `problems(with:)` says so.
        let cells = integer(node.property(MacroProperty.bindingCells)) ?? kind.bindingCells

        return KeymapMacro(
            nodeName: node.name,
            // A macro with no label is unusable, but it is still the file's
            // macro; reporting the missing label is `problems(with:)`'s job.
            label: node.label ?? "",
            compatible: compatible,
            bindingCells: cells,
            bindings: bindings(of: node.property(MacroProperty.bindings)),
            waitMs: integer(node.property(MacroProperty.waitMs)),
            tapMs: integer(node.property(MacroProperty.tapMs))
        )
    }

    /// Every binding across every `<…>` group, in source order. ZMK concatenates
    /// the groups, so the split between them carries no meaning.
    private static func bindings(of property: DTProperty?) -> [KeyBinding] {
        guard case .cells(let cells)? = property?.value else { return [] }
        return cells.flatMap { BindingParser.parse($0.text) }
    }

    private static func integer(_ property: DTProperty?) -> Int? {
        guard case .cells(let cells)? = property?.value, let text = cells.first?.text else { return nil }
        return DTCell.integer(text)
    }
}

/// Renders macros back into devicetree text.
public enum MacroWriter {
    /// Roughly how wide one `<…>` group of bindings is allowed to get before
    /// the sequence wraps onto another line. Chosen so a wrapped macro sits
    /// comfortably inside the same width as a rendered binding table.
    static let groupWidth = 56

    /// The bindings that mark a step of the sequence rather than a keypress.
    /// Each of these starts a new `<…>` group, which is how the ZMK docs and
    /// every hand-written macro lay a sequence out.
    static let stepBehaviors: Set<String> = [
        "&macro_press", "&macro_release", "&macro_tap",
        "&macro_wait_time", "&macro_tap_time", "&macro_pause_for_release",
    ]

    /// A whole node, ready to be spliced into a `macros { }` body.
    public static func node(_ macro: KeymapMacro, indent: String, propertyIndent: String) -> String {
        var lines = ["\(indent)\(macro.label): \(macro.nodeName) {"]
        for property in properties(of: macro) {
            lines.append(propertyIndent + line(property.name, property.value, propertyIndent: propertyIndent))
        }
        lines.append("\(indent)};")
        return lines.joined(separator: "\n")
    }

    /// A whole `macros { }` section, for a keymap that has none yet.
    ///
    /// Unlike `combos { }` this section has no `compatible` of its own, so the
    /// first macro follows the brace directly and `separator` only ever falls
    /// *between* siblings.
    public static func section(_ macros: [KeymapMacro], indent: String, separator: String) -> String {
        let bodyIndent = indent + "    "
        let nodes = macros.map { node($0, indent: bodyIndent, propertyIndent: bodyIndent + "    ") }
        return "\(indent)macros {\n" + nodes.joined(separator: separator) + "\n\(indent)};"
    }

    /// Every property a macro writes, in the order ZMK keymaps write them.
    ///
    /// `bindings` comes back as ``BehaviorValue/references(_:)`` holding one
    /// entry per `<…>` group, already wrapped. Write it through
    /// ``line(_:_:propertyIndent:)`` rather than `BehaviorWriter.line`, which
    /// would put every group on one line.
    public static func properties(of macro: KeymapMacro) -> [(name: String, value: BehaviorValue)] {
        var properties: [(name: String, value: BehaviorValue)] = [
            (MacroProperty.compatible, .string(macro.compatible)),
            (MacroProperty.bindingCells, .integer(macro.bindingCells)),
        ]
        if let waitMs = macro.waitMs { properties.append((MacroProperty.waitMs, .integer(waitMs))) }
        if let tapMs = macro.tapMs { properties.append((MacroProperty.tapMs, .integer(tapMs))) }
        properties.append((MacroProperty.bindings, .references(groups(of: macro.bindings))))
        return properties
    }

    /// `wait-ms = <30>;`, or the wrapped multi-line form for a `bindings`
    /// sequence that needs more than one group.
    ///
    /// `propertyIndent` is the indentation of the line this property starts on;
    /// continuation lines are indented one step further, so the `=` and the
    /// `,` separators line up under each other the way ZMK's own examples do.
    public static func line(
        _ name: String, _ value: BehaviorValue, propertyIndent: String
    ) -> String {
        guard name == MacroProperty.bindings, case .references(let groups) = value, groups.count > 1
        else { return BehaviorWriter.line(name, value) }

        let continuation = propertyIndent + "    "
        var text = name
        for (index, group) in groups.enumerated() {
            text += "\n\(continuation)\(index == 0 ? "=" : ",") <\(group)>"
        }
        return text + "\n\(continuation);"
    }

    /// The bindings split into the `<…>` groups they will be written as, each
    /// without its brackets.
    ///
    /// A group breaks before every step behavior — `&macro_press` and friends —
    /// and again whenever one would grow past ``groupWidth``. Where the split
    /// falls is cosmetic: ZMK concatenates the groups, and ``MacroReader`` reads
    /// them back as one flat sequence.
    public static func groups(of bindings: [KeyBinding]) -> [String] {
        var groups: [String] = []
        var current: [String] = []

        func flush() {
            guard !current.isEmpty else { return }
            groups.append(current.joined(separator: " "))
            current = []
        }

        for binding in bindings {
            let text = binding.text
            let starts = stepBehaviors.contains(binding.behavior)
                || binding.behavior.hasPrefix("&macro_param_")
            let width = current.reduce(0) { $0 + $1.count + 1 }
            if !current.isEmpty, starts || width + text.count > groupWidth { flush() }
            current.append(text)
        }
        flush()
        return groups
    }

    /// Reasons this macro could not be written. An empty result means it is
    /// safe to stage.
    public static func problems(with macro: KeymapMacro) -> [String] {
        var problems: [String] = []

        if macro.label.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("The macro has no label, so no binding could ever refer to it.")
        } else if !KeymapBehavior.isValidLabel(macro.label) {
            problems.append(
                "`\(macro.label)` is not a usable label: labels are letters, digits and "
                    + "underscores, and start with a letter or a digit."
            )
        }

        if macro.nodeName.isEmpty {
            problems.append("The macro has no node name.")
        } else if !KeymapCombo.isValidNodeName(macro.nodeName) {
            problems.append(
                "`\(macro.nodeName)` is not a valid devicetree node name: names are letters, "
                    + "digits and `,._+-`, and start with a letter or a digit."
            )
        }

        guard let kind = macro.kind else {
            problems.append(
                "`\(macro.compatible)` is not a macro. A macro is one of "
                    + MacroKind.allCases.map { "`\($0.compatible)`" }.joined(separator: ", ") + "."
            )
            return problems
        }

        if macro.bindingCells != kind.bindingCells {
            problems.append(
                "`#binding-cells` is \(macro.bindingCells), but `\(macro.compatible)` takes "
                    + "\(kind.bindingCells)."
            )
        }

        if macro.bindings.isEmpty {
            problems.append("The macro has no bindings, so invoking it would do nothing.")
        }

        for binding in macro.bindings where binding.behavior.hasPrefix("&macro_param_") {
            guard let parameter = parameterIndex(binding.behavior) else { continue }
            if kind == .plain {
                problems.append(
                    "`\(binding.behavior)` passes a parameter through, but `\(macro.compatible)` "
                        + "takes none — use a one- or two-parameter macro."
                )
            } else if parameter > kind.bindingCells {
                problems.append(
                    "`\(binding.behavior)` uses parameter \(parameter), but `\(macro.compatible)` "
                        + "takes only \(kind.bindingCells)."
                )
            }
        }

        if let waitMs = macro.waitMs, waitMs < 0 {
            problems.append("`wait-ms` cannot be negative.")
        }
        if let tapMs = macro.tapMs, tapMs < 0 {
            problems.append("`tap-ms` cannot be negative.")
        }

        return problems
    }

    /// The source parameter `&macro_param_2to1` reads from, or nil when the
    /// name is not one of ZMK's.
    private static func parameterIndex(_ behavior: String) -> Int? {
        let suffix = behavior.dropFirst("&macro_param_".count)
        guard let digit = suffix.first, let value = Int(String(digit)) else { return nil }
        return value
    }
}
