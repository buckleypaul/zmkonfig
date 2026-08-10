import Foundation

/// The `/* zmkonfig: … */` comment a behavior node may carry: a description of
/// what the behavior is *for*, written once and kept in the keymap so it
/// travels with the file, gets reviewed in a diff, and never has to be worked
/// out again.
///
/// ``BehaviorNarrator`` can always say what a node does — it reads the bindings
/// and the properties — but it cannot say why the node exists. "Home-row mod
/// for the left hand, tuned so a fast roll never fires the modifier" is not in
/// the devicetree, and nothing can derive it. It has to be written down, and
/// the keymap is the only place it can be written down that survives a clone.
///
/// A comment rather than a property because a property goes to the compiler:
/// Zephyr warns about properties its binding does not declare, and a future
/// `dtc` could refuse one outright. A comment is invisible to the build by
/// construction.
public enum BehaviorNote {
    /// What marks a comment as one of ours.
    ///
    /// People already write comments inside behavior nodes, and they are not
    /// descriptions — `/* 280 felt too slow */` next to a `tapping-term-ms` is
    /// a note about one property, and promoting it to the node's description
    /// would put it under the behavior picker as if it explained the whole
    /// thing. The marker is what makes claiming a comment an opt-in.
    public static let marker = "zmkonfig:"

    /// The longest note that will be written, in characters.
    ///
    /// A description is a sentence or three. This is not a guess at what reads
    /// well — it is a ceiling on what a generated answer can put in the user's
    /// file, so a model that ignores its instructions and returns an essay
    /// cannot bury the node it is describing.
    public static let characterLimit = 600

    /// The column the rendered comment wraps at, indentation included.
    private static let wrapColumn = 76

    // MARK: - Reading

    /// The note inside a node's body, and the bytes the comment occupies.
    ///
    /// Only a comment that starts its own line counts. That is where this
    /// writes them, and it is also what makes scanning raw bytes safe without a
    /// second lexer: the one thing that could turn a byte scan into a false
    /// positive is a `/*` inside a string literal, and a string literal's
    /// contents never start a line.
    static func read(bodyRange: Range<Int>, bytes: [UInt8]) -> (text: String, range: Range<Int>)? {
        var lineStart = bodyRange.lowerBound
        while lineStart < bodyRange.upperBound {
            let scan = skippingSpaces(from: lineStart, limit: bodyRange.upperBound, in: bytes)
            if matches(openBytes, at: scan, in: bytes, limit: bodyRange.upperBound) {
                let afterOpen = skippingSpaces(
                    from: scan + 2, limit: bodyRange.upperBound, in: bytes
                )
                if matches(markerBytes, at: afterOpen, in: bytes, limit: bodyRange.upperBound),
                   let end = index(of: closeBytes, from: afterOpen,
                                   limit: bodyRange.upperBound, in: bytes) {
                    let text = unwrap(afterOpen + markerBytes.count..<end, in: bytes)
                    return text.isEmpty ? nil : (text, scan..<end + 2)
                }
            }
            let next = SourceLines.end(of: lineStart, in: bytes)
            guard next > lineStart else { break }
            lineStart = next
        }
        return nil
    }

