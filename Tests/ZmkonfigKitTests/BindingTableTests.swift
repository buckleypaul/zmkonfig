import Foundation
import Testing

@testable import ZmkonfigKit

@Suite("Binding table")
struct BindingTableTests {

    @Test("A column is two wider than its longest binding, with a floor of seven")
    func columnWidths() throws {
        let keymap = try KeymapFile(source: try Fixture.cradioSource())
        let placements = BindingTable.placements(keymap.layers[0].bindings, layout: try Fixture.cradioLayout())
        #expect(BindingTable.columnWidths(placements) == [17, 21, 17, 19, 20, 2, 13, 19, 17, 21, 19])

        let nav = BindingTable.placements(keymap.layers[1].bindings, layout: try Fixture.cradioLayout())
        #expect(BindingTable.columnWidths(nav) == [8, 8, 8, 8, 8, 2, 8, 10, 14, 10, 11])
    }

    @Test("A column the layout skips is exactly two wide, not seven")
    func skippedColumnWidth() throws {
        // Column 5 is the gap between the halves of a split keyboard: no key
        // ever lands there, and it contributes two spaces, below the floor
        // that applies to columns that do hold keys.
        let keymap = try KeymapFile(source: try Fixture.cradioSource())
        let placements = BindingTable.placements(keymap.layers[2].bindings, layout: try Fixture.cradioLayout())
        let widths = BindingTable.columnWidths(placements)
        #expect(widths[5] == BindingTable.emptyColumnWidth)
        #expect(widths[5] == 2)
        #expect(widths.filter { $0 != 2 }.allSatisfy { $0 >= BindingTable.minimumColumnWidth })
    }

    @Test("Rendered rows match the file the rules were derived from")
    func renderMatchesSource() throws {
        let keymap = try KeymapFile(source: try Fixture.cradioSource())
        let source = try Fixture.cradioText()
        for layer in keymap.layers {
            let rendered = BindingTable.render(layer.bindings, layout: try Fixture.cradioLayout())
            #expect(rendered == (try Fixture.bindingLines(of: layer.nodeName, in: source)), "\(layer.nodeName)")
        }
    }

    @Test("Bindings land at the byte offsets measured in the real file")
    func measuredOffsets() throws {
        let keymap = try KeymapFile(source: try Fixture.cradioSource())
        let rows = BindingTable.render(keymap.layers[0].bindings, layout: try Fixture.cradioLayout())
        let expected = [0, 17, 38, 55, 74, 96, 109, 128, 145, 166]
        for row in rows.prefix(3) {
            #expect(offsetsOfBindings(in: row) == expected)
        }
        #expect(offsetsOfBindings(in: rows[3]) == [55, 74, 96, 109])
    }

    @Test("Trailing whitespace is stripped from every row")
    func noTrailingWhitespace() throws {
        let keymap = try KeymapFile(source: try Fixture.cradioSource())
        for layer in keymap.layers {
            for row in BindingTable.render(layer.bindings, layout: try Fixture.cradioLayout()) {
                #expect(!row.hasSuffix(" "), "\(layer.nodeName): \(row.debugDescription)")
            }
        }
    }

    @Test("A binding with no layout position falls into the next free column")
    func fallbackPlacement() {
        let bindings = ["&kp A", "&kp B", "&kp C"].map { KeyBinding(behavior: $0) }
        let rendered = BindingTable.render(bindings, layout: [])
        #expect(rendered == ["&kp A  &kp B  &kp C"])
    }

    @Test("Cell whitespace is copied from the original, not assumed")
    func preservesFraming() {
        let original = "\n&kp A  &kp B\n        "
        let rewritten = BindingTable.rewrite(
            cellInner: original,
            bindings: [KeyBinding(behavior: "&kp", params: [BindingParam(value: "A")])],
            layout: [KeyPosition(row: 0, col: 0, x: 0, y: 0)]
        )
        #expect(rewritten == "\n&kp A\n        ")
    }

    @Test("A one-line cell stays on one line")
    func singleLineCell() {
        let rewritten = BindingTable.rewrite(
            cellInner: "&kp ESC",
            bindings: [KeyBinding(behavior: "&kp", params: [BindingParam(value: "ESC")])],
            layout: []
        )
        #expect(rewritten == "&kp ESC")
    }

    // MARK: Binding parsing

    @Test("A binding runs from its `&` to the next one")
    func parseSplitsOnAmpersand() {
        let bindings = BindingParser.parse("  &kp Q   &hml LEFT_GUI A\n&trans  &bt BT_SEL 0  ")
        #expect(bindings.map(\.text) == ["&kp Q", "&hml LEFT_GUI A", "&trans", "&bt BT_SEL 0"])
        #expect(bindings[2].params.isEmpty)
        #expect(bindings[3].params.count == 2)
    }

    @Test("Modifier functions nest")
    func parseNestedParams() {
        #expect(BindingParser.parse("&kp LS(LG(NUMBER_4))")[0].text == "&kp LS(LG(NUMBER_4))")
        #expect(BindingParser.parse("&kp LC(LEFT)")[0].params[0]
            == BindingParam(value: "LC", params: [BindingParam(value: "LEFT")]))
    }

    @Test("Whitespace inside a modifier function does not split the parameter")
    func parseParensHoldTogether() {
        let parsed = BindingParser.parse("&kp LG( LS(SPACE) )")
        #expect(parsed.count == 1)
        #expect(parsed[0].text == "&kp LG(LS(SPACE))")
    }

    @Test("A cell with no bindings in it parses to nothing")
    func parseNonBindingCell() {
        #expect(BindingParser.parse("KEYS_RIGHT THUMBS").isEmpty)
        #expect(BindingParser.parse("").isEmpty)
    }
}

/// The column each binding starts at, for checking against measured offsets.
private func offsetsOfBindings(in row: String) -> [Int] {
    var offsets: [Int] = []
    var previousWasSpace = true
    for (index, character) in row.enumerated() {
        if character == "&", previousWasSpace { offsets.append(index) }
        previousWasSpace = character == " "
    }
    return offsets
}
