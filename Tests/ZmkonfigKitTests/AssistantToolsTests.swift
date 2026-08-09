import Foundation
import Testing

@testable import ZmkonfigKit

// MARK: - Shared scaffolding

/// The pieces every suite here needs: a call to hand to a tool, and a snapshot
/// of the fixture keymap to answer it from.
enum AssistantFixture {
    static func call(
        _ name: String, _ input: [String: JSONValue] = [:]
    ) -> ClaudeToolUse {
        ClaudeToolUse(id: "toolu_test", name: name, input: .object(input))
    }

    static func context(
        keymap: KeymapFile? = nil,
        hasUnsavedEdits: Bool = false,
        keymapRelativePath: String? = "config/cradio.keymap"
    ) throws -> KeymapContext {
        let file = try keymap ?? Fixture.cradio()
        return KeymapContext(
            keymap: file,
            keycodes: [],
            layout: try Fixture.cradioLayout(),
            behaviors: BehaviorIndex(stock: [], keymap: file),
            hasUnsavedEdits: hasUnsavedEdits,
            keymapRelativePath: keymapRelativePath
        )
    }
}

// MARK: - behaviorProperties

@Suite("Assistant behavior properties")
struct AssistantBehaviorPropertiesTests {
    /// A hold-tap's properties in source order, as `BehaviorReader` would hand
    /// them over.
    private static let existing = [
        BehaviorProperty(name: "flavor", value: .string("tap-preferred")),
        BehaviorProperty(name: "tapping-term-ms", value: .integer(280)),
    ]

    private static func merged(
        _ raw: [String: JSONValue], into existing: [BehaviorProperty] = existing
    ) throws -> [BehaviorProperty] {
        switch AssistantTools.behaviorProperties(raw, merging: existing) {
        case .success(let properties): return properties
        case .failure(let reason): Issue.record("expected success, got: \(reason)"); throw CancellationError()
        }
    }

    private static func rejection(
        _ raw: [String: JSONValue], into existing: [BehaviorProperty] = existing
    ) throws -> String {
        switch AssistantTools.behaviorProperties(raw, merging: existing) {
        case .success(let properties):
            Issue.record("expected a failure, got: \(properties)")
            throw CancellationError()
        case .failure(let reason): return reason
        }
    }

    @Test("Each JSON shape becomes the devicetree value it writes as")
    func shapes() throws {
        let properties = try Self.merged(
            [
                "tapping-term-ms": .number(280),
                "flavor": .string("balanced"),
                "hold-trigger-on-release": .bool(true),
                "hold-trigger-key-positions": .array([.number(0), .number(1), .number(2)]),
                "wrapped": .array([.string("&kp"), .string("&mo")]),
                "macro-cell": .array([.string("KEYS_L"), .string("THUMBS")]),
            ],
            into: []
        )
        let byName = Dictionary(properties.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(byName["tapping-term-ms"] == .integer(280))
        #expect(byName["flavor"] == .string("balanced"))
        #expect(byName["hold-trigger-on-release"] == .flag)
        #expect(byName["hold-trigger-key-positions"] == .integers([0, 1, 2]))
        #expect(byName["wrapped"] == .references(["&kp", "&mo"]))
        #expect(byName["macro-cell"] == .tokens(["KEYS_L", "THUMBS"]))
    }

    @Test("Merging leaves untouched properties alone and changes only what was named")
    func mergeKeepsTheRest() throws {
        let properties = try Self.merged(["tapping-term-ms": .number(200)])
        #expect(properties.map(\.name) == ["flavor", "tapping-term-ms"])
        #expect(properties[0].value == .string("tap-preferred"))
        #expect(properties[1].value == .integer(200))
    }

    @Test("New properties are appended after the existing ones, alphabetically")
    func newPropertiesAppendInOrder() throws {
        let properties = try Self.merged([
            "quick-tap-ms": .number(175),
            "retro-tap": .bool(true),
            "hold-trigger-on-release": .bool(true),
        ])
        #expect(
            properties.map(\.name) == [
                "flavor", "tapping-term-ms",
                "hold-trigger-on-release", "quick-tap-ms", "retro-tap",
            ]
        )
    }

