import Foundation

public struct KeymapLayer: Identifiable, Sendable, Equatable {
    /// The ZMK layer number, which is also the layer's position in ``KeymapFile/layers``.
    ///
    /// This is what `&mo 2`, `&lt 3 TAB` and a combo's `layers` all mean, so it
    /// is renumbered whenever a layer is added or removed. It is *not* a stable
    /// identity — ``sourceIndex`` is what joins a layer back to its node.
    public internal(set) var id: Int
    /// The devicetree node name, `default_layer`.
    public let nodeName: String
    /// What to show in the UI: the node's `display-name` if it has one,
    /// otherwise the node name humanized — `default_layer` to `Default Layer`.
    public var displayName: String
    public var bindings: [KeyBinding]
    /// Where in the file this layer's node was parsed, or nil for a layer that
    /// did not come from the file and so has to be written whole.
    ///
    /// ``KeymapFile/serialized(layout:)`` used to zip `layers` with the bindings
    /// cells positionally, which silently wrote every layer's bindings into the
    /// wrong node the moment one was inserted in the middle. Anchoring by this
    /// instead is what makes adding and removing layers possible at all.
    public let sourceIndex: Int?

    public init(
        id: Int, nodeName: String, displayName: String, bindings: [KeyBinding],
        sourceIndex: Int? = nil
    ) {
        self.id = id
        self.nodeName = nodeName
        self.displayName = displayName
        self.bindings = bindings
        self.sourceIndex = sourceIndex
    }
}

/// The property names a keymap layer node uses. Anything else in the node is
/// never read and never written, so it survives untouched.
enum LayerProperty {
    static let bindings = "bindings"
    static let displayName = "display-name"
}

/// A node ``KeymapFile`` writes back as `label: node_name { … }` — a behavior
/// or a macro.
///
/// The two differ only in what was read out of the node, so every splice
/// ``KeymapFile/nodeEdits(anchors:models:section:properties:line:wholeLineProperties:node:wholeSection:)``
/// makes is written once against this.
protocol KeymapNodeModel: Identifiable, Sendable {
    var nodeName: String { get }
    var label: String { get }
    /// The ``BehaviorNote`` this node carries. Defaulted, because only
    /// behaviors have one so far and a macro should not have to say it has
    /// none — the splice is written once against this protocol, and a model
    /// that never has a note simply never produces a note edit.
    var note: String? { get }
}

extension KeymapNodeModel {
    var note: String? { nil }
}

/// What a binding's `&label` names, when this keymap is the one that defines
/// it. Behaviors and macros share the namespace — `&hml` and `&em` are looked
/// up the same way — so resolving one is a single question with three answers.
public enum BoundNode: Sendable {
    case behavior(KeymapBehavior)
    case macro(KeymapMacro)
}

extension KeymapBehavior: KeymapNodeModel {}
extension KeymapMacro: KeymapNodeModel {}

/// Something about a combo that would make the file invalid if written.
public struct ComboProblem: Sendable, Equatable, Identifiable {
    public let id: KeymapCombo.ID
    public let message: String
}

public enum KeymapError: Error, CustomStringConvertible, Equatable {
    case noKeymapNode
    case layerCountChanged(expected: Int, got: Int)
    case layoutTooSmall(layer: String, bindings: Int, positions: Int)
    case invalidCombos([String])
    case overlappingEdits(Range<Int>, Range<Int>)
    case bindingOutOfRange(layer: Int, index: Int)
    case layerOutOfRange(Int)
    case invalidDisplayName(String)
    case behaviorNotFound
    case macroNotFound
    case duplicateNodeName(String)
    case layerIndexOutOfRange(Int)
    case lastLayerRemoved
    case invalidNodeName(String)

    public var description: String {
        switch self {
        case .noKeymapNode:
            return "no node with compatible = \"zmk,keymap\""
        case .layerCountChanged(let expected, let got):
            return "layer count changed from \(expected) to \(got); layers cannot be added or removed"
        case .layoutTooSmall(let layer, let bindings, let positions):
            return "layer `\(layer)` has \(bindings) bindings but the layout has only \(positions) key positions"
        case .invalidCombos(let messages):
            return messages.joined(separator: "\n")
        case .overlappingEdits(let first, let second):
            return "internal error: edits \(first) and \(second) overlap"
        case .bindingOutOfRange(let layer, let index):
            return "no key \(index) on layer \(layer); the selected layout may not match the keymap"
        case .layerOutOfRange(let layer):
            return "no layer \(layer) in this keymap"
        case .invalidDisplayName(let name):
            return name.isEmpty
                ? "a layer needs a display name"
                : "`\(name)` cannot be a display name; it is a devicetree string, so no quotes and no line breaks"
        case .behaviorNotFound:
            return "that behavior is not in this keymap"
        case .macroNotFound:
            return "that macro is not in this keymap"
        case .duplicateNodeName(let name):
            return "this keymap already has a node named `\(name)`"
        case .layerIndexOutOfRange(let index):
            return "cannot add or remove a layer at position \(index)"
        case .lastLayerRemoved:
            return "a keymap needs at least one layer"
        case .invalidNodeName(let name):
            return "`\(name)` is not a valid node name; use letters, digits, `-` and `_`"
        }
    }
}

