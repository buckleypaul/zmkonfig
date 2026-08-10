import Foundation
import Testing

@testable import ZmkonfigKit

/// The `/* zmkonfig: … */` description a behavior node carries.
///
/// Two things are being pinned here and they matter for different reasons. The
/// splicing tests keep the promise the whole editor rests on — a note is one
/// comment's worth of bytes and touching it moves nothing else. The sanitising
/// tests keep the promise that makes it safe to put a *generated* description
/// in the file at all: nothing that goes through ``BehaviorNote/sanitized(_:)``
/// can close the comment it is written inside.
@Suite("Behavior notes")
struct BehaviorNoteTests {
    static let withNote = """
        / {
            behaviors {
                hml: hold_tap_left {
                    /* zmkonfig: Home-row mod for the left hand. */
                    compatible = "zmk,behavior-hold-tap";
                    #binding-cells = <2>;
                    bindings = <&kp>, <&kp>;
                    tapping-term-ms = <280>;
                };

                plain: no_note {
                    compatible = "zmk,behavior-sticky-key";
                    #binding-cells = <1>;
                    bindings = <&kp>;
                    release-after-ms = <1000>;
                };
            };

            keymap {
                compatible = "zmk,keymap";

                base {
                    bindings = <
        &kp A  &kp B
                    >;
                };
            };
        };

        """

    static let twoKeys = BehaviorEditingTests.twoKeys

    private static func file() throws -> KeymapFile {
        try KeymapFile(source: Data(withNote.utf8))
    }

    private static func behavior(_ keymap: KeymapFile, _ label: String) throws -> KeymapBehavior {
        try #require(keymap.behaviors.first { $0.label == label }, "no behavior &\(label)")
    }

    private static func write(_ keymap: KeymapFile) throws -> String {
        String(decoding: try keymap.serialized(layout: twoKeys), as: UTF8.self)
    }

    // MARK: Reading

    @Test("A marked comment is read as the behavior's note")
    func read() throws {
        let keymap = try Self.file()
        #expect(try Self.behavior(keymap, "hml").note == "Home-row mod for the left hand.")
        #expect(try Self.behavior(keymap, "plain").note == nil)
    }