    @Test("A null value deletes an existing property")
    func nullDeletes() throws {
        let properties = try Self.merged(["flavor": .null])
        #expect(properties.map(\.name) == ["tapping-term-ms"])
    }

    @Test("A null value for a property that is not set changes nothing")
    func nullOnAbsentPropertyIsANoOp() throws {
        #expect(try Self.merged(["quick-tap-ms": .null]) == Self.existing)
    }

    @Test("False is refused, because a flag property is written or absent")
    func falseIsRefused() throws {
        let reason = try Self.rejection(["hold-trigger-on-release": .bool(false)])
        #expect(reason.contains("`null`"))
        #expect(reason.contains("hold-trigger-on-release"))
    }

    @Test(
        "The properties the kind owns cannot be set through `properties`",
        arguments: [
            ("compatible", JSONValue.string("zmk,behavior-hold-tap")),
            ("#binding-cells", .number(2)),
            ("bindings", .array([.string("&kp"), .string("&kp")])),
        ]
    )
    func kindOwnedPropertiesAreRefused(name: String, value: JSONValue) throws {
        let reason = try Self.rejection([name: value])
        #expect(reason.contains("`\(name)` is not set through `properties`"))
    }

    @Test("A value with no devicetree spelling is refused and named")
    func unwritableValueIsRefused() throws {
        let reason = try Self.rejection(["odd": .object(["a": .number(1)])])
        #expect(reason.contains("`odd` cannot be written"))
    }
}

// MARK: - behaviorValue

@Suite("Assistant behavior values")
struct AssistantBehaviorValueTests {
    /// One JSON value and the devicetree value it must discriminate to, or nil
    /// where it has no devicetree spelling at all.
    struct Discrimination: Sendable, CustomTestStringConvertible {
        let label: String
        let json: JSONValue
        let value: BehaviorValue?

        var testDescription: String { label }
    }

    static let cases: [Discrimination] = [
        .init(label: "integer", json: .number(280), value: .integer(280)),
        .init(label: "whole float", json: .number(3.0), value: .integer(3)),
        .init(label: "negative integer", json: .number(-1), value: .integer(-1)),
        .init(label: "string", json: .string("balanced"), value: .string("balanced")),
        .init(label: "true", json: .bool(true), value: .flag),
        .init(
            label: "all-integer array",
            json: .array([.number(0), .number(1)]),
            value: .integers([0, 1])
        ),
        .init(
            label: "all-reference array",
            json: .array([.string("&kp"), .string("&mo 2")]),
            value: .references(["&kp", "&mo 2"])
        ),
        .init(
            label: "other string array",
            json: .array([.string("KEYS_L"), .string("THUMBS")]),
            value: .tokens(["KEYS_L", "THUMBS"])
        ),
        .init(
            label: "array of one reference and one token is tokens",
            json: .array([.string("&kp"), .string("THUMBS")]),
            value: .tokens(["&kp", "THUMBS"])
        ),
        .init(label: "empty array", json: .array([]), value: nil),
        .init(
            label: "mixed array",
            json: .array([.number(1), .string("THUMBS")]),
            value: nil
        ),
        .init(label: "false", json: .bool(false), value: nil),
        .init(label: "null", json: .null, value: nil),
        .init(label: "nested object", json: .object(["a": .number(1)]), value: nil),
        .init(label: "non-integral number", json: .number(1.5), value: nil),
        .init(
            label: "array holding an object",
            json: .array([.object(["a": .number(1)])]),
            value: nil
        ),
    ]

    @Test("A JSON value becomes the devicetree value it can be written as", arguments: cases)
    func discriminates(_ discrimination: Discrimination) {
        #expect(AssistantTools.behaviorValue(discrimination.json) == discrimination.value)
    }
}

// MARK: - read_keymap_source

@Suite("Assistant keymap source paging")
struct AssistantKeymapSourceTests {
    /// The fixture with enough trailing comment to force a clip.
    ///
    /// `sourceCharacterLimit` is a `static let`, so the only way to exercise the
    /// boundary is a keymap that actually exceeds it. A comment block is the
    /// cheapest thing to add that the parser keeps verbatim and no other tool
    /// looks at.
    static func longKeymap() throws -> KeymapFile {
        var text = try Fixture.cradioText()
        let filler = String(repeating: "x", count: 100)
        while text.count < AssistantTools.sourceCharacterLimit + 5_000 {
            text += "// \(filler)\n"
        }
        return try KeymapFile(source: Data(text.utf8))
    }