/// A ZMK `.keymap` file opened for editing.
///
/// Only the parts the editor understands are ever rewritten: the
/// `bindings = < ... >` value of each keymap layer, and the properties of the
/// combos in the `zmk,combos` node. Custom behaviors, macros, `#define`s,
/// includes and comments are copied through byte for byte, because they are
/// never re-serialized at all — the original bytes are spliced, not
/// regenerated.
public struct KeymapFile: Sendable {
    /// Where a layer's `display-name` lives, and what it said when it was read.
    ///
    /// The same shape as ``ComboAnchor`` and for the same reason: a rename is
    /// written only when it differs from what was parsed. A layer with no
    /// `display-name` still has a display name — `default_layer` humanizes to
    /// `Default Layer` — so writing the name back unconditionally would invent
    /// a property the file never had, and the byte-for-byte round trip would
    /// stop holding.
    private struct LayerAnchor: Sendable {
        /// Where the node lives, so a removed layer can be cut and a new one
        /// spliced in in front of it.
        let node: NodeAnchor
        /// The display name as parsed, humanized node name included.
        let originalDisplayName: String
        /// The `"…"` of an existing `display-name`, quotes included. Writing
        /// through the value rather than the whole property leaves the rest of
        /// the line — a trailing comment, say — exactly as it was.
        let displayNameValue: Range<Int>?
        /// Indentation for a `display-name` line the node does not have yet,
        /// taken from the `bindings` property it is written in front of.
        let propertyIndent: String
        /// Start of the `bindings` line, which is where a missing
        /// `display-name` is inserted. ZMK keymaps put it there, and an empty
        /// range in front of the property cannot overlap the bindings cell
        /// splice that every save also makes.
        let insertionPoint: Int

        init(node: DTNode, bindings: DTProperty, bytes: [UInt8]) {
            self.node = NodeAnchor(node: node, bytes: bytes)
            self.originalDisplayName = KeymapFile.displayName(of: node)
            self.displayNameValue = node.property(LayerProperty.displayName)?.valueRange
            let nodeIndent = SourceLines.indentation(before: node.range.lowerBound, in: bytes) ?? ""
            self.propertyIndent = SourceLines.indentation(before: bindings.range.lowerBound, in: bytes)
                ?? (nodeIndent + "    ")
            self.insertionPoint = SourceLines.start(of: bindings.range.lowerBound, in: bytes)
        }
    }

    /// The bytes every splice is measured against. This is the parser's own
    /// buffer, not a second copy of it — a byte offset means the same thing to
    /// both or the splice writes to the wrong place.
    private var bytes: [UInt8] { document.source }

    /// One behavior or macro node as it was parsed, joined to its source bytes.
    ///
    /// Generic because behaviors and macros differ only in what was read out of
    /// the node; every edit either of them makes goes through ``NodeAnchor``.
    private struct ModelAnchor<Model: Identifiable & Sendable>: Sendable where Model.ID: Sendable {
        let original: Model
        let node: NodeAnchor
        /// True when the node sits inside the section new siblings are appended
        /// to. A behavior defined at the root of the file is still editable, but
        /// it is not where a new one goes.
        let isInSection: Bool

        var id: Model.ID { original.id }
    }

    private let layerCells: [DTCell]
    /// Parallel to ``layerCells``, so a layer, its bindings cell and its
    /// display name are always read out of the same node. Layers are joined
    /// back to these by ``KeymapLayer/sourceIndex``, never by position in
    /// ``layers``, which moves the moment a layer is added or removed.
    private let layerAnchors: [LayerAnchor]
    private let layersSection: NodeSection
    /// Source order, which ``insertion(of:keeping:)`` and
    /// ``NodeAnchor/deletionRange(takingPrecedingBlanks:in:)`` both depend on.
    private let comboAnchors: [ComboAnchor]
    /// The same anchors keyed by id, because every combo operation joins the
    /// edited model back to what was parsed.
    private let anchorsByID: [KeymapCombo.ID: ComboAnchor]
    private let combosSection: NodeSection

    private let behaviorAnchors: [ModelAnchor<KeymapBehavior>]
    private let behaviorsSection: NodeSection
    private let macroAnchors: [ModelAnchor<KeymapMacro>]
    private let macrosSection: NodeSection

    public let document: DTDocument
    public var layers: [KeymapLayer]
    public private(set) var combos: [KeymapCombo]
    /// The `zmk,behavior-*` nodes the keymap defines for itself, wherever in
    /// the file they sit. Macros are not among them — they are ``macros``.
    public private(set) var behaviors: [KeymapBehavior]
    public private(set) var macros: [KeymapMacro]