    /// The comment's inner text as one line: continuation indentation and the
    /// leading `*` some comment styles put on every line are dropped, and what
    /// is left is joined with single spaces.
    ///
    /// Wrapping is this file's doing, so unwrapping is too — a note is a
    /// paragraph, and where the line breaks fell in the file is not part of it.
    private static func unwrap(_ range: Range<Int>, in bytes: [UInt8]) -> String {
        let raw = String(decoding: bytes[range.clamped(to: 0..<bytes.count)], as: UTF8.self)
        let lines = raw.split(whereSeparator: \.isNewline).map { line -> Substring in
            var trimmed = Substring(line.drop { $0 == " " || $0 == "\t" })
            if trimmed.first == "*" { trimmed = trimmed.dropFirst().drop { $0 == " " } }
            return trimmed
        }
        return lines.joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// The three needles, encoded once. They used to be re-encoded inside
    /// `matches`, which `index(of:)` calls once per byte — so finding the
    /// closing `*/` allocated an array per byte of the note.
    private static let openBytes = Array("/*".utf8)
    private static let closeBytes = Array("*/".utf8)
    private static let markerBytes = Array(marker.utf8)

    /// Past any spaces and tabs, but never past the end of the line — a comment
    /// this scan cares about opens on the line it is indented on.
    private static func skippingSpaces(from offset: Int, limit: Int, in bytes: [UInt8]) -> Int {
        var index = offset
        while index < limit, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
        return index
    }

    private static func matches(
        _ needle: [UInt8], at offset: Int, in bytes: [UInt8], limit: Int
    ) -> Bool {
        guard offset >= 0, offset + needle.count <= limit else { return false }
        return !zip(needle.indices, needle).contains { bytes[offset + $0.0] != $0.1 }
    }

    private static func index(
        of needle: [UInt8], from offset: Int, limit: Int, in bytes: [UInt8]
    ) -> Int? {
        (offset..<max(offset, limit)).first { matches(needle, at: $0, in: bytes, limit: limit) }
    }

    // MARK: - Writing

    /// The comment as it is written, wrapped, without the indentation of its
    /// first line — the caller has that already, the same way it does for
    /// ``BehaviorWriter/line(_:_:)``. Continuation lines carry their own.
    ///
    /// Returns nil for a note that sanitises away to nothing, which is how an
    /// emptied field asks for the comment to be removed rather than written as
    /// `/* zmkonfig: */`.
    public static func comment(_ note: String, indent: String) -> String? {
        let text = sanitized(note)
        guard !text.isEmpty else { return nil }

        // Aligned under `zmkonfig:` rather than under the `/*`, so the block
        // reads as one paragraph with a marker in front of it.
        let continuation = indent + "   "
        // The first line is built carrying the indent its caller will supply,
        // then has it taken back off — so every line is measured the same way
        // rather than by a condition that knows which line it is on.
        var lines = [indent + "/* " + marker + " "]
        for word in text.split(separator: " ") {
            let candidate = lines[lines.count - 1] + word
            if candidate.count <= wrapColumn {
                lines[lines.count - 1] = candidate + " "
            } else {
                lines.append(continuation + word + " ")
            }
        }
        lines[0].removeFirst(indent.count)
        return lines.map { $0.hasSuffix(" ") ? String($0.dropLast()) : $0 }
            .joined(separator: "\n") + " */"
    }

    /// A note reduced to text that cannot be anything but a comment.
    ///
    /// This is the whole safety story for putting a generated description in
    /// the keymap, and it is structural rather than a matter of asking nicely.
    /// The only way text inside `/* … */` can become devicetree is by closing
    /// the comment, so a `*` is never allowed to be followed by a `/` — a space
    /// goes between them — and the same is done for `/` before `*` so a nested
    /// open cannot be written either. Whitespace collapses to single spaces
    /// because the wrapping is this file's job, control characters are dropped,
    /// and the result is cut at ``characterLimit``.
    ///
    /// The invariant: for any input, the output contains neither `*/` nor `/*`.
    public static func sanitized(_ note: String) -> String {
        var result = ""
        for character in note {
            if character.isWhitespace || character.isNewline {
                if !result.isEmpty, !result.hasSuffix(" ") { result.append(" ") }
                continue
            }
            if let ascii = character.asciiValue, ascii < 0x20 || ascii == 0x7F { continue }
            if character == "/" && result.last == "*" || character == "*" && result.last == "/" {
                result.append(" ")
            }
            result.append(character)
        }

        let trimmed = result.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > characterLimit else { return trimmed }
        return String(trimmed.prefix(characterLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
