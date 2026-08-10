import Foundation

/// Splicing a *node* rather than a property value.
///
/// Combos, custom behaviors, macros and keymap layers are all the same shape:
/// sibling nodes under a parent, each anchored to the bytes it was parsed from,
/// each written back only where it actually changed, new ones appended and
/// removed ones cut along with the blank line that spaced them. This file is
/// that logic, once. It used to exist only for combos, and a second copy of it
/// is how the second copy drifts.

/// What a node says about one of its properties, ready to be written.
enum PropertyWrite: Equatable, Sendable {
    /// `name = …;` — the associated text is the value, brackets included.
    case value(String)
    /// `name;` — a boolean property that is simply present.
    case flag
    /// Not written at all, so ZMK's own default applies.
    case absent
}

/// Where a node the file does not have yet would be written, and how the file
/// already spaces and indents its siblings.
struct NodeSection: Sendable {
    /// True when the file already has the parent node — `combos { }`,
    /// `behaviors { }`. False means one has to be created before anything can
    /// be put in it.
    let exists: Bool
    /// Indentation of a child node's own line and of its property lines.
    let indent: String
    let propertyIndent: String
    /// Where to append when no existing child survives to append after.
    let appendOffset: Int
    /// What separates sibling nodes, copied from what the file already does.
    let separator: String
    /// Indentation and offset for the parent node itself, when the file has
    /// none and one has to be made.
    let sectionIndent: String
    let sectionOffset: Int

    /// Reads the shape of a section out of the file.
    ///
    /// `reference` is the node a missing section would be created in front of —
    /// the `zmk,keymap` node, for every section this editor writes. Its own
    /// indentation is what a new section is indented by, so a file that indents
    /// with two spaces keeps doing so.
    static func read(
        node: DTNode?, creatingBefore reference: DTNode, anchors: [NodeAnchor], bytes: [UInt8]
    ) -> NodeSection {
        let sectionIndent = SourceLines.indentation(before: reference.range.lowerBound, in: bytes) ?? "    "
        let sectionOffset = SourceLines.start(of: reference.range.lowerBound, in: bytes)

        guard let node else {
            return NodeSection(
                exists: false,
                indent: sectionIndent + "    ",
                propertyIndent: sectionIndent + "        ",
                appendOffset: sectionOffset,
                separator: "\n\n",
                sectionIndent: sectionIndent,
                sectionOffset: sectionOffset
            )
        }

        let indent = anchors.first?.indent ?? (sectionIndent + "    ")
        // Match however the file already spaces these nodes apart.
        let gap = anchors.first.map { SourceLines.newlinesPreceding($0.nodeRange.lowerBound, in: bytes) } ?? 2
        return NodeSection(
            exists: true,
            indent: indent,
            propertyIndent: anchors.first?.propertyIndent ?? (indent + "    "),
            appendOffset: node.properties.map(\.range.upperBound).max() ?? node.bodyRange.lowerBound,
            separator: String(repeating: "\n", count: max(1, min(gap, 2))),
            sectionIndent: sectionIndent,
            sectionOffset: sectionOffset
        )
    }

    /// Writes nodes the file does not have yet, either after the last sibling
    /// that survives this save or, when there is no parent node at all, as a
    /// whole new section in front of the keymap.
    ///
    /// `section` is only built when it is needed, because rendering a section
    /// for a file that already has one would be wasted work on every save.
    func appending(_ nodes: [String], orCreating section: @autoclosure () -> String,
                   after survivors: [Int]) -> SourceEdit {
        guard exists else { return .insert(at: sectionOffset, section() + "\n\n") }
        let offset = survivors.max() ?? appendOffset
        return .insert(at: offset, nodes.map { separator + $0 }.joined())
    }

    /// Writes nodes in front of an existing sibling rather than after the last
    /// one, which is what inserting a layer in the middle of a keymap needs.
    func inserting(_ nodes: [String], beforeLineAt offset: Int) -> SourceEdit {
        .insert(at: offset, nodes.map { $0 + separator }.joined())
    }
}

/// One existing node's source bytes: where its name is, where each property and
/// each property *value* is, and where a new property would go.
///
/// Holding the value range separately from the whole property is what lets a
/// changed property keep the rest of its line — a trailing comment, most often
/// — instead of being rewritten wholesale.
struct NodeAnchor: Sendable {
    /// The whole node, from the label (or name) through the trailing `;`.
    let nodeRange: Range<Int>
    /// Just the node's name token, so renaming is a one-word diff.
    let nameRange: Range<Int>
    /// The `hml` of `hml: hold_tap_left { }`, or nil for an unlabelled node.
    let labelRange: Range<Int>?
    /// Whole `name = value;` ranges, for when a property has to come out.
    let propertyRanges: [String: Range<Int>]
    /// Value ranges, brackets included, for when only the value changes.
    let valueRanges: [String: Range<Int>]
    /// Indentation of the node's own line and of its property lines.
    let indent: String
    let propertyIndent: String
    /// Where a property the node does not have yet gets written.
    let propertyInsertionPoint: Int
    /// Just inside the `{`, where a node that has no ``BehaviorNote`` yet gets
    /// one.
    let bodyStart: Int
    /// The node's ``BehaviorNote`` and the bytes its comment occupies, read
    /// together so the text and the place it came from can never disagree.
    let note: String?
    let noteRange: Range<Int>?