    public init(source: Data) throws {
        let document = try DTDocument(source: source)
        guard let keymap = document.nodes(compatible: "zmk,keymap").first else {
            throw KeymapError.noKeymapNode
        }
        let bytes = document.source

        var layers: [KeymapLayer] = []
        var layerCells: [DTCell] = []
        var layerAnchors: [LayerAnchor] = []
        for node in keymap.children {
            guard let bindings = node.property(LayerProperty.bindings),
                  case .cells(let cells) = bindings.value,
                  let cell = cells.first
            else { continue }
            layers.append(
                KeymapLayer(
                    id: layers.count,
                    nodeName: node.name,
                    displayName: KeymapFile.displayName(of: node),
                    bindings: BindingParser.parse(cell.text),
                    sourceIndex: layers.count
                )
            )
            layerCells.append(cell)
            layerAnchors.append(LayerAnchor(node: node, bindings: bindings, bytes: bytes))
        }

        let combosNode = document.nodes(compatible: "zmk,combos").first
        let anchors = (combosNode?.children ?? []).compactMap { ComboAnchor(node: $0, bytes: bytes) }

        // A behavior or a macro can be declared anywhere — in `behaviors { }`,
        // in `macros { }`, or straight under a root — so the whole tree is
        // scanned. The named sections only decide where a *new* one goes.
        let behaviorsNode = KeymapFile.section(named: "behaviors", in: document)
        let macrosNode = KeymapFile.section(named: "macros", in: document)
        var behaviorAnchors: [ModelAnchor<KeymapBehavior>] = []
        var macroAnchors: [ModelAnchor<KeymapMacro>] = []
        for node in document.allNodes() {
            // Macros first: `MacroReader` and `BehaviorReader` must never both
            // claim a node, or two splices would fight over the same bytes.
            if let macro = MacroReader.read(node) {
                macroAnchors.append(ModelAnchor(
                    original: macro,
                    node: NodeAnchor(node: node, bytes: bytes),
                    isInSection: macrosNode?.children.contains { $0 === node } ?? false
                ))
            } else if var behavior = BehaviorReader.read(node) {
                // The note comes off the anchor rather than out of
                // `BehaviorReader`, which is given a parsed node and no bytes:
                // a comment is exactly what the parser threw away, so finding
                // it is a job for the type that already holds source positions.
                let anchor = NodeAnchor(node: node, bytes: bytes, readsNote: true)
                behavior.note = anchor.note
                behaviorAnchors.append(ModelAnchor(
                    original: behavior,
                    node: anchor,
                    isInSection: behaviorsNode?.children.contains { $0 === node } ?? false
                ))
            }
        }

        self.document = document
        self.layers = layers
        self.layerCells = layerCells
        self.layerAnchors = layerAnchors
        self.layersSection = NodeSection.read(
            node: keymap, creatingBefore: keymap, anchors: layerAnchors.map(\.node), bytes: bytes
        )
        self.comboAnchors = anchors
        self.anchorsByID = Dictionary(anchors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.combos = anchors.map(\.original)
        self.combosSection = NodeSection.read(
            node: combosNode, creatingBefore: keymap, anchors: anchors.map(\.node), bytes: bytes
        )
        self.behaviors = behaviorAnchors.map(\.original)
        self.behaviorAnchors = behaviorAnchors
        self.behaviorsSection = NodeSection.read(
            node: behaviorsNode, creatingBefore: keymap,
            anchors: behaviorAnchors.filter(\.isInSection).map(\.node), bytes: bytes
        )
        self.macros = macroAnchors.map(\.original)
        self.macroAnchors = macroAnchors
        self.macrosSection = NodeSection.read(
            node: macrosNode, creatingBefore: keymap,
            anchors: macroAnchors.filter(\.isInSection).map(\.node), bytes: bytes
        )
    }

    /// The `behaviors { }` or `macros { }` node, if the file has one.
    ///
    /// Neither carries a `compatible`, so they are found by name. Having no
    /// properties of its own is what tells them apart from a keymap layer
    /// innocently called `macros`, which would otherwise become the place new
    /// macros are written into.
    private static func section(named name: String, in document: DTDocument) -> DTNode? {
        document.allNodes().first { $0.name == name && $0.properties.isEmpty }
    }

    public init(contentsOf url: URL) throws {
        try self.init(source: Data(contentsOf: url))
    }

    // MARK: - Editing

    /// Throws rather than no-op on an out-of-range index. Swallowing it loses a
    /// user's edit while the UI goes on showing unsaved changes — reachable
    /// whenever the selected layout does not match the keymap.
    public mutating func setBinding(layer: Int, index: Int, to binding: KeyBinding) throws {
        guard layers.indices.contains(layer), layers[layer].bindings.indices.contains(index) else {
            throw KeymapError.bindingOutOfRange(layer: layer, index: index)
        }
        layers[layer].bindings[index] = binding
    }

    /// Renames a layer, writing `display-name` on the next save.
    ///
    /// Throws rather than no-op for the same reason ``setBinding(layer:index:to:)``
    /// does: a swallowed rename leaves the UI showing a name the file will
    /// never contain. The name goes into the file as a devicetree string, so a
    /// quote or a line break in it would end the string early and corrupt the
    /// keymap — there is no escaping to fall back on, so it is refused.
    public mutating func setLayerDisplayName(layer: Int, to name: String) throws {
        guard layers.indices.contains(layer) else { throw KeymapError.layerOutOfRange(layer) }
        guard KeymapFile.displayNameProblem(name) == nil else {
            throw KeymapError.invalidDisplayName(name)
        }
        layers[layer].displayName = name
    }

    /// Replaces a combo with an edited copy of itself, matched by id.
    public mutating func updateCombo(_ combo: KeymapCombo) {
        guard let index = combos.firstIndex(where: { $0.id == combo.id }) else { return }
        combos[index] = combo
    }

    /// Appends a combo. New combos are written at the end of the `combos { }`
    /// node in the order they were added; the existing ones stay where they are.
    public mutating func addCombo(_ combo: KeymapCombo) {
        combos.append(combo)
    }

    public mutating func removeCombo(id: KeymapCombo.ID) {
        combos.removeAll { $0.id == id }
    }

    // MARK: - Behaviors and macros

    /// What `&hml` refers to in this keymap, or nil when nothing here defines
    /// it — a stock ZMK behavior, or one that came in through an include.
    ///
    /// The one place the `&` is stripped and a label is matched. Every feature
    /// that asks "what is this binding bound to" asks here, so a change to how
    /// labels resolve is one change rather than several that must agree.
    public func node(boundAs code: String) -> BoundNode? {
        let label = String(code.drop(while: { $0 == "&" }))
        if let behavior = behaviors.first(where: { $0.label == label }) { return .behavior(behavior) }
        if let macro = macros.first(where: { $0.label == label }) { return .macro(macro) }
        return nil
    }

    /// Adds the behavior, or replaces the one with the same id.
    ///
    /// The node name is checked against every other node this editor models,
    /// not just the other behaviors: devicetree node names are siblings only
    /// within one parent, but two `zmk,behavior-*` nodes sharing a name is
    /// always a mistake and the error is far clearer here than at build time.
    public mutating func upsertBehavior(_ behavior: KeymapBehavior) throws {
        try checkNodeName(behavior.nodeName, ignoring: behavior.id)
        if let index = behaviors.firstIndex(where: { $0.id == behavior.id }) {
            behaviors[index] = behavior
        } else {
            behaviors.append(behavior)
        }
    }

    public mutating func removeBehavior(id: KeymapBehavior.ID) throws {
        guard behaviors.contains(where: { $0.id == id }) else { throw KeymapError.behaviorNotFound }
        behaviors.removeAll { $0.id == id }
    }

    public mutating func upsertMacro(_ macro: KeymapMacro) throws {
        try checkNodeName(macro.nodeName, ignoring: macro.id)
        if let index = macros.firstIndex(where: { $0.id == macro.id }) {
            macros[index] = macro
        } else {
            macros.append(macro)
        }
    }

    public mutating func removeMacro(id: KeymapMacro.ID) throws {
        guard macros.contains(where: { $0.id == id }) else { throw KeymapError.macroNotFound }
        macros.removeAll { $0.id == id }
    }

    private func checkNodeName(_ name: String, ignoring id: UUID) throws {
        guard KeymapCombo.isValidNodeName(name) else { throw KeymapError.invalidNodeName(name) }
        let taken = behaviors.filter { $0.id != id }.map(\.nodeName)
            + macros.filter { $0.id != id }.map(\.nodeName)
        guard !taken.contains(name) else { throw KeymapError.duplicateNodeName(name) }
    }

    // MARK: - Layers

    /// Inserts a layer at `index`, renumbering the layers after it.
    ///
    /// A nil `displayName` means the node gets no `display-name` property at
    /// all and ZMK falls back to the node name, which is what most keymaps do.
    /// Passing the humanized node name is the same thing and is written the
    /// same way, so a caller cannot accidentally add a redundant property.
    ///
    /// **This renumbers every layer after `index`, and `&mo 2` elsewhere in the
    /// file goes on saying `2`.** Call ``layerReferencesAffected(byInsertingAt:)``
    /// first and tell the user what will drift; nothing here rewrites those
    /// references, because they can sit inside macros and behaviors this editor
    /// does not model and a partial rewrite is worse than none.
    public mutating func addLayer(
        nodeName: String, displayName: String?, bindings: [KeyBinding], at index: Int
    ) throws {
        guard index >= 0, index <= layers.count else { throw KeymapError.layerIndexOutOfRange(index) }
        guard KeymapCombo.isValidNodeName(nodeName) else { throw KeymapError.invalidNodeName(nodeName) }
        guard !layers.contains(where: { $0.nodeName == nodeName }) else {
            throw KeymapError.duplicateNodeName(nodeName)
        }
        if let displayName, KeymapFile.displayNameProblem(displayName) != nil {
            throw KeymapError.invalidDisplayName(displayName)
        }

        layers.insert(
            KeymapLayer(
                id: index,
                nodeName: nodeName,
                displayName: displayName ?? KeymapFile.humanized(nodeName),
                bindings: bindings,
                sourceIndex: nil
            ),
            at: index
        )
        renumberLayers()
    }

    /// Removes a layer and renumbers the ones after it. See
    /// ``addLayer(nodeName:displayName:bindings:at:)`` on why the references to
    /// those numbers are left alone.
    public mutating func removeLayer(at index: Int) throws {
        guard layers.indices.contains(index) else { throw KeymapError.layerIndexOutOfRange(index) }
        guard layers.count > 1 else { throw KeymapError.lastLayerRemoved }
        layers.remove(at: index)
        renumberLayers()
    }

    /// Puts every layer's ``KeymapLayer/id`` back in step with its position,
    /// because the id *is* the ZMK layer number and the whole file's `&mo`,
    /// `&lt` and combo `layers` values are read against it.
    private mutating func renumberLayers() {
        for index in layers.indices { layers[index].id = index }
    }

    /// Layer numbers that would change if this edit were applied, and the
    /// bindings elsewhere in the keymap that name them.
    ///
    /// Removing layer 2 makes what was layer 3 into layer 2, so `&mo 3` now
    /// points somewhere else and `&mo 2` points at a layer that is gone. Both
    /// are reported. This scans what the editor models — layers, combos and
    /// macros — and is deliberately not exhaustive: a layer number inside a
    /// custom behavior or a `#define` cannot be found, which is the other half
    /// of why nothing here rewrites anything.
    public func layerReferencesAffected(byRemoving index: Int) -> [String] {
        guard layers.indices.contains(index) else { return [] }
        return layerReferences { $0 >= index }
    }

    public func layerReferencesAffected(byInsertingAt index: Int) -> [String] {
        guard index >= 0, index <= layers.count else { return [] }
        return layerReferences { $0 >= index }
    }

    private func layerReferences(_ isAffected: (Int) -> Bool) -> [String] {
        // Which behaviors take a layer number, and how the number is read off
        // one, is `KeycapKit`'s to say — the same rule the board colors a
        // layer-switch key by.
        var found: [String] = []
        for layer in layers {
            for (key, binding) in layer.bindings.enumerated() {
                guard let value = KeycapKit.layerTarget(of: binding), isAffected(value) else { continue }
                found.append("`\(binding.text)` on layer \(layer.id) (\(layer.displayName)) key \(key)")
            }
        }
        for combo in combos {
            if let value = KeycapKit.layerTarget(of: combo.binding), isAffected(value) {
                found.append("`\(combo.binding.text)` is what combo `\(combo.nodeName)` fires")
            }
            for value in combo.layers ?? [] where isAffected(value) {
                found.append("combo `\(combo.nodeName)` is limited to layer \(value)")
            }
        }
        for macro in macros {
            for (step, binding) in macro.bindings.enumerated() {
                guard let value = KeycapKit.layerTarget(of: binding), isAffected(value) else { continue }
                found.append("`\(binding.text)` in macro `&\(macro.label)` step \(step + 1)")
            }
        }
        return found
    }

    // MARK: - Naming

    /// Every node name this editor models, whatever kind of node it is.
    ///
    /// A new node has to avoid all of them and not just its own kind: two
    /// siblings sharing a name is a devicetree error, and a combo that happens
    /// to be called `hml` alongside a behavior of that name is confusing long
    /// before it is a build failure.
    public var modelledNodeNames: Set<String> {
        var names = Set(layers.map(\.nodeName))
        names.formUnion(combos.map(\.nodeName))
        names.formUnion(behaviors.map(\.nodeName))
        names.formUnion(macros.map(\.nodeName))
        return names
    }

    /// A node name none of `taken` holds, derived from `base`.
    ///
    /// `base` is sanitized into something devicetree accepts, and a collision is
    /// resolved by counting upward — `combo`, `combo-2`, `combo-3`. `separator`
    /// is what goes in front of the count, because a combo is named with `-` and
    /// a behavior or macro with `_`.
    public func uniqueNodeName(
        startingFrom base: String, separator: Character, taken: Set<String>
    ) -> String {
        let sanitized = KeymapCombo.sanitizeNodeName(base)
        let root = sanitized.isEmpty ? "node" : sanitized
        guard taken.contains(root) else { return root }
        var suffix = 2
        while taken.contains("\(root)\(separator)\(suffix)") { suffix += 1 }
        return "\(root)\(separator)\(suffix)"
    }

    /// A node name nothing in the keymap is using yet, derived from `base`.
    ///
    /// The fallback root is picked here rather than inside
    /// ``uniqueNodeName(startingFrom:separator:taken:)`` so an unnameable base
    /// becomes `combo` and not the generic `node`.
    public func uniqueComboName(startingFrom base: String) -> String {
        let sanitized = KeymapCombo.sanitizeNodeName(base)
        return uniqueNodeName(
            startingFrom: sanitized.isEmpty ? "combo" : sanitized,
            separator: "-",
            taken: modelledNodeNames
        )
    }

    /// Why `name` cannot be a layer's display name, or nil when it can.
    ///
    /// The name goes into the file as a devicetree string, so a quote or a line
    /// break in it would end the string early and corrupt the keymap. There is
    /// no escaping to fall back on, which is why it is refused rather than
    /// rewritten.
    public static func displayNameProblem(_ name: String) -> String? {
        if name.isEmpty { return "A layer needs a display name." }
        if name.contains("\"") {
            return "`\(name)` cannot be a display name: it is written into the file as a "
                + "devicetree string, which cannot contain a quote."
        }
        if name.contains(where: \.isNewline) {
            return "A display name cannot contain a line break."
        }
        return nil
    }

    // MARK: - Validation

    /// Reasons the combos as they stand could not be written.
    ///
    /// Only what the editor is actually going to rewrite is checked, property
    /// by property. Anything it leaves alone is the user's own file and is left
    /// to say whatever it says, however odd — a combo whose positions are
    /// `POS_LH_T1` macros reads as having none, and must not be called broken
    /// for it when nothing is being written over them.
    public func comboProblems(positionCount: Int) -> [ComboProblem] {
        var nameCounts: [String: Int] = [:]
        for combo in combos { nameCounts[combo.nodeName, default: 0] += 1 }

        var problems: [ComboProblem] = []
        for combo in combos {
            let original = anchorsByID[combo.id]?.original
            guard original != combo else { continue }
            let label = combo.nodeName.isEmpty ? "This combo" : "Combo `\(combo.nodeName)`"

            if original?.nodeName != combo.nodeName {
                if combo.nodeName.isEmpty {
                    problems.append(ComboProblem(id: combo.id, message: "A combo needs a name."))
                } else if !KeymapCombo.isValidNodeName(combo.nodeName) {
                    problems.append(ComboProblem(
                        id: combo.id,
                        message: "`\(combo.nodeName)` is not a valid node name. Use letters, digits and `-`."
                    ))
                } else if nameCounts[combo.nodeName, default: 0] > 1 {
                    problems.append(ComboProblem(
                        id: combo.id, message: "Two combos are both named `\(combo.nodeName)`."
                    ))
                }
            }

            if original?.keyPositions != combo.keyPositions {
                if combo.keyPositions.count < 2 {
                    problems.append(ComboProblem(
                        id: combo.id, message: "\(label) needs at least two key positions."
                    ))
                }
                if positionCount > 0,
                   let outside = combo.keyPositions.first(where: { $0 < 0 || $0 >= positionCount }) {
                    problems.append(ComboProblem(
                        id: combo.id,
                        message: "\(label) uses key position \(outside), but the layout has \(positionCount) keys."
                    ))
                }
            }

            if original?.binding != combo.binding, combo.binding.behavior.count < 2 {
                problems.append(ComboProblem(id: combo.id, message: "\(label) has no behavior."))
            }
        }
        return problems
    }

    /// True for a combo that has been added or changed since the file was read,
    /// and so is going to be written back.
    public func isEdited(_ combo: KeymapCombo) -> Bool {
        guard let anchor = anchorsByID[combo.id] else { return true }
        return anchor.original != combo
    }

    /// A combo's key positions as they should be shown: the tokens the file
    /// still says while the combo is untouched, and the edited numbers once it
    /// is not.
    ///
    /// This exists so the sidebar and the inspector cannot disagree about a
    /// combo whose positions are `POS_*` macros. Reassembling it from
    /// ``KeymapCombo/keyPositions`` and ``KeymapCombo/unresolvedPositions`` at
    /// each call site loses the source order, and both of them did.
    public func positionTokens(of combo: KeymapCombo) -> [String] {
        guard let anchor = anchorsByID[combo.id],
              anchor.original.keyPositions == combo.keyPositions
        else { return combo.keyPositions.map(String.init) }
        return anchor.original.sourcePositionTokens
    }

    /// True when saving would replace this combo's unresolved `POS_*` macros
    /// with plain numbers, because its positions have been edited.
    public func willDiscardMacros(_ combo: KeymapCombo) -> Bool {
        guard let anchor = anchorsByID[combo.id] else { return false }
        return !anchor.original.unresolvedPositions.isEmpty
            && anchor.original.keyPositions != combo.keyPositions
    }

    /// True when anything at all would be written differently.
    public var hasComboEdits: Bool {
        combos.count != comboAnchors.count || combos.contains(where: isEdited)
    }

    // MARK: - Serializing

    /// Rewrites every layer's bindings cell and every changed combo, and
    /// returns the whole file.
    public func serialized(layout: [KeyPosition]) throws -> Data {
        // Every layer that came from the file must still claim exactly one of
        // the nodes that were parsed. This is no longer a refusal to change the
        // layer count — `addLayer` and `removeLayer` do that — but a check that
        // `layers` was not reshuffled behind their backs into something whose
        // bindings would be spliced into the wrong node.
        let claimed = layers.compactMap(\.sourceIndex)
        guard Set(claimed).count == claimed.count, claimed.allSatisfy(layerCells.indices.contains)
        else {
            throw KeymapError.layerCountChanged(expected: layerCells.count, got: layers.count)
        }
        let problems = comboProblems(positionCount: layout.count)
        guard problems.isEmpty else {
            throw KeymapError.invalidCombos(problems.map(\.message))
        }

        var edits: [SourceEdit] = []
        for layer in layers {
            guard layer.bindings.count <= layout.count else {
                throw KeymapError.layoutTooSmall(
                    layer: layer.nodeName, bindings: layer.bindings.count, positions: layout.count
                )
            }
            // A layer with no source index has no cell to splice; it is written
            // whole by `layerStructureEdits(layout:)` instead.
            guard let source = layer.sourceIndex else { continue }
            let cell = layerCells[source]
            edits.append(.replace(
                cell.innerRange,
                with: BindingTable.rewrite(
                    cellInner: cell.text, bindings: layer.bindings, layout: layout
                )
            ))
        }
        edits += layerNameEdits()
        edits += layerStructureEdits(layout: layout)
        edits += comboEdits()
        edits += behaviorEdits()
        edits += macroEdits()

        return Data(try edits.applied(to: bytes))
    }

    /// Writes back the layers whose display name has been changed.
    ///
    /// This follows the combo "other properties" rule and not the bindings
    /// rule: an untouched layer is not re-rendered at all. Emitting it every
    /// time would add `display-name = "Default Layer";` to every layer that
    /// never had one, which is exactly the regeneration the editor exists to
    /// avoid.
    private func layerNameEdits() -> [SourceEdit] {
        layers.compactMap { layer in
            guard let source = layer.sourceIndex else { return nil }
            let anchor = layerAnchors[source]
            guard layer.displayName != anchor.originalDisplayName else { return nil }
            let quoted = "\"\(layer.displayName)\""
            guard let value = anchor.displayNameValue else {
                return .insert(
                    at: anchor.insertionPoint,
                    anchor.propertyIndent + LayerProperty.displayName + " = " + quoted + ";\n"
                )
            }
            return .replace(value, with: quoted)
        }
    }

    /// Cuts the nodes of removed layers and writes the nodes of added ones.
    ///
    /// A new layer goes in front of the next layer that did come from the file,
    /// so a layer inserted in the middle of a keymap lands in the middle of the
    /// file too and reparses at the number it was given. Only when there is no
    /// such layer does it append after the last surviving one.
    private func layerStructureEdits(layout: [KeyPosition]) -> [SourceEdit] {
        let claimed = Set(layers.compactMap(\.sourceIndex))
        let removed = layerAnchors.indices.filter { !claimed.contains($0) }
        // `removeLayer` refuses to empty the keymap, so this only ever fires
        // when a caller emptied `layers` itself.
        let clearingAll = removed.count == layerAnchors.count && !removed.isEmpty
        var edits: [SourceEdit] = removed.map {
            .delete(layerAnchors[$0].node.deletionRange(takingPrecedingBlanks: clearingAll, in: bytes))
        }

        // Group each run of new layers onto the file layer that follows it;
        // whatever trails the last file layer is appended instead.
        var before: [Int: [KeymapLayer]] = [:]
        var pending: [KeymapLayer] = []
        for layer in layers {
            guard let source = layer.sourceIndex else {
                pending.append(layer)
                continue
            }
            if !pending.isEmpty {
                before[source, default: []] += pending
                pending = []
            }
        }

        func node(_ layer: KeymapLayer) -> String {
            layerNode(layer, layout: layout)
        }
        for (source, added) in before.sorted(by: { $0.key < $1.key }) {
            edits.append(layersSection.inserting(
                added.map(node),
                beforeLineAt: SourceLines.start(
                    of: layerAnchors[source].node.nodeRange.lowerBound, in: bytes
                )
            ))
        }
        if !pending.isEmpty {
            edits.append(layersSection.appending(
                pending.map(node),
                // The keymap node always exists, so this is never reached.
                orCreating: "",
                after: claimed.map { layerAnchors[$0].node.nodeRange.upperBound }
            ))
        }
        return edits
    }

    /// A whole layer node, for a layer the file does not have yet.
    ///
    /// `display-name` is written only when it says something the node name does
    /// not, so a layer named `default_layer` and shown as `Default Layer` comes
    /// out as the two-property node every ZMK keymap already writes.
    private func layerNode(_ layer: KeymapLayer, layout: [KeyPosition]) -> String {
        let indent = layersSection.indent
        let propertyIndent = layersSection.propertyIndent
        var lines = ["\(indent)\(layer.nodeName) {"]
        if layer.displayName != KeymapFile.humanized(layer.nodeName) {
            lines.append(
                "\(propertyIndent)\(LayerProperty.displayName) = \"\(layer.displayName)\";"
            )
        }
        // The cell is framed exactly as `BindingTable.rewrite` would leave an
        // existing one: a newline after `<`, the rows unindented, and the `>`
        // back at the property's own indentation.
        let inner = BindingTable.rewrite(
            cellInner: "\n" + propertyIndent, bindings: layer.bindings, layout: layout
        )
        lines.append("\(propertyIndent)\(LayerProperty.bindings) = <\(inner)>;")
        lines.append("\(indent)};")
        return lines.joined(separator: "\n")
    }

    private func comboEdits() -> [SourceEdit] {
        let live = Set(combos.map(\.id))
        let removed = comboAnchors.filter { !live.contains($0.id) }
        // When the whole section is being cleared out there is no sibling left
        // to keep a blank line for, so the first one takes its own leading gap
        // with it and the section closes up neatly around whatever is added.
        let clearingAll = removed.count == comboAnchors.count && !removed.isEmpty

        // Two combos removed side by side both claim the blank line between
        // them; `applied(to:)` merges deletions that meet rather than calling
        // that an overlap.
        var edits: [SourceEdit] = removed.map {
            .delete($0.node.deletionRange(takingPrecedingBlanks: clearingAll, in: bytes))
        }

        var added: [KeymapCombo] = []
        for combo in combos {
            guard let anchor = anchorsByID[combo.id] else {
                added.append(combo)
                continue
            }
            edits += self.edits(for: combo, anchor: anchor)
        }

        if !added.isEmpty { edits.append(insertion(of: added, keeping: live)) }
        return edits
    }

    /// The edits that turn one existing combo node into what the model says.
    private func edits(for combo: KeymapCombo, anchor: ComboAnchor) -> [SourceEdit] {
        var edits: [SourceEdit] = []

        if combo.nodeName != anchor.original.nodeName {
            edits.append(.replace(anchor.node.nameRange, with: combo.nodeName))
        }

        // The binding is re-rendered on every save, exactly as a layer's
        // bindings are, so an untouched file coming back byte for byte is proof
        // the renderer is right rather than proof it was skipped.
        edits.append(.replace(
            anchor.bindingsInner,
            with: BindingTable.rewrite(
                cellInner: anchor.bindingsOriginalInner, bindings: [combo.binding], layout: []
            )
        ))

        // Everything else is only touched when it changed. `key-positions` is
        // the reason why: positions written as `POS_LH_T1` macros resolve to
        // nothing, so re-rendering an untouched combo would throw the macros
        // away and write an empty list in their place.
        let before = ComboWriter.properties(of: anchor.original)
        for (name, value) in ComboWriter.properties(of: combo)
        where name != ComboProperty.bindings {
            guard value != before.first(where: { $0.name == name })?.value else { continue }
            if let edit = anchor.node.propertyEdit(name, to: value, in: bytes, line: ComboWriter.line) {
                edits.append(edit)
            }
        }

        return edits
    }

    /// Writes combos the file does not have yet, either after the last combo
    /// that survives this save or, when there is no `zmk,combos` node at all,
    /// as a whole new section in front of the keymap.
    private func insertion(of added: [KeymapCombo], keeping live: Set<KeymapCombo.ID>) -> SourceEdit {
        let section = combosSection
        return section.appending(
            added.map {
                ComboWriter.node($0, indent: section.indent, propertyIndent: section.propertyIndent)
            },
            orCreating: ComboWriter.section(
                added, indent: section.sectionIndent, separator: section.separator
            ),
            after: comboAnchors.filter { live.contains($0.id) }.map(\.node.nodeRange.upperBound)
        )
    }

    // MARK: - Serializing behaviors and macros

    /// Behaviors are written property by property and **never re-rendered
    /// whole**, unlike a layer's bindings or a combo's binding.
    ///
    /// `hold-trigger-key-positions = <KEYS_RIGHT THUMBS>;` is why. Those are
    /// preprocessor macros, and re-rendering a behavior nobody touched would
    /// have to reproduce them from a model that only sometimes can. Comparing
    /// the parsed model against the edited one instead means an untouched
    /// behavior produces no edit at all, whatever its properties say.
    private func behaviorEdits() -> [SourceEdit] {
        nodeEdits(
            anchors: behaviorAnchors,
            models: behaviors,
            section: behaviorsSection,
            properties: BehaviorWriter.properties(of:),
            line: BehaviorWriter.line(_:_:propertyIndent:),
            wholeLineProperties: [],
            node: { BehaviorWriter.node($0, indent: $1, propertyIndent: $2) },
            wholeSection: { BehaviorWriter.section($0, indent: $1, separator: $2) }
        )
    }

    private func macroEdits() -> [SourceEdit] {
        nodeEdits(
            anchors: macroAnchors,
            models: macros,
            section: macrosSection,
            properties: MacroWriter.properties(of:),
            line: MacroWriter.line(_:_:propertyIndent:),
            // A macro's `bindings` wraps across several lines, so there is no
            // one-line value to splice into the value range; the whole property
            // is replaced instead.
            wholeLineProperties: [MacroProperty.bindings],
            node: { MacroWriter.node($0, indent: $1, propertyIndent: $2) },
            wholeSection: { MacroWriter.section($0, indent: $1, separator: $2) }
        )
    }

    /// The one implementation behind ``behaviorEdits()`` and ``macroEdits()``.
    ///
    /// Removed nodes are cut with their blank line, surviving ones are spliced
    /// property by property, and new ones are appended to the section — or the
    /// section is created. Exactly what combos do; the models differ only in
    /// how they render.
    private func nodeEdits<Model: KeymapNodeModel>(
        anchors: [ModelAnchor<Model>],
        models: [Model],
        section: NodeSection,
        properties: (Model) -> [(name: String, value: BehaviorValue)],
        line: @escaping (String, BehaviorValue, String) -> String,
        wholeLineProperties: Set<String>,
        node: (Model, String, String) -> String,
        wholeSection: ([Model], String, String) -> String
    ) -> [SourceEdit] where Model.ID: Sendable & Hashable {
        let live = Set(models.map(\.id))
        let removed = anchors.filter { !live.contains($0.id) }
        let inSection = anchors.filter(\.isInSection)
        let clearingAll = !inSection.isEmpty && inSection.allSatisfy { !live.contains($0.id) }
        var edits: [SourceEdit] = removed.map {
            .delete($0.node.deletionRange(
                takingPrecedingBlanks: clearingAll && $0.isInSection, in: bytes
            ))
        }

        let byID = Dictionary(anchors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var added: [Model] = []
        for model in models {
            guard let anchor = byID[model.id] else {
                added.append(model)
                continue
            }
            edits += propertyEdits(
                anchor: anchor.node,
                from: properties(anchor.original), to: properties(model),
                line: line, wholeLineProperties: wholeLineProperties
            )
            if model.note != anchor.original.note,
               let edit = anchor.node.noteEdit(to: model.note, in: bytes) {
                edits.append(edit)
            }
            if model.nodeName != anchor.original.nodeName {
                edits.append(.replace(anchor.node.nameRange, with: model.nodeName))
            }
            if model.label != anchor.original.label {
                // A node that had no label has no label range to write into, so
                // the label is inserted in front of the name instead.
                if let range = anchor.node.labelRange {
                    edits.append(.replace(range, with: model.label))
                } else {
                    edits.append(.insert(at: anchor.node.nameRange.lowerBound, model.label + ": "))
                }
            }
        }

        guard !added.isEmpty else { return edits }
        edits.append(section.appending(
            added.map { node($0, section.indent, section.propertyIndent) },
            orCreating: wholeSection(added, section.sectionIndent, section.separator),
            after: inSection.filter { live.contains($0.id) }.map(\.node.nodeRange.upperBound)
        ))
        return edits
    }

    /// One node's properties, written back only where they differ from what was
    /// parsed. A property the model no longer has is deleted; one it gained is
    /// appended after the last property the node already had.
    private func propertyEdits(
        anchor: NodeAnchor,
        from before: [(name: String, value: BehaviorValue)],
        to after: [(name: String, value: BehaviorValue)],
        line: (String, BehaviorValue, String) -> String,
        wholeLineProperties: Set<String>
    ) -> [SourceEdit] {
        let originals = Dictionary(
            before.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }
        )
        var edits: [SourceEdit] = []

        for (name, value) in after {
            guard value != originals[name] else { continue }
            guard let property = anchor.propertyRanges[name] else {
                edits.append(.insert(
                    at: anchor.propertyInsertionPoint,
                    "\n" + anchor.propertyIndent + line(name, value, anchor.propertyIndent)
                ))
                continue
            }
            // Writing through the value range keeps the rest of the line — a
            // trailing comment, most often. A property that has no value range
            // was a boolean, and one that renders across several lines has no
            // single value to splice, so both replace the whole property.
            if !wholeLineProperties.contains(name), let range = anchor.valueRanges[name],
               let text = KeymapFile.valueText(value) {
                edits.append(.replace(range, with: text))
            } else {
                edits.append(.replace(property, with: line(name, value, anchor.propertyIndent)))
            }
        }

        let kept = Set(after.map(\.name))
        for (name, _) in before where !kept.contains(name) {
            guard let range = anchor.propertyRanges[name] else { continue }
            edits.append(.delete(
                SourceLines.start(of: range.lowerBound, in: bytes)
                    ..< SourceLines.end(of: range.upperBound, in: bytes)
            ))
        }
        return edits
    }

    /// The `<280>` of `tapping-term-ms = <280>;`, or nil for a boolean.
    ///
    /// The writer renders it, so the two cannot disagree about how a value is
    /// spelled.
    private static func valueText(_ value: BehaviorValue) -> String? {
        BehaviorWriter.valueText(value)
    }

    // MARK: - Reading the shape of the file

    private static func displayName(of node: DTNode) -> String {
        if case .string(let name)? = node.property("display-name")?.value, !name.isEmpty {
            return name
        }
        return humanized(node.name)
    }

    /// `default_layer` to `Default Layer`. Also what decides whether a new
    /// layer needs a `display-name` property at all.
    static func humanized(_ nodeName: String) -> String {
        nodeName
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