    @Test("A wrapped note reads back as one paragraph")
    func unwrapping() throws {
        // How the lines were broken is this file's doing, so it is this file's
        // to undo — a note that came back with the newlines still in it would
        // re-wrap differently on every save.
        let source = Self.withNote.replacingOccurrences(
            of: "/* zmkonfig: Home-row mod for the left hand. */",
            with: """
                /* zmkonfig: Home-row mod for the left
                       hand. Holds a mod, taps the letter. */
                """
        )
        let keymap = try KeymapFile(source: Data(source.utf8))
        #expect(try Self.behavior(keymap, "hml").note
            == "Home-row mod for the left hand. Holds a mod, taps the letter.")
    }

    @Test("An unmarked comment is somebody else's and is left alone")
    func markerIsRequired() throws {
        // People comment inside behavior nodes already. Claiming one of those
        // as the description would put a note about `tapping-term-ms` under the
        // behavior picker as if it explained the whole node — and worse, the
        // next save would rewrite it.
        let source = Self.withNote.replacingOccurrences(
            of: "/* zmkonfig: Home-row mod for the left hand. */",
            with: "/* 280 felt too slow at speed */"
        )
        var keymap = try KeymapFile(source: Data(source.utf8))
        #expect(try Self.behavior(keymap, "hml").note == nil)

        var edited = try Self.behavior(keymap, "hml")
        edited.note = "Home-row mod."
        try keymap.upsertBehavior(edited)
        let output = try Self.write(keymap)
        #expect(output.contains("/* 280 felt too slow at speed */"))
        #expect(output.contains("/* zmkonfig: Home-row mod. */"))
    }

    // MARK: Splicing

    @Test("A keymap with notes round trips byte for byte")
    func roundTrip() throws {
        let keymap = try Self.file()
        #expect(try Self.write(keymap) == Self.withNote)
    }

    @Test("Adding a note writes one comment as the node's first line")
    func add() throws {
        var keymap = try Self.file()
        var plain = try Self.behavior(keymap, "plain")
        plain.note = "One-shot shift for the right hand."
        try keymap.upsertBehavior(plain)

        // Compared whole rather than by `contains`, so "nothing else moved" is
        // actually asserted rather than assumed.
        #expect(try Self.write(keymap) == Self.withNote.replacingOccurrences(
            of: "        plain: no_note {\n",
            with: "        plain: no_note {\n"
                + "            /* zmkonfig: One-shot shift for the right hand. */\n"
        ))
    }

    @Test("Changing a note rewrites the comment and nothing around it")
    func change() throws {
        var keymap = try Self.file()
        var hml = try Self.behavior(keymap, "hml")
        hml.note = "Left-hand home-row mod."
        try keymap.upsertBehavior(hml)

        let output = try Self.write(keymap)
        let differences = Fixture.differingLines(Self.withNote, output)
        #expect(differences.count == 1)
        #expect(differences.first?.1
            == "            /* zmkonfig: Left-hand home-row mod. */")
    }

    @Test("Clearing a note takes the whole line with it")
    func remove() throws {
        var keymap = try Self.file()
        var hml = try Self.behavior(keymap, "hml")
        hml.note = nil
        try keymap.upsertBehavior(hml)

        // The whole line goes: one left holding nothing but its indentation is
        // not what "no description" looks like.
        #expect(try Self.write(keymap) == Self.withNote.replacingOccurrences(
            of: "            /* zmkonfig: Home-row mod for the left hand. */\n",
            with: ""
        ))
    }

    @Test("A note emptied to whitespace removes the comment rather than writing an empty one")
    func emptiedNote() throws {
        var keymap = try Self.file()
        var hml = try Self.behavior(keymap, "hml")
        hml.note = "   \n  "
        try keymap.upsertBehavior(hml)
        #expect(!(try Self.write(keymap)).contains("zmkonfig:"))
    }

    @Test("A new behavior carries its note into the node it is written as")
    func newBehavior() throws {
        var keymap = try Self.file()
        try keymap.upsertBehavior(KeymapBehavior(
            nodeName: "tap_dance_x",
            label: "td",
            compatible: BehaviorKind.tapDance.compatible,
            bindingCells: 0,
            bindings: ["&kp A", "&kp B"],
            properties: [],
            note: "Tap for A, twice for B."
        ))

        let output = try Self.write(keymap)
        #expect(output.contains(
            "        td: tap_dance_x {\n"
                + "            /* zmkonfig: Tap for A, twice for B. */\n"
                + "            compatible = \"zmk,behavior-tap-dance\";\n"
        ))
        // And it survives being read back, which is the only proof that what
        // was written is a note rather than a comment that merely looks like one.
        let reparsed = try KeymapFile(source: Data(output.utf8))
        #expect(try Self.behavior(reparsed, "td").note == "Tap for A, twice for B.")
    }

    @Test("A long note wraps and still reads back as what was written")
    func wrapping() throws {
        let note = "Home-row modifier for the left hand: hold for a modifier, tap for "
            + "the letter, and never hold within 150 ms of the previous key so a fast "
            + "roll cannot fire it by accident."
        var keymap = try Self.file()
        var hml = try Self.behavior(keymap, "hml")
        hml.note = note
        try keymap.upsertBehavior(hml)

        let output = try Self.write(keymap)
        let lines = output.components(separatedBy: "\n").filter { $0.contains("zmkonfig:") || $0.contains("roll cannot") }
        #expect(lines.count >= 1)
        for line in output.components(separatedBy: "\n") where line.contains("zmkonfig:") {
            #expect(line.count <= 80, "a wrapped line ran long: \(line)")
        }
        let reparsed = try KeymapFile(source: Data(output.utf8))
        #expect(try Self.behavior(reparsed, "hml").note == note)
    }

    // MARK: Sanitising

    @Test("Nothing can close the comment it is written inside")
    func cannotEscape() throws {
        // The one thing that would turn a description into devicetree. Every
        // case is checked on the sanitised text directly, because this is the
        // guarantee the feature rests on rather than a formatting preference.
        let attacks = [
            "harmless */ compatible = \"zmk,behavior-macro\"; /*",
            "*/",
            "**//",
            "a */ b /* c",
            "/*/*/*",
            "trailing *",
            "*/*/*/*/",
        ]
        for attack in attacks {
            let clean = BehaviorNote.sanitized(attack)
            #expect(!clean.contains("*/"), "\(attack.debugDescription) sanitised to \(clean.debugDescription)")
            #expect(!clean.contains("/*"), "\(attack.debugDescription) sanitised to \(clean.debugDescription)")
        }
    }

    @Test("An escape attempt written into a keymap comes back as a comment, not devicetree")
    func escapeAttemptSplices() throws {
        var keymap = try Self.file()
        var hml = try Self.behavior(keymap, "hml")
        hml.note = "*/ compatible = \"zmk,behavior-macro\"; /* still mine"
        try keymap.upsertBehavior(hml)

        let output = try Self.write(keymap)
        let reparsed = try KeymapFile(source: Data(output.utf8))
        // The node is still a hold-tap, and the injected property is not one.
        let after = try Self.behavior(reparsed, "hml")
        #expect(after.compatible == BehaviorKind.holdTap.compatible)
        #expect(after.properties.map(\.name) == ["tapping-term-ms"])
    }

    @Test("Newlines and control characters collapse to spaces")
    func collapsesWhitespace() {
        #expect(BehaviorNote.sanitized("  one\n\ttwo   three \n\n ") == "one two three")
        #expect(BehaviorNote.sanitized("a\u{0}b\u{7}c") == "abc")
    }

    @Test("A note past the limit is cut rather than allowed to bury the node")
    func lengthLimit() {
        let long = String(repeating: "word ", count: 400)
        let clean = BehaviorNote.sanitized(long)
        #expect(clean.count <= BehaviorNote.characterLimit + 1)
        #expect(clean.hasSuffix("…"))
    }

    @Test("A note that sanitises to nothing produces no comment at all")
    func emptyComment() {
        #expect(BehaviorNote.comment("", indent: "    ") == nil)
        #expect(BehaviorNote.comment("  \n ", indent: "    ") == nil)
        #expect(BehaviorNote.comment("*/", indent: "    ") != nil)
    }
}
