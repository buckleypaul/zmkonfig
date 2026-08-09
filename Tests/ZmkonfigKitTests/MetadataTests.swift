import Foundation
import Testing

@testable import ZmkonfigKit

@Suite("Vendored ZMK metadata")
struct MetadataTests {
    /// `ParamKind` decodes strictly, so a re-vendored `zmk-behaviors.json` that
    /// introduces a fifth slot kind fails to load the whole file rather than
    /// mislabelling one slot. That trade is only safe if something checks the
    /// file still decodes — nothing else in the suite loads it.
    @Test("Behaviors decode, and every parameter kind is one the editor knows")
    func behaviorsDecode() throws {
        let behaviors = try ZMKMetadata.loadBehaviors()
        #expect(behaviors.count == 15)
        let kinds = Set(behaviors.flatMap { $0.params ?? [] })
        #expect(kinds == [.code, .layer, .mod, .command])
        #expect(behaviors.contains { $0.code == "&kp" })
    }

    @Test("Keycodes decode and carry usable names")
    func keycodesDecode() throws {
        let keycodes = try ZMKMetadata.loadKeycodes()
        #expect(keycodes.count > 300)
        #expect(keycodes.allSatisfy { !$0.primaryName.isEmpty })
        #expect(keycodes.contains { $0.names.contains("SPACE") })
    }

    @Test("A keycode matches on any of its names, its description or its context")
    func keycodeMatching() {
        let keycode = ZMKKeycode(
            names: ["LEFT_CONTROL", "LCTRL"], description: "Left Control", context: "Keyboard",
            os: nil
        )
        #expect(keycode.matches("lctrl"))
        #expect(keycode.matches("left_con"))
        #expect(keycode.matches("left control"))
        #expect(keycode.matches("keyboard"))
        #expect(!keycode.matches("bluetooth"))
        // The query is pre-folded by the caller, so an unfolded one cannot match
        // and the picker must lowercase before it asks.
        #expect(!keycode.matches("LCTRL"))
        #expect(keycode.matches(""))
    }
}
