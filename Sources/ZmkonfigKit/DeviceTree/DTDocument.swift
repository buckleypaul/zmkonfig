import Foundation

/// A whole devicetree source file, parsed but never rewritten.
///
/// ZMK keymaps legally contain several separate top-level blocks — the usual
/// shape is one or more `/ { ... };` roots plus `&label { ... };` overrides.
/// ``roots`` holds all of them in source order; nothing is merged, because
/// merging would lose the byte ranges the editor splices into.
public struct DTDocument: Sendable {
    public let source: [UInt8]
    public let roots: [DTNode]

    /// Flattened once at parse time. Every caller that wants the whole tree —
    /// the two `nodes(compatible:)` lookups in ``KeymapFile`` and the behavior
    /// index in the app — would otherwise walk and reallocate it again.
    private let flattened: [DTNode]

    public init(source: Data) throws {
        let bytes = [UInt8](source)
        var parser = try DTParser(bytes: bytes)
        let roots = try parser.parseRoots()

        var flattened: [DTNode] = []
        func visit(_ node: DTNode) {
            flattened.append(node)
            for child in node.children { visit(child) }
        }
        for root in roots { visit(root) }

        self.roots = roots
        self.source = bytes
        self.flattened = flattened
    }

    /// Every node in the tree, depth first, parents before children.
    public func allNodes() -> [DTNode] { flattened }

    public func nodes(compatible: String) -> [DTNode] {
        flattened.filter { $0.compatible == compatible }
    }

    public func text(_ range: Range<Int>) -> String {
        source.text(range)
    }
}
