import Foundation

/// Reads the inside of a `bindings = < ... >` cell into ``KeyBinding`` values.
public enum BindingParser {
    /// A binding starts at `&` and runs to the next top-level `&` or the end
    /// of the cell. Whitespace and newlines between bindings are insignificant;
    /// the table layout is reconstructed from the keyboard layout, not the file.
    public static func parse(_ text: String) -> [KeyBinding] {
        var bindings: [KeyBinding] = []
        var current: KeyBinding?
        for token in tokenize(text) {
            if token.hasPrefix("&") {
                if let binding = current { bindings.append(binding) }
                current = KeyBinding(behavior: token)
            } else {
                current?.params.append(parseParam(token))
            }
        }
        if let binding = current { bindings.append(binding) }
        return bindings
    }

    /// Splits on whitespace, except inside parentheses so `LG(LS( SPACE ))`
    /// stays one token.
    private static func tokenize(_ text: String) -> [String] {
        split(text, on: \.isWhitespace).filter { !$0.isEmpty }
    }

    /// Splits `text` wherever `isDelimiter` matches outside any parentheses.
    ///
    /// The depth is clamped at zero so a stray `)` cannot drive it negative and
    /// silently stop the rest of the string from splitting at all.
    private static func split(
        _ text: String, on isDelimiter: (Character) -> Bool
    ) -> [String] {
        var parts: [String] = []
        var buffer = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if isDelimiter(character), depth == 0 {
                parts.append(buffer)
                buffer = ""
            } else {
                buffer.append(character)
            }
        }
        parts.append(buffer)
        return parts
    }

    /// `LG(LS(SPACE))` becomes `LG` wrapping `LS` wrapping `SPACE`.
    static func parseParam(_ token: String) -> BindingParam {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else {
            return BindingParam(value: trimmed)
        }
        let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        return BindingParam(
            value: String(trimmed[trimmed.startIndex..<open]),
            params: splitTopLevel(String(inner)).map(parseParam)
        )
    }

    private static func splitTopLevel(_ text: String) -> [String] {
        split(text, on: { $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Renders `[KeyBinding]` back into the aligned text block ZMK keymaps use.
///
/// The column rules below were derived by measuring a real keymap and verified
/// against every layer of it; ``KeymapFile/serialized(layout:)`` re-renders
/// every layer on every save, so an unedited file must come back byte for byte.
public enum BindingTable {
    /// Minimum width of a column that holds at least one binding.
    static let minimumColumnWidth = 7
    /// Padding added after the longest binding in a column.
    static let columnPadding = 2
    /// A column index the layout skips entirely — the gap between the halves of
    /// a split keyboard — still occupies space, but only this much. It is *not*
    /// subject to ``minimumColumnWidth``.
    static let emptyColumnWidth = 2

    struct Placement {
        var row: Int
        var column: Int
        var text: String
    }

    static func placements(_ bindings: [KeyBinding], layout: [KeyPosition]) -> [Placement] {
        var nextFreeColumn: [Int: Int] = [:]
        return bindings.enumerated().map { index, binding in
            let position = index < layout.count ? layout[index] : nil
            let row = position?.row ?? 0
            let column = position?.col ?? nextFreeColumn[row, default: 0]
            nextFreeColumn[row] = column + 1
            return Placement(row: row, column: column, text: binding.text)
        }
    }

    static func columnWidths(_ placements: [Placement]) -> [Int] {
        var longest: [Int: Int] = [:]
        for placement in placements {
            longest[placement.column] = max(longest[placement.column] ?? 0, placement.text.count)
        }
        guard let lastColumn = longest.keys.max() else { return [] }
        return (0...lastColumn).map { column in
            guard let length = longest[column] else { return emptyColumnWidth }
            return max(minimumColumnWidth, length + columnPadding)
        }
    }

    /// One string per row, left-aligned into columns, trailing spaces stripped.
    public static func render(_ bindings: [KeyBinding], layout: [KeyPosition]) -> [String] {
        let placements = placements(bindings, layout: layout)
        guard !placements.isEmpty else { return [] }
        let widths = columnWidths(placements)
        let lastRow = placements.map(\.row).max() ?? 0

        return (0...lastRow).map { row in
            var line = ""
            var column = 0
            for placement in placements.filter({ $0.row == row }).sorted(by: { $0.column < $1.column }) {
                while column < placement.column {
                    line += String(repeating: " ", count: widths[column])
                    column += 1
                }
                line += placement.text
                line += String(repeating: " ", count: widths[column] - placement.text.count)
                column = placement.column + 1
            }
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
    }

    /// Rewrites the inside of a cell, keeping the whitespace that framed it.
    ///
    /// The leading newline after `<` and the indentation before `>` are copied
    /// from the original rather than assumed, so a file indented differently
    /// still round trips. A cell that was written on one line stays on one line
    /// — combos and `#binding-cells` are never tables.
    public static func rewrite(
        cellInner original: String, bindings: [KeyBinding], layout: [KeyPosition]
    ) -> String {
        guard let firstNewline = original.firstIndex(of: "\n"),
              let lastNewline = original.lastIndex(of: "\n")
        else {
            let body = original.drop(while: isBlank)
            let leading = original.prefix(original.count - body.count)
            let trailing = body.reversed().prefix(while: isBlank).reversed()
            return String(leading) + bindings.map(\.text).joined(separator: " ") + String(trailing)
        }

        let prefix = String(original[...firstNewline])
        let tail = String(original[original.index(after: lastNewline)...])
        let rows = render(bindings, layout: layout).joined(separator: "\n")

        // A tail with content on it means the cell had no closing indentation
        // to preserve, so the last row butts straight up against the `>`.
        guard tail.allSatisfy(isBlank) else { return prefix + rows }
        return prefix + rows + "\n" + tail
    }
}

private func isBlank(_ character: Character) -> Bool {
    character == " " || character == "\t"
}
