import Foundation

/// A parsed devicetree node.
///
/// Every node and property carries byte ranges into the original source. That
/// is the whole point of this parser: the editor rewrites a handful of spans
/// and copies every other byte through untouched, so comments, preprocessor
/// directives and hand-tuned formatting all survive.
public final class DTNode: Sendable {
    /// The label before the colon, `hml` in `hml: hold_tap_left { }`.
    public let label: String?
    /// The node name: `hold_tap_left`, `keymap`, `&mt`, or `/` for a root.
    public let name: String
    public let properties: [DTProperty]
    public let children: [DTNode]
    /// The whole node, from the label (or name) through the trailing `;`.
    public let range: Range<Int>
    /// The bytes between the braces, exclusive.
    public let bodyRange: Range<Int>

    init(
        label: String?,
        name: String,
        properties: [DTProperty],
        children: [DTNode],
        range: Range<Int>,
        bodyRange: Range<Int>
    ) {
        self.label = label
        self.name = name
        self.properties = properties
        self.children = children
        self.range = range
        self.bodyRange = bodyRange
    }

    public func property(_ name: String) -> DTProperty? {
        properties.first { $0.name == name }
    }

    /// The string value of the `compatible` property, if it has one.
    public var compatible: String? {
        if case .string(let value) = property("compatible")?.value { return value }
        return nil
    }
}

public struct DTProperty: Sendable, Equatable {
    public let name: String
    /// The whole `name = value;`, including the semicolon.
    public let range: Range<Int>
    /// Just the value text, from the first value token to the last. `nil` for
    /// boolean properties, which have no value at all.
    public let valueRange: Range<Int>?
    public let value: DTValue
}

public enum DTValue: Sendable, Equatable {
    /// A boolean property: `hold-trigger-on-release;`.
    case none
    /// One or more `<...>` groups: `bindings = <&kp>, <&kp>;` yields two.
    case cells([DTCell])
    case string(String)
    /// A bare phandle: `foo = &bar;`.
    case reference(String)
    /// Anything else, kept as source text so it can be written back verbatim.
    case other(String)

    /// The text inside each `<...>`, or `nil` if this is not a cell value.
    public var cellTexts: [String]? {
        if case .cells(let cells) = self { return cells.map(\.text) }
        return nil
    }
}

/// One `<...>` group. `innerRange` covers the bytes between the brackets.
public struct DTCell: Sendable, Equatable {
    public let innerRange: Range<Int>
    public let text: String
}

