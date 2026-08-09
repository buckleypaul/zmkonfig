import Foundation

/// Tokens of the devicetree subset ZMK keymaps use.
///
/// The lexer deliberately treats `<...>` groups as opaque spans rather than
/// tokenizing their contents. Cell contents are where key bindings live, and
/// the editor rewrites them as raw text so that everything it does not
/// understand survives a round trip untouched.
enum DTTokenKind: Equatable {
    case identifier(String)
    case string(String)
    /// A `<...>` group. `inner` covers the bytes between the angle brackets.
    case cell(inner: Range<Int>)
    case punct(UInt8)
}

struct DTToken: Equatable {
    let kind: DTTokenKind
    let range: Range<Int>

    /// `punct` and `identifier` are stored, not computed.
    ///
    /// As computed properties they switched over `kind` at every use site, and
    /// the resulting chains (`token.punct == Self.slash`) crash the Swift 6.3.3
    /// optimizer: the CopyPropagation pass fails ownership verification with
    /// "Found outside of lifetime use?!" on the repeated borrows, so `-O`
    /// builds abort while debug builds compile fine. Deriving them once here
    /// keeps every consumer reading a plain stored value.
    let punct: UInt8?
    let identifier: String?

    init(kind: DTTokenKind, range: Range<Int>) {
        self.kind = kind
        self.range = range
        switch kind {
        case .punct(let c):
            self.punct = c
            self.identifier = nil
        case .identifier(let s):
            self.punct = nil
            self.identifier = s
        case .string, .cell:
            self.punct = nil
            self.identifier = nil
        }
    }
}

public struct DTParseError: Error, CustomStringConvertible {
    public let message: String
    public let offset: Int

    public var description: String { "\(message) at byte offset \(offset)" }
}

/// Preprocessor directives are skipped wholesale. `#binding-cells` is a
/// property name, not a directive, so `#` alone cannot decide — the keyword
/// that follows does.
private let directives: Set<String> = [
    "include", "define", "undef", "if", "ifdef", "ifndef",
    "else", "elif", "endif", "pragma", "error", "warning", "line",
]

struct DTLexer {
    let bytes: [UInt8]
    private(set) var pos: Int = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private func byte(at i: Int) -> UInt8? {
        i < bytes.count ? bytes[i] : nil
    }

    private static func isIdentStart(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == UInt8(ascii: "_")
    }

    private static func isIdentContinue(_ c: UInt8) -> Bool {
        isIdentStart(c) || (c >= 0x30 && c <= 0x39)
            || c == UInt8(ascii: "-") || c == UInt8(ascii: ".")
            || c == UInt8(ascii: "@") || c == UInt8(ascii: "+")
            || c == UInt8(ascii: "?") || c == UInt8(ascii: "#")
    }

    private func text(_ range: Range<Int>) -> String {
        bytes.text(range)
    }

    private func isBlockCommentStart(at i: Int) -> Bool {
        byte(at: i) == UInt8(ascii: "/") && byte(at: i + 1) == UInt8(ascii: "*")
    }

    private func isLineCommentStart(at i: Int) -> Bool {
        byte(at: i) == UInt8(ascii: "/") && byte(at: i + 1) == UInt8(ascii: "/")
    }

    /// Consumes a `/* … */` comment, or the rest of the file if it is never
    /// closed. `pos` must sit on the opening `/`.
    private mutating func skipBlockComment() {
        pos += 2
        while pos < bytes.count {
            if bytes[pos] == UInt8(ascii: "*"), byte(at: pos + 1) == UInt8(ascii: "/") {
                pos += 2
                return
            }
            pos += 1
        }
    }

    /// Consumes a `//` comment up to, but not including, its newline.
    private mutating func skipLineComment() {
        while pos < bytes.count, bytes[pos] != 0x0A { pos += 1 }
    }

    /// Advances past whitespace, both comment styles, and preprocessor lines.
    private mutating func skipTrivia() {
        while pos < bytes.count {
            let c = bytes[pos]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                pos += 1
            } else if isBlockCommentStart(at: pos) {
                skipBlockComment()
            } else if isLineCommentStart(at: pos) {
                skipLineComment()
            } else if c == UInt8(ascii: "#"), isDirective(at: pos) {
                skipPreprocessorLine()
            } else {
                return
            }
        }
    }

    private func isDirective(at start: Int) -> Bool {
        var i = start + 1
        // `# include` with intervening space is legal C.
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
        let wordStart = i
        while i < bytes.count, DTLexer.isIdentStart(bytes[i]) { i += 1 }
        guard i > wordStart else { return false }
        return directives.contains(text(wordStart..<i))
    }

    private mutating func skipPreprocessorLine() {
        while pos < bytes.count {
            if bytes[pos] == UInt8(ascii: "\\") {
                // Line continuation: consume the newline too.
                var j = pos + 1
                while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0D { j += 1 }
                if j < bytes.count, bytes[j] == 0x0A {
                    pos = j + 1
                    continue
                }
            }
            if bytes[pos] == 0x0A { return }
            pos += 1
        }
    }

    mutating func next() throws -> DTToken? {
        skipTrivia()
        guard pos < bytes.count else { return nil }
        let start = pos
        let c = bytes[pos]

        if c == UInt8(ascii: "\"") {
            pos += 1
            var value = [UInt8]()
            while pos < bytes.count, bytes[pos] != UInt8(ascii: "\"") {
                if bytes[pos] == UInt8(ascii: "\\"), pos + 1 < bytes.count {
                    value.append(bytes[pos + 1])
                    pos += 2
                } else {
                    value.append(bytes[pos])
                    pos += 1
                }
            }
            guard pos < bytes.count else {
                throw DTParseError(message: "unterminated string", offset: start)
            }
            pos += 1
            return DTToken(kind: .string(String(decoding: value, as: UTF8.self)), range: start..<pos)
        }

        if c == UInt8(ascii: "<") {
            let innerStart = pos + 1
            pos += 1
            var depth = 1
            while pos < bytes.count, depth > 0 {
                let d = bytes[pos]
                if isBlockCommentStart(at: pos) {
                    skipBlockComment()
                    continue
                }
                if isLineCommentStart(at: pos) {
                    skipLineComment()
                    continue
                }
                if d == UInt8(ascii: "\"") {
                    pos += 1
                    while pos < bytes.count, bytes[pos] != UInt8(ascii: "\"") {
                        pos += bytes[pos] == UInt8(ascii: "\\") ? 2 : 1
                    }
                    pos += 1
                    continue
                }
                if d == UInt8(ascii: "<") { depth += 1 }
                if d == UInt8(ascii: ">") {
                    depth -= 1
                    if depth == 0 {
                        let inner = innerStart..<pos
                        pos += 1
                        return DTToken(kind: .cell(inner: inner), range: start..<pos)
                    }
                }
                pos += 1
            }
            throw DTParseError(message: "unterminated < > cell", offset: start)
        }

        if DTLexer.isIdentStart(c) || c == UInt8(ascii: "#") {
            pos += 1
            while pos < bytes.count, DTLexer.isIdentContinue(bytes[pos]) { pos += 1 }
            return DTToken(kind: .identifier(text(start..<pos)), range: start..<pos)
        }

        if c >= 0x30 && c <= 0x39 {
            pos += 1
            while pos < bytes.count, DTLexer.isIdentContinue(bytes[pos]) { pos += 1 }
            return DTToken(kind: .identifier(text(start..<pos)), range: start..<pos)
        }

        pos += 1
        return DTToken(kind: .punct(c), range: start..<pos)
    }
}
