import Foundation

/// How the keymap is described to Claude.
///
/// Two features render the same things — `ExplainModel` asks about one layer,
/// the assistant's `read_layer` and `list_combos` tools answer questions about
/// any of them — and they must describe an identical keymap in identical words.
/// Two renderers would drift: the assistant would cite a key position the
/// explainer numbered differently, and only one of them would be right.
///
/// Everything here is a pure function of the parsed model. Nothing in this file
/// can reach the `.keymap` on disk.
public enum KeymapDigest {

    /// One layer drawn as it sits under the hands, followed by an index legend
    /// tying each key position back to a key the reader can see.
    ///
    /// A layer whose binding count disagrees with the layout's position count is
    /// the case the editor's layout-mismatch warning is about: the wrong layout is
    /// selected, and rendering through it puts keys in rows and columns they are
    /// not on. A garbled grid is worse than no grid, so this falls back to the
    /// flat numbered list rather than describe a keyboard that does not exist.
    public static func layer(_ layer: KeymapLayer, layout: [KeyPosition]) -> String {
        guard !layout.isEmpty, layout.count == layer.bindings.count else {
            let bindings = layer.bindings.enumerated()
                .map { "\($0.offset): \($0.element.text)" }
                .joined(separator: "\n")
            return """
                The physical layout for this keyboard is unknown, so the bindings \
                are listed in key-position order rather than drawn as a grid:
                \(bindings)
                """
        }

        return """
            The layer as it sits under the hands, one line per physical row:
            \(BindingTable.render(layer.bindings, layout: layout).joined(separator: "\n"))

            The same bindings by key position, row by row, in the same order they \
            appear in the grid above. Use these numbers to refer to keys:
            \(legend(for: layer.bindings, layout: layout))
            """
    }

    /// `index: binding` pairs grouped into the rows of the grid, so a position
    /// number can be tied back to a key the reader can see.
    private static func legend(for bindings: [KeyBinding], layout: [KeyPosition]) -> String {
        Dictionary(grouping: bindings.indices, by: { layout[$0].row ?? 0 })
            .sorted { $0.key < $1.key }
            .map { row, indices in
                let keys = indices
                    .sorted { (layout[$0].col ?? $0) < (layout[$1].col ?? $1) }
                    .map { "\($0): \(bindings[$0].text)" }
                    .joined(separator: ", ")
                return "row \(row) — \(keys)"
            }
            .joined(separator: "\n")
    }

    /// The layer list: number, display name and how many keys each one binds.
    public static func layers(_ layers: [KeymapLayer]) -> String {
        guard !layers.isEmpty else { return "This keymap has no layers." }
        return layers
            .map { "\($0.id): \"\($0.displayName)\" (node `\($0.nodeName)`, \($0.bindings.count) keys)" }
            .joined(separator: "\n")
    }

    /// Every combo, one per line.
    ///
    /// Positions come from `KeymapFile.positionTokens(of:)` rather than
    /// `keyPositions` so a combo written as `<POS_LH_T1 POS_RH_T1>` is described
    /// with the macros it actually uses. Reading it as an empty chord would
    /// invite the model to "fix" a combo that is not broken, and editing its
    /// positions is what throws those macros away.
    public static func combos(_ combos: [KeymapCombo], keymap: KeymapFile?) -> String {
        guard !combos.isEmpty else { return "This keymap has no combos." }
        return combos.map { combo in
            let positions = (keymap?.positionTokens(of: combo) ?? combo.keyPositions.map(String.init))
                .joined(separator: " ")
            var line = "`\(combo.nodeName)`: keys <\(positions)> → \(combo.binding.text)"
            if let layers = combo.layers {
                line += ", layers <\(layers.map(String.init).joined(separator: " "))>"
            } else {
                line += ", active on every layer"
            }
            if let timeout = combo.timeoutMs { line += ", timeout-ms \(timeout)" }
            if let idle = combo.requirePriorIdleMs { line += ", require-prior-idle-ms \(idle)" }
            if combo.isSlowRelease { line += ", slow-release" }
            if !combo.unresolvedPositions.isEmpty {
                line += " (positions \(combo.unresolvedPositions.joined(separator: ", ")) are "
                    + "preprocessor macros this editor cannot resolve to numbers)"
            }
            return line
        }
        .joined(separator: "\n")
    }
}
