import Foundation

/// A `zmk,combos` child node: a chord of key positions bound to one behavior.
///
/// Unlike a layer, a combo can be added and removed, so its identity is a UUID
/// rather than its position in the file. ``KeymapFile`` matches a combo back to
/// the node it was read from by that id and rewrites only what actually
/// changed.
public struct KeymapCombo: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// The devicetree node name, e.g. `escape-combo`.
    public var nodeName: String
    public var binding: KeyBinding
    /// Key positions the chord fires on.
    public var keyPositions: [Int]
    /// `timeout-ms`, or nil when the node leaves it to ZMK's default.
    public var timeoutMs: Int?
    /// `require-prior-idle-ms`, or nil when unset.
    public var requirePriorIdleMs: Int?
    /// `layers`, or nil when unset — the combo is then active on every layer.
    public var layers: [Int]?
    /// The `slow-release;` boolean property.
    public var isSlowRelease: Bool
    /// Position tokens that were not literal numbers. `POS_LH_T1` and friends
    /// are preprocessor macros this editor cannot resolve, so they stay in the
    /// file verbatim and are only lost if ``keyPositions`` is edited.
    public var unresolvedPositions: [String]
    /// Every `key-positions` token exactly as the file wrote them, in source
    /// order — numbers and unresolved macros interleaved as they actually
    /// appear. ``keyPositions`` and ``unresolvedPositions`` each hold half of
    /// this and neither can reconstruct the order on its own, which is why the
    /// two views that tried both got it wrong.
    ///
    /// Read it through ``KeymapFile/positionTokens(of:)``, which knows whether
    /// the combo has since been edited past what the file still says.
    public var sourcePositionTokens: [String]

    public init(
        id: UUID = UUID(),
        nodeName: String,
        binding: KeyBinding,
        keyPositions: [Int],
        timeoutMs: Int? = nil,
        requirePriorIdleMs: Int? = nil,
        layers: [Int]? = nil,
        isSlowRelease: Bool = false,
        unresolvedPositions: [String] = [],
        sourcePositionTokens: [String] = []
    ) {
        self.id = id
        self.nodeName = nodeName
        self.binding = binding
        self.keyPositions = keyPositions
        self.timeoutMs = timeoutMs
        self.requirePriorIdleMs = requirePriorIdleMs
        self.layers = layers
        self.isSlowRelease = isSlowRelease
        self.unresolvedPositions = unresolvedPositions
        self.sourcePositionTokens = sourcePositionTokens
    }

    /// Devicetree node names are ASCII letters, digits and `,._+-`, and start
    /// with a letter or a digit.
    public static func isValidNodeName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isNameStart(first) else { return false }
        return name.unicodeScalars.allSatisfy(isNameContinue)
    }

    /// Turns a free-typed name into one devicetree accepts. Runs of illegal
    /// characters become a single `-`, which is how the reference editor names
    /// combos too.
    public static func sanitizeNodeName(_ name: String) -> String {
        var result = ""
        var pendingSeparator = false
        for scalar in name.lowercased().unicodeScalars {
            if isNameContinue(scalar) {
                if pendingSeparator, !result.isEmpty { result.append("-") }
                pendingSeparator = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        while let first = result.unicodeScalars.first, !isNameStart(first) {
            result.removeFirst()
        }
        return result
    }

    private static func isNameStart(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    private static func isNameContinue(_ scalar: Unicode.Scalar) -> Bool {
        isNameStart(scalar) || ",._+-".unicodeScalars.contains(scalar)
    }
}

/// The property names a combo node uses. Anything else in the node is never
/// read and never written, so it survives untouched.
enum ComboProperty {
    static let bindings = "bindings"
    static let keyPositions = "key-positions"
    static let timeout = "timeout-ms"
    static let requirePriorIdle = "require-prior-idle-ms"
    static let layers = "layers"
    static let slowRelease = "slow-release"
}

/// Where a combo lives in the source, and what was parsed out of it.
///
/// The `original` copy is what makes a surgical save possible: a property is
/// only rewritten when the edited combo differs from what the file said.
struct ComboAnchor: Sendable {
    let original: KeymapCombo
    /// Where the node and each of its properties live. Shared with behaviors,
    /// macros and layers — see ``NodeAnchor``.
    let node: NodeAnchor
    /// Inside the `bindings = < … >` brackets, and what was there.
    let bindingsInner: Range<Int>
    let bindingsOriginalInner: String

    var id: UUID { original.id }

    /// Reads one child of a `zmk,combos` node.
    ///
    /// Returns nil for a node that is not an editable combo — no `bindings`, or
    /// a `bindings` cell holding anything other than exactly one binding. Such
    /// a node is left out of the model entirely, which means nothing ever
    /// splices into it and it survives byte for byte.
    init?(node: DTNode, bytes: [UInt8]) {
        guard case .cells(let cells)? = node.property(ComboProperty.bindings)?.value,
              let cell = cells.first
        else { return nil }
        let parsed = BindingParser.parse(cell.text)
        guard parsed.count == 1, let binding = parsed.first else { return nil }

        let positions = ComboAnchor.positions(of: node.property(ComboProperty.keyPositions))
        self.original = KeymapCombo(
            nodeName: node.name,
            binding: binding,
            keyPositions: positions.resolved,
            timeoutMs: ComboAnchor.integer(node.property(ComboProperty.timeout)),
            requirePriorIdleMs: ComboAnchor.integer(node.property(ComboProperty.requirePriorIdle)),
            layers: node.property(ComboProperty.layers).map {
                ComboAnchor.positions(of: $0).resolved
            },
            isSlowRelease: node.property(ComboProperty.slowRelease) != nil,
            unresolvedPositions: positions.unresolved,
            sourcePositionTokens: positions.tokens
        )

        self.node = NodeAnchor(node: node, bytes: bytes)
        self.bindingsInner = cell.innerRange
        self.bindingsOriginalInner = cell.text
    }

    private static func integer(_ property: DTProperty?) -> Int? {
        guard case .cells(let cells)? = property?.value, let text = cells.first?.text else { return nil }
        return DTCell.integer(text)
    }

    /// Splits a `<…>` cell into the numbers it holds and the tokens that are
    /// something else — almost always `POS_*` macros — while also keeping every
    /// token in the order the file wrote it.
    private static func positions(
        of property: DTProperty?
    ) -> (resolved: [Int], unresolved: [String], tokens: [String]) {
        guard case .cells(let cells)? = property?.value else { return ([], [], []) }
        var resolved: [Int] = []
        var unresolved: [String] = []
        var tokens: [String] = []
        for field in cells.flatMap({ $0.text.split(whereSeparator: \.isWhitespace) }) {
            tokens.append(String(field))
            if let value = DTCell.integer(String(field)) {
                resolved.append(value)
            } else {
                unresolved.append(String(field))
            }
        }
        return (resolved, unresolved, tokens)
    }
}

/// What a combo says about one of its properties. Behaviors, macros and layers
/// answer the same question, so the type is shared — see ``PropertyWrite``.
typealias ComboPropertyValue = PropertyWrite

/// Renders combos back into devicetree text.
enum ComboWriter {
    /// A whole node, ready to be spliced into a `combos { }` body.
    static func node(_ combo: KeymapCombo, indent: String, propertyIndent: String) -> String {
        var lines = ["\(indent)\(combo.nodeName) {"]
        for property in properties(of: combo) where property.value != .absent {
            lines.append(propertyIndent + line(property.name, property.value))
        }
        lines.append("\(indent)};")
        return lines.joined(separator: "\n")
    }

    /// A whole `combos { }` section, for a keymap that has none yet.
    static func section(_ combos: [KeymapCombo], indent: String, separator: String) -> String {
        let propertyIndent = indent + "    "
        var text = "\(indent)combos {\n\(propertyIndent)compatible = \"zmk,combos\";"
        for combo in combos {
            text += separator + node(combo, indent: propertyIndent, propertyIndent: propertyIndent + "    ")
        }
        return text + "\n\(indent)};"
    }

    /// Every property a combo can write, in the order ZMK keymaps write them.
    static func properties(of combo: KeymapCombo) -> [(name: String, value: ComboPropertyValue)] {
        [
            (ComboProperty.bindings, .value("<\(combo.binding.text)>")),
            (ComboProperty.keyPositions, .value(cell(combo.keyPositions))),
            (ComboProperty.timeout, combo.timeoutMs.map { .value("<\($0)>") } ?? .absent),
            (ComboProperty.layers, combo.layers.map { .value(cell($0)) } ?? .absent),
            (ComboProperty.requirePriorIdle, combo.requirePriorIdleMs.map { .value("<\($0)>") } ?? .absent),
            (ComboProperty.slowRelease, combo.isSlowRelease ? .flag : .absent),
        ]
    }

    /// `key-positions = <1 3>;`, or `slow-release;` for a boolean property.
    ///
    /// `.absent` never reaches here — ``node(_:indent:propertyIndent:)`` filters
    /// it out and ``KeymapFile`` handles it in its own switch. Rendering it as a
    /// flag would write `timeout-ms;`, which is a corrupt keymap rather than a
    /// missing property, so it is a programmer error instead of a default.
    static func line(_ name: String, _ value: ComboPropertyValue) -> String {
        switch value {
        case .value(let text): "\(name) = \(text);"
        case .flag: "\(name);"
        case .absent: preconditionFailure("an absent property is never written")
        }
    }

    static func cell(_ values: [Int]) -> String {
        "<\(values.map(String.init).joined(separator: " "))>"
    }
}
