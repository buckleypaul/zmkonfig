import Foundation

/// One splice into the original file: replace `range` with `text`.
///
/// Everything the editor writes goes through this type, because the editor
/// never regenerates a keymap — it rewrites a handful of byte spans and copies
/// every other byte through untouched. An insertion is an empty range; a
/// deletion is empty text.
struct SourceEdit: Sendable, Equatable {
    let range: Range<Int>
    let text: String

    static func replace(_ range: Range<Int>, with text: String) -> SourceEdit {
        SourceEdit(range: range, text: text)
    }

    static func insert(at offset: Int, _ text: String) -> SourceEdit {
        SourceEdit(range: offset..<offset, text: text)
    }

    static func delete(_ range: Range<Int>) -> SourceEdit {
        SourceEdit(range: range, text: "")
    }
}

extension Array where Element == SourceEdit {
    /// Applies every edit, back to front so the offsets of the earlier ones are
    /// still valid when they are spliced.
    ///
    /// Two edits that overlap would quietly corrupt each other, so that is an
    /// error rather than a coin toss. Several insertions at one offset are
    /// fine: they land in the order they were made.
    func applied(to bytes: [UInt8]) throws -> [UInt8] {
        let ordered = Array.mergingDeletions(self)
            .enumerated()
            .sorted {
                $0.element.range.lowerBound == $1.element.range.lowerBound
                    ? $0.offset > $1.offset
                    : $0.element.range.lowerBound > $1.element.range.lowerBound
            }
            .map(\.element)

        // `ordered` runs backwards through the file, so each pair is
        // (the later edit, the one before it).
        for (later, earlier) in zip(ordered, ordered.dropFirst())
        where earlier.range.upperBound > later.range.lowerBound {
            throw KeymapError.overlappingEdits(earlier.range, later.range)
        }

        var output: [UInt8] = bytes
        for edit in ordered {
            output.replaceSubrange(edit.range, with: [UInt8](edit.text.utf8))
        }
        return output
    }

    /// Merges deletions that meet or overlap into a single deletion.
    ///
    /// Two combos that sit next to each other and are removed together both
    /// claim the blank line between them. That is not a conflict — it is the
    /// same bytes being deleted twice — so it merges here rather than reaching
    /// the overlap check. Overlapping *replacements* are left alone and still
    /// throw, because which text should win is unknowable.
    ///
    /// Deleting `a..<b` and `b..<c` back to front leaves exactly what deleting
    /// `a..<c` does, so merging touching ranges is free as well as necessary.
    private static func mergingDeletions(_ edits: [SourceEdit]) -> [SourceEdit] {
        func isDeletion(_ edit: SourceEdit) -> Bool { edit.text.isEmpty && !edit.range.isEmpty }
        guard edits.filter(isDeletion).count > 1 else { return edits }

        var merged: [Range<Int>] = []
        for range in edits.filter(isDeletion).map(\.range).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<Swift.max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }

        // Each merged range is emitted at the position of the first deletion
        // that fell into it, so insertions keep the relative order they were
        // made in and the tiebreak below still means what it says.
        var emitted = Set<Int>()
        return edits.compactMap { edit in
            guard isDeletion(edit) else { return edit }
            guard let group = merged.firstIndex(where: {
                $0.lowerBound <= edit.range.lowerBound && edit.range.upperBound <= $0.upperBound
            }) else { return edit }
            return emitted.insert(group).inserted ? .delete(merged[group]) : nil
        }
    }
}

extension Array where Element == UInt8 {
    /// The bytes in `range` decoded as UTF-8.
    func text(_ range: Range<Int>) -> String {
        String(decoding: self[range], as: UTF8.self)
    }
}

/// Line arithmetic over the raw bytes, for the edits that splice whole lines
/// in and out rather than just a property's value.
enum SourceLines {
    /// Offset of the first byte of the line `offset` sits on.
    static func start(of offset: Int, in bytes: [UInt8]) -> Int {
        var index = Swift.min(Swift.max(offset, 0), bytes.count)
        while index > 0, bytes[index - 1] != 0x0A { index -= 1 }
        return index
    }

    /// Offset just past the newline that ends the line `offset` sits on, or the
    /// end of the file when the last line is unterminated.
    static func end(of offset: Int, in bytes: [UInt8]) -> Int {
        var index = Swift.min(Swift.max(offset, 0), bytes.count)
        while index < bytes.count, bytes[index] != 0x0A { index += 1 }
        return index < bytes.count ? index + 1 : index
    }

    /// The indentation of the line `offset` sits on, or nil when something
    /// other than whitespace comes before it on that line.
    static func indentation(before offset: Int, in bytes: [UInt8]) -> String? {
        let from = start(of: offset, in: bytes)
        let to = Swift.min(Swift.max(offset, from), bytes.count)
        let prefix = bytes[from..<to]
        guard prefix.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return nil }
        return String(decoding: prefix, as: UTF8.self)
    }

    /// True when the line starting at `offset` holds nothing but whitespace.
    static func isBlank(lineAt offset: Int, in bytes: [UInt8]) -> Bool {
        var index = offset
        while index < bytes.count, bytes[index] != 0x0A {
            guard bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0D else {
                return false
            }
            index += 1
        }
        return index < bytes.count
    }

    /// How many newlines separate `offset` from the previous non-whitespace
    /// byte — 2 means the file leaves a blank line there.
    static func newlinesPreceding(_ offset: Int, in bytes: [UInt8]) -> Int {
        var index = Swift.min(offset, bytes.count)
        var newlines = 0
        while index > 0 {
            let byte = bytes[index - 1]
            if byte == 0x0A { newlines += 1 } else if byte != 0x20 && byte != 0x09 && byte != 0x0D {
                break
            }
            index -= 1
        }
        return newlines
    }
}