    static func sourceLines(of keymap: KeymapFile) -> [String] {
        String(decoding: keymap.document.source, as: UTF8.self).components(separatedBy: "\n")
    }

    /// A tool answer split back into the sentence at the top and the file text
    /// under it. The header never contains a blank line, so the first one is the
    /// separator.
    static func split(_ content: String) throws -> (header: String, body: [String]) {
        let separator = try #require(content.range(of: "\n\n"), "no header in the answer")
        return (
            String(content[content.startIndex..<separator.lowerBound]),
            String(content[separator.upperBound...]).components(separatedBy: "\n")
        )
    }

    static func read(_ input: [String: JSONValue], context: KeymapContext) -> ClaudeToolResult {
        AssistantTools.run(
            AssistantFixture.call(AssistantTools.Name.readKeymapSource, input),
            context: context,
            staged: []
        ).result
    }

    @Test("A file under the limit is shown whole, with no paging sentence")
    func shortFileIsWhole() throws {
        let context = try AssistantFixture.context()
        let result = Self.read([:], context: context)
        #expect(!result.isError)
        let (header, body) = try Self.split(result.content)
        #expect(header.contains("`config/cradio.keymap`"))
        #expect(!header.contains("from_line"))
        #expect(body == Self.sourceLines(of: try #require(context.keymap)))
    }

    @Test("A long file's first page ends on a line boundary and says how to ask for the next")
    func firstPageClipsOnALineBoundary() throws {
        let keymap = try Self.longKeymap()
        let lines = Self.sourceLines(of: keymap)
        let context = try AssistantFixture.context(keymap: keymap)

        let result = Self.read([:], context: context)
        #expect(!result.isError)
        let (header, body) = try Self.split(result.content)

        #expect(body.count < lines.count, "the fixture was not long enough to clip")
        #expect(body == Array(lines.prefix(body.count)), "a line was altered or lost")
        #expect(header.contains("showing lines 1 to \(body.count)"))
        #expect(header.contains("from_line: \(body.count + 1)"))

        // The clip is as late as it can be: what was shown fits, and one more
        // line would not.
        let shown = body.reduce(0) { $0 + $1.count + 1 }
        #expect(shown <= AssistantTools.sourceCharacterLimit)
        #expect(shown + lines[body.count].count + 1 > AssistantTools.sourceCharacterLimit)
    }

    @Test("from_line resumes exactly where the previous page stopped")
    func pagingLosesAndRepeatsNothing() throws {
        let keymap = try Self.longKeymap()
        let lines = Self.sourceLines(of: keymap)
        let context = try AssistantFixture.context(keymap: keymap)

        var page = try Self.split(Self.read([:], context: context).content)
        var seen = page.body
        var guardrail = 0
        while page.header.contains("from_line: ") {
            guardrail += 1
            #expect(guardrail < 10, "the file should not need this many pages")
            if guardrail >= 10 { break }

            let next = seen.count + 1
            #expect(page.header.contains("from_line: \(next)"))
            let result = Self.read(["from_line": .number(Double(next))], context: context)
            #expect(!result.isError)
            page = try Self.split(result.content)
            #expect(page.header.contains("showing lines \(next) to \(next + page.body.count - 1)"))
            seen += page.body
        }
        #expect(seen == lines, "paging did not reproduce the file exactly")
    }

    @Test("from_line: 0 is rejected, because lines count from 1")
    func zeroIsRejected() throws {
        let result = Self.read(["from_line": .number(0)], context: try AssistantFixture.context())
        #expect(result.isError)
        #expect(result.content.contains("`from_line`"))
        #expect(result.content.contains("counts from 1"))
    }

