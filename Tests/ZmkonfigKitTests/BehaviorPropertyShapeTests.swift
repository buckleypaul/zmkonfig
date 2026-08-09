import Foundation
import Testing

@testable import ZmkonfigKit

@Suite("Behavior property shapes")
struct BehaviorPropertyShapeTests {

    @Test("Every property a kind offers has a shape that writes something legal")
    func everyOfferedPropertyIsWritable() throws {
        for kind in BehaviorKind.allCases {
            for name in kind.requiredProperties + kind.optionalProperties {
                let value = BehaviorPropertyShape.shape(of: name).initialValue
                // An empty cell renders as `<>`, which devicetree rejects and
                // `BehaviorWriter.problems` refuses — so a property switched on
                // in the UI would be unsaveable the moment it was added.
                #expect(!value.isEmptyCell, "\(kind.rawValue).\(name) starts empty")
                #expect(
                    BehaviorWriter.valueText(value) != nil || value == .flag,
                    "\(kind.rawValue).\(name) has no text to write"
                )
            }
        }
    }

    @Test("A flag is offered as a flag, not as a value")
    func flagsAreFlags() {
        for name in ["retro-tap", "hold-trigger-on-release", "quick-release", "lazy"] {
            #expect(BehaviorPropertyShape.shape(of: name) == .choiceless)
            #expect(BehaviorPropertyShape.shape(of: name).initialValue == .flag)
        }
    }

    @Test("A duration this table has never heard of is still offered as a number")
    func unknownDurations() {
        guard case .integer = BehaviorPropertyShape.shape(of: "some-future-ms") else {
            Issue.record("a `-ms` property should be a number")
            return
        }
    }

    @Test("An unknown property falls back to free text rather than to a number")
    func unknownFallback() {
        guard case .tokens = BehaviorPropertyShape.shape(of: "invented-property") else {
            Issue.record("an unknown property should be free text")
            return
        }
    }

    @Test("Flavor is a choice, and every option is one ZMK accepts")
    func flavorOptions() {
        guard case .choice(let options, let initial) = BehaviorPropertyShape.shape(of: "flavor")
        else {
            Issue.record("flavor should be a choice")
            return
        }
        #expect(options.contains(initial))
        #expect(options == BehaviorPropertyShape.flavors)
    }

    @Test("The value in the file wins over the table")
    func valueWinsOverTable() {
        // A keymap writing `tapping-term-ms = <TAPPING_TERM>` means the
        // `#define`, and offering a number field would be offering the user a
        // way to lose it without meaning to.
        let shape = BehaviorPropertyShape.shape(of: "tapping-term-ms", value: .tokens(["TAPPING_TERM"]))
        guard case .tokens = shape else {
            Issue.record("an unresolved token should stay free text")
            return
        }
    }

    @Test("A number in the file is offered as a number even where the table says otherwise")
    func numberStaysANumber() {
        let shape = BehaviorPropertyShape.shape(of: "tapping-term-ms", value: .integer(280))
        guard case .integer(let initial) = shape else {
            Issue.record("a number should be a number")
            return
        }
        // The table's default, not the file's — an existing value is shown by
        // the field, and `initial` is only what a fresh one starts at.
        #expect(initial == 200)
    }
}