    /// `readsNote` is opt-in because only behaviors carry one. Scanning
    /// unconditionally made every anchor pay for it, and a layer's body — the
    /// whole `bindings = <…>` cell, usually the largest thing in the file — is
    /// the worst possible place to go looking for a comment that cannot be
    /// there. Macros are the obvious next caller to pass `true`.
    init(node: DTNode, bytes: [UInt8], readsNote: Bool = false) {
        var propertyRanges: [String: Range<Int>] = [:]
        var valueRanges: [String: Range<Int>] = [:]
        for property in node.properties {
            propertyRanges[property.name] = property.range
            if let range = property.valueRange { valueRanges[property.name] = range }
        }
        self.propertyRanges = propertyRanges
        self.valueRanges = valueRanges

        self.nodeRange = node.range
        let start = node.range.lowerBound
        if let label = node.label {
            let labelEnd = min(start + label.utf8.count, bytes.count)
            self.labelRange = start..<labelEnd
            // The parser keeps no range for the `:` or the space after it, so
            // the name is found by walking the bytes rather than by arithmetic
            // — `hml:hold_tap_left` and `hml : hold_tap_left` are both legal.
            var index = labelEnd
            while index < bytes.count, bytes[index] != UInt8(ascii: ":") { index += 1 }
            index = min(index + 1, bytes.count)
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D { index += 1 }
            self.nameRange = index..<min(index + node.name.utf8.count, bytes.count)
        } else {
            self.labelRange = nil
            self.nameRange = start..<min(start + node.name.utf8.count, bytes.count)
        }

        let indent = SourceLines.indentation(before: start, in: bytes) ?? ""
        self.indent = indent
        self.propertyIndent = node.properties.first
            .flatMap { SourceLines.indentation(before: $0.range.lowerBound, in: bytes) }
            ?? (indent + "    ")
        self.propertyInsertionPoint = node.properties.map(\.range.upperBound).max()
            ?? node.bodyRange.lowerBound
        self.bodyStart = node.bodyRange.lowerBound

        let note = readsNote ? BehaviorNote.read(bodyRange: node.bodyRange, bytes: bytes) : nil
        self.note = note?.text
        self.noteRange = note?.range
    }

    /// Adds, rewrites or removes this node's ``BehaviorNote``.
    ///
    /// The comment's own bytes are replaced rather than its lines, so the
    /// indentation and the newline around it are the file's and stay the
    /// file's. Removing one takes the whole line, because a line left holding
    /// nothing but its indentation is not what "no description" looks like.
    func noteEdit(to note: String?, in bytes: [UInt8]) -> SourceEdit? {
        let text = note.flatMap { BehaviorNote.comment($0, indent: propertyIndent) }
        switch (text, noteRange) {
        case (nil, nil):
            return nil
        case (nil, .some(let range)):
            return .delete(
                SourceLines.start(of: range.lowerBound, in: bytes)
                    ..< SourceLines.end(of: range.upperBound, in: bytes)
            )
        case (.some(let comment), .some(let range)):
            return .replace(range, with: comment)
        case (.some(let comment), nil):
            return .insert(at: bodyStart, "\n" + propertyIndent + comment)
        }
    }

    /// Adds, changes or removes one property of this node.
    ///
    /// A property that is already there is changed through its value range, so
    /// the rest of its line is left alone. `line` renders a whole `name = …;`
    /// and belongs to whatever model is being written, because each of them
    /// formats its values its own way.
    func propertyEdit(
        _ name: String, to value: PropertyWrite, in bytes: [UInt8],
        line: (String, PropertyWrite) -> String
    ) -> SourceEdit? {
        switch (value, propertyRanges[name] != nil) {
        case (.absent, true):
            guard let range = propertyRanges[name] else { return nil }
            return .delete(
                SourceLines.start(of: range.lowerBound, in: bytes)
                    ..< SourceLines.end(of: range.upperBound, in: bytes)
            )
        case (.absent, false), (.flag, true):
            return nil
        case (.value(let text), true):
            // A property that was boolean cannot gain a value in place; there
            // is no value range to write into. None of the properties this
            // editor knows can change shape that way.
            guard let range = valueRanges[name] else { return nil }
            return .replace(range, with: text)
        case (.value, false), (.flag, false):
            return .insert(at: propertyInsertionPoint, "\n" + propertyIndent + line(name, value))
        }
    }

    /// The bytes to cut when this node is removed: its own lines plus the blank
    /// line that separated it from the next sibling — or, when it was the last
    /// one, from the previous.
    ///
    /// `takingPrecedingBlanks` is for clearing a section out entirely: with no
    /// sibling left to keep a gap for, the first node takes its own leading gap
    /// with it and the section closes up neatly around whatever is added back.
    func deletionRange(takingPrecedingBlanks: Bool, in bytes: [UInt8]) -> Range<Int> {
        var start = SourceLines.start(of: nodeRange.lowerBound, in: bytes)
        var end = SourceLines.end(of: nodeRange.upperBound, in: bytes)

        let withoutTrailingBlanks = end
        while end < bytes.count, SourceLines.isBlank(lineAt: end, in: bytes) {
            end = SourceLines.end(of: end, in: bytes)
        }
        if takingPrecedingBlanks || end == withoutTrailingBlanks {
            while start > 0,
                  SourceLines.isBlank(lineAt: SourceLines.start(of: start - 1, in: bytes), in: bytes) {
                start = SourceLines.start(of: start - 1, in: bytes)
            }
        }
        return start..<end
    }
}