    @Test("A from_line past the end is rejected and says how many lines there are")
    func pastTheEndIsRejected() throws {
        let context = try AssistantFixture.context()
        let count = Self.sourceLines(of: try #require(context.keymap)).count
        let result = Self.read(["from_line": .number(Double(count + 1))], context: context)
        #expect(result.isError)
        #expect(result.content.contains("`from_line` is \(count + 1)"))
        #expect(result.content.contains("\(count) lines"))
    }

    @Test("The last line of the file is a valid from_line")
    func theLastLineIsReadable() throws {
        let context = try AssistantFixture.context()
        let lines = Self.sourceLines(of: try #require(context.keymap))
        let result = Self.read(["from_line": .number(Double(lines.count))], context: context)
        #expect(!result.isError)
        let (_, body) = try Self.split(result.content)
        #expect(body == [lines[lines.count - 1]])
    }

    @Test("The unsaved-edits note appears only when there are unsaved edits")
    func unsavedNote() throws {
        let clean = Self.read([:], context: try AssistantFixture.context())
        #expect(!clean.content.contains("not yet saved"))

        let dirty = Self.read([:], context: try AssistantFixture.context(hasUnsavedEdits: true))
        #expect(dirty.content.contains("not yet saved"))
    }

    @Test("With no keymap open the answer is an error, not an empty file")
    func noKeymap() {
        let result = Self.read([:], context: KeymapContext())
        #expect(result.isError)
        #expect(result.content.contains("no keymap is open"))
    }
}

// MARK: - Argument reading

@Suite("Assistant tool arguments")
struct AssistantArgumentTests {
    /// An ``AssistantTools.ArgumentRead`` flattened so cases of different value
    /// types can sit in one table.
    enum Reading: Equatable {
        case value(String)
        case absent
        case failure(String)
    }

    static func flatten<Value>(_ read: AssistantTools.ArgumentRead<Value>) -> Reading {
        switch read {
        case .value(let value): .value("\(value)")
        case .absent: .absent
        case .failure(let outcome): .failure(outcome.result.content)
        }
    }

    /// One argument, as one tool call would carry it, and how it must read.
    struct ArgumentCase: Sendable, CustomTestStringConvertible {
        let label: String
        /// nil means the key is not in the call at all.
        let given: JSONValue?
        let reader: Reader
        let expect: Expectation

        var testDescription: String { label }

        enum Reader: Sendable { case integer, string, array, object }

        enum Expectation: Sendable {
            case value(String)
            case absent
            /// A failure whose message contains every one of these.
            case failure([String])
        }
    }

    static let argumentCases: [ArgumentCase] = [
        .init(label: "an absent integer", given: nil, reader: .integer, expect: .absent),
        .init(label: "an absent string", given: nil, reader: .string, expect: .absent),
        .init(label: "an absent array", given: nil, reader: .array, expect: .absent),
        .init(label: "an absent object", given: nil, reader: .object, expect: .absent),

        // A model filling an optional parameter with `null` means "I am not
        // sending this", and must not be told off for a value it never meant.
        .init(label: "an explicit null integer", given: .null, reader: .integer, expect: .absent),
        .init(label: "an explicit null string", given: .null, reader: .string, expect: .absent),
        .init(label: "an explicit null array", given: .null, reader: .array, expect: .absent),
        .init(label: "an explicit null object", given: .null, reader: .object, expect: .absent),

        .init(label: "an integer", given: .number(280), reader: .integer, expect: .value("280")),
        .init(label: "a whole float", given: .number(3.0), reader: .integer, expect: .value("3")),
        .init(label: "a string", given: .string("Nav"), reader: .string, expect: .value("Nav")),
        .init(label: "an empty string", given: .string(""), reader: .string, expect: .value("")),

        .init(
            label: "a string where an integer was asked for",
            given: .string("280"),
            reader: .integer,
            expect: .failure(["`thing`", "must be an integer", "\"280\""])
        ),
        .init(
            label: "a non-integral number",
            given: .number(1.5),
            reader: .integer,
            expect: .failure(["`thing`", "must be an integer", "1.5"])
        ),
        .init(
            label: "a boolean where an integer was asked for",
            given: .bool(true),
            reader: .integer,
            expect: .failure(["`thing`", "must be an integer"])
        ),
        .init(
            label: "an integer where a string was asked for",
            given: .number(2),
            reader: .string,
            expect: .failure(["`thing`", "must be a string"])
        ),
        .init(
            label: "a string where an array was asked for",
            given: .string("&kp A"),
            reader: .array,
            expect: .failure(["`thing`", "an array of integers"])
        ),
        .init(
            label: "an array where an object was asked for",
            given: .array([.number(1)]),
            reader: .object,
            expect: .failure(["`thing`", "an object of property names and values"])
        ),
    ]

    @Test("An optional argument reads as present, absent or wrong", arguments: argumentCases)
    func reads(_ testCase: ArgumentCase) {
        let call = AssistantFixture.call(
            "any", testCase.given.map { ["thing": $0] } ?? [:]
        )
        let reading: Reading
        switch testCase.reader {
        case .integer: reading = Self.flatten(AssistantTools.integerArgument(call, "thing"))
        case .string: reading = Self.flatten(AssistantTools.stringArgument(call, "thing"))
        case .array:
            reading = Self.flatten(
                AssistantTools.arrayArgument(call, "thing", "an array of integers")
            )
        case .object:
            reading = Self.flatten(
                AssistantTools.objectArgument(call, "thing", "an object of property names and values")
            )
        }

        switch testCase.expect {
        case .value(let expected): #expect(reading == .value(expected))
        case .absent: #expect(reading == .absent)
        case .failure(let fragments):
            guard case .failure(let message) = reading else {
                Issue.record("expected a failure, got \(reading)")
                return
            }
            for fragment in fragments {
                #expect(message.contains(fragment), "\(message) does not mention \(fragment)")
            }
        }
    }

    @Test("A failing argument comes back as an error result, not a thrown error")
    func failureIsAToolError() {
        let call = AssistantFixture.call("any", ["thing": .string("nope")])
        guard case .failure(let outcome) = AssistantTools.integerArgument(call, "thing") else {
            Issue.record("expected a failure")
            return
        }
        #expect(outcome.result.isError)
        #expect(outcome.result.toolUseID == call.id)
        #expect(outcome.staged == nil)
        #expect(outcome.unstage == nil)
    }

    @Test("A reader of its own decides what counts, and the message says what was wanted")
    func customReader() {
        func positive(_ call: ClaudeToolUse) -> Reading {
            Self.flatten(
                AssistantTools.argument(call, "thing", "a positive integer") { json in
                    json.intValue.flatMap { $0 > 0 ? $0 : nil }
                }
            )
        }
        #expect(positive(AssistantFixture.call("any", ["thing": .number(3)])) == .value("3"))
        #expect(positive(AssistantFixture.call("any")) == .absent)

        guard case .failure(let message) = positive(AssistantFixture.call("any", ["thing": .number(-1)]))
        else {
            Issue.record("expected -1 to be refused")
            return
        }
        #expect(message.contains("`thing` must be a positive integer"))
        #expect(message.contains("-1"))
    }

    @Test("field treats an explicit null as absent and anything else as present")
    func fieldReadsNullAsAbsent() {
        let call = AssistantFixture.call(
            "any", ["nothing": .null, "something": .bool(false)]
        )
        #expect(AssistantTools.field(call, "nothing") == nil)
        #expect(AssistantTools.field(call, "missing") == nil)
        #expect(AssistantTools.field(call, "something") == .bool(false))
    }

    // MARK: Rejections through `run`

    /// One whole tool call that must be refused, and what the refusal has to
    /// name so the model can fix it.
    struct RejectionCase: Sendable, CustomTestStringConvertible {
        let label: String
        let tool: String
        let input: [String: JSONValue]
        let mentions: [String]

        var testDescription: String { label }
    }

    static let rejectionCases: [RejectionCase] = [
        .init(
            label: "read_layer with no layer",
            tool: AssistantTools.Name.readLayer,
            input: [:],
            mentions: ["`layer` is required", "an integer"]
        ),
        .init(
            label: "read_layer with a string layer",
            tool: AssistantTools.Name.readLayer,
            input: ["layer": .string("1")],
            mentions: ["`layer` must be an integer", "\"1\""]
        ),
        .init(
            label: "set_binding with a string layer",
            tool: AssistantTools.Name.setBinding,
            input: ["layer": .string("0"), "key_position": .number(0), "binding": .string("&kp A")],
            mentions: ["`layer` must be an integer"]
        ),
        .init(
            label: "set_binding with a fractional key position",
            tool: AssistantTools.Name.setBinding,
            input: ["layer": .number(0), "key_position": .number(1.5), "binding": .string("&kp A")],
            mentions: ["`key_position` must be an integer", "1.5"]
        ),
        .init(
            label: "set_binding with no binding",
            tool: AssistantTools.Name.setBinding,
            input: ["layer": .number(0), "key_position": .number(0)],
            mentions: ["`binding` is required"]
        ),
        .init(
            label: "set_binding with two bindings in one key",
            tool: AssistantTools.Name.setBinding,
            input: ["layer": .number(0), "key_position": .number(0), "binding": .string("&kp A &kp B")],
            mentions: ["is not one ZMK binding"]
        ),
        .init(
            label: "set_combo with a one-element key_positions",
            tool: AssistantTools.Name.setCombo,
            input: ["name": .string("escape-combo"), "key_positions": .array([.number(1)])],
            mentions: ["key positions", "at least two"]
        ),
        .init(
            label: "set_combo with a non-integer key position",
            tool: AssistantTools.Name.setCombo,
            input: [
                "name": .string("escape-combo"),
                "key_positions": .array([.number(1), .string("3")]),
            ],
            mentions: ["`key_positions`", "must be an integer"]
        ),
        .init(
            label: "set_combo with key_positions that is not an array",
            tool: AssistantTools.Name.setCombo,
            input: ["name": .string("escape-combo"), "key_positions": .number(3)],
            mentions: ["`key_positions`", "an array of integers"]
        ),
        .init(
            label: "set_combo with a string timeout",
            tool: AssistantTools.Name.setCombo,
            input: ["name": .string("escape-combo"), "timeout_ms": .string("fast")],
            mentions: ["`timeout_ms` must be an integer"]
        ),
        .init(
            label: "set_combo with no name",
            tool: AssistantTools.Name.setCombo,
            input: ["binding": .string("&kp ESC")],
            mentions: ["`name` is required", "a non-empty string"]
        ),
        .init(
            label: "rename_layer with an empty name",
            tool: AssistantTools.Name.renameLayer,
            input: ["layer": .number(1), "name": .string("   ")],
            mentions: ["display name"]
        ),
        .init(
            label: "rename_layer with no name",
            tool: AssistantTools.Name.renameLayer,
            input: ["layer": .number(1)],
            mentions: ["`name` is required"]
        ),
        .init(
            label: "rename_layer with a number for a name",
            tool: AssistantTools.Name.renameLayer,
            input: ["layer": .number(1), "name": .number(2)],
            mentions: ["`name` must be a string", "2"]
        ),
        .init(
            label: "find_keycodes with a blank query",
            tool: AssistantTools.Name.findKeycodes,
            input: ["query": .string("  ")],
            mentions: ["`query`", "a non-empty string"]
        ),
        .init(
            label: "set_behavior with a numeric label",
            tool: AssistantTools.Name.setBehavior,
            input: ["label": .number(42)],
            mentions: ["`label`", "a non-empty string"]
        ),
        .init(
            label: "set_macro with a fractional parameter count",
            tool: AssistantTools.Name.setMacro,
            input: ["label": .string("email"), "parameters": .number(0.5)],
            mentions: ["`parameters` must be an integer"]
        ),
        .init(
            label: "add_layer with bindings that are not an array",
            tool: AssistantTools.Name.addLayer,
            input: ["name": .string("Nav"), "bindings": .string("&trans")],
            mentions: ["`bindings`", "an array of strings"]
        ),
        .init(
            label: "remove_layer with a layer that does not exist",
            tool: AssistantTools.Name.removeLayer,
            input: ["layer": .number(99)],
            mentions: ["layer 99 does not exist"]
        ),
        .init(
            label: "a tool nothing declares",
            tool: "set_everything",
            input: [:],
            mentions: ["there is no tool called `set_everything`"]
        ),
    ]

    @Test("A call with a bad argument is refused and the argument is named", arguments: rejectionCases)
    func rejects(_ testCase: RejectionCase) throws {
        let outcome = AssistantTools.run(
            AssistantFixture.call(testCase.tool, testCase.input),
            context: try AssistantFixture.context(),
            staged: []
        )
        #expect(outcome.result.isError, "\(testCase.label) was accepted: \(outcome.result.content)")
        #expect(outcome.staged == nil, "a refused call must stage nothing")
        for fragment in testCase.mentions {
            #expect(
                outcome.result.content.contains(fragment),
                "\(outcome.result.content) does not mention \(fragment)"
            )
        }
    }
}