/// Recursive-descent parser over ``DTLexer``.
struct DTParser {
    private let bytes: [UInt8]
    private let tokens: [DTToken]
    private var index = 0

    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let semicolon = UInt8(ascii: ";")
    private static let colon = UInt8(ascii: ":")
    private static let equals = UInt8(ascii: "=")
    private static let comma = UInt8(ascii: ",")
    private static let ampersand = UInt8(ascii: "&")
    private static let slash = UInt8(ascii: "/")

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        var lexer = DTLexer(bytes: bytes)
        var collected: [DTToken] = []
        while let token = try lexer.next() { collected.append(token) }
        self.tokens = collected
    }

    private var current: DTToken? { index < tokens.count ? tokens[index] : nil }

    private func peek(_ offset: Int) -> DTToken? {
        let i = index + offset
        return i < tokens.count ? tokens[i] : nil
    }

    private func text(_ range: Range<Int>) -> String {
        bytes.text(range)
    }

    private var endOffset: Int { tokens.last?.range.upperBound ?? bytes.count }

    mutating func parseRoots() throws -> [DTNode] {
        var roots: [DTNode] = []
        while let token = current {
            // Stray semicolons between top-level blocks are legal and common.
            if token.punct == Self.semicolon {
                index += 1
                continue
            }
            roots.append(try parseNode())
        }
        return roots
    }

    private mutating func parseNode() throws -> DTNode {
        guard let first = current else {
            throw DTParseError(message: "unexpected end of file", offset: endOffset)
        }
        let start = first.range.lowerBound

        var label: String?
        if let identifier = first.identifier, peek(1)?.punct == Self.colon {
            label = identifier
            index += 2
        }

        let name = try parseNodeName()

        guard let brace = current, brace.punct == Self.openBrace else {
            throw DTParseError(
                message: "expected `{` for node `\(name)`",
                offset: current?.range.lowerBound ?? endOffset
            )
        }
        index += 1

        var properties: [DTProperty] = []
        var children: [DTNode] = []
        var closing: DTToken?
        while let token = current {
            if token.punct == Self.closeBrace {
                closing = token
                index += 1
                break
            }
            if token.punct == Self.semicolon {
                index += 1
                continue
            }
            if startsNode() {
                children.append(try parseNode())
            } else {
                properties.append(try parseProperty())
            }
        }

        guard let close = closing else {
            throw DTParseError(message: "unterminated node `\(name)`", offset: start)
        }

        var end = close.range.upperBound
        if let semi = current, semi.punct == Self.semicolon {
            end = semi.range.upperBound
            index += 1
        }

        return DTNode(
            label: label,
            name: name,
            properties: properties,
            children: children,
            range: start..<end,
            bodyRange: brace.range.upperBound..<close.range.lowerBound
        )
    }

    private mutating func parseNodeName() throws -> String {
        guard let token = current else {
            throw DTParseError(message: "expected a node name", offset: endOffset)
        }
        if token.punct == Self.slash {
            index += 1
            return "/"
        }
        if token.punct == Self.ampersand {
            index += 1
            guard let identifier = current?.identifier else {
                throw DTParseError(message: "expected a label after `&`", offset: token.range.lowerBound)
            }
            index += 1
            return "&" + identifier
        }
        if let identifier = token.identifier {
            index += 1
            return identifier
        }
        throw DTParseError(message: "expected a node name", offset: token.range.lowerBound)
    }

    /// Distinguishes `foo { }` and `bar: foo { }` and `&foo { }` from `foo = <1>;`.
    private func startsNode() -> Bool {
        guard let token = current else { return false }
        if token.punct == Self.ampersand || token.punct == Self.slash { return true }
        guard token.identifier != nil else { return false }
        let next = peek(1)?.punct
        return next == Self.colon || next == Self.openBrace
    }

    private mutating func parseProperty() throws -> DTProperty {
        guard let nameToken = current, let name = nameToken.identifier else {
            throw DTParseError(
                message: "expected a property name",
                offset: current?.range.lowerBound ?? endOffset
            )
        }
        index += 1
        let start = nameToken.range.lowerBound

        if let token = current, token.punct == Self.semicolon {
            index += 1
            return DTProperty(
                name: name, range: start..<token.range.upperBound, valueRange: nil, value: .none
            )
        }

        guard let equalsToken = current, equalsToken.punct == Self.equals else {
            throw DTParseError(
                message: "expected `=` or `;` after property `\(name)`",
                offset: current?.range.lowerBound ?? endOffset
            )
        }
        index += 1

        var valueTokens: [DTToken] = []
        var end = equalsToken.range.upperBound
        var terminated = false
        while let token = current {
            if token.punct == Self.semicolon {
                end = token.range.upperBound
                index += 1
                terminated = true
                break
            }
            valueTokens.append(token)
            index += 1
        }
        guard terminated else {
            throw DTParseError(message: "unterminated property `\(name)`", offset: start)
        }

        let valueRange = valueTokens.isEmpty
            ? nil
            : valueTokens[0].range.lowerBound..<valueTokens[valueTokens.count - 1].range.upperBound

        return DTProperty(
            name: name, range: start..<end, valueRange: valueRange, value: value(of: valueTokens)
        )
    }

    private func value(of valueTokens: [DTToken]) -> DTValue {
        // Commas only separate values; they carry no meaning of their own.
        let significant = valueTokens.filter { $0.punct != Self.comma }
        guard !significant.isEmpty else { return .none }

        var cells: [DTCell] = []
        for token in significant {
            guard case .cell(let inner) = token.kind else {
                cells.removeAll()
                break
            }
            cells.append(DTCell(innerRange: inner, text: text(inner)))
        }
        if !cells.isEmpty { return .cells(cells) }

        if significant.count == 1, case .string(let value) = significant[0].kind {
            return .string(value)
        }
        if significant.count == 2, significant[0].punct == Self.ampersand,
           let identifier = significant[1].identifier {
            return .reference("&" + identifier)
        }

        let span = significant[0].range.lowerBound..<significant[significant.count - 1].range.upperBound
        return .other(text(span))
    }
}
