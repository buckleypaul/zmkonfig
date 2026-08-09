import Foundation
import Testing

@testable import ZmkonfigKit

/// The context pack: what a prompt about this keymap is told before it is asked
/// anything.
@Suite("Context pack")
struct ContextPackTests {

    private static func context() throws -> KeymapContext {
        let keymap = try Fixture.cradio()
        return KeymapContext(
            keymap: keymap,
            layout: try Fixture.cradioLayout(),
            behaviors: BehaviorIndex(stock: try ZMKMetadata.loadBehaviors(), keymap: keymap)
        )
    }

    private static func baseLayer(_ context: KeymapContext) throws -> KeymapLayer {
        try #require(context.layers.first { $0.nodeName == "default_layer" })
    }

    // MARK: - Which behaviors are in

    /// The whole point of the pack: `&hml LEFT_GUI A` is a home-row mod because
    /// of properties that live two hundred lines up the file, and the model
    /// never saw them.
    @Test("A layer's pack defines the behaviors that layer binds")
    func definesReferencedBehaviors() throws {
        let context = try Self.context()
        let pack = ContextPack.forLayer(try Self.baseLayer(context), context: context)

        // Every behavior the base layer binds.
        for code in ["&kp", "&hml", "&hmr", "&mt", "&lt"] {
            #expect(pack.contains(code), "the pack does not mention \(code)")
        }

        // And &hml is defined, not merely named.
        let line = try #require(
            pack.components(separatedBy: "\n").first { $0.hasPrefix("&hml ") }
        )
        #expect(line.contains("hold_tap_left"))
        #expect(line.contains("flavor \"tap-preferred\""))
        #expect(line.contains("tapping-term-ms 280"))
        #expect(line.contains("require-prior-idle-ms 150"))
        #expect(line.contains("hold-trigger-key-positions"))
    }

    /// The fixture defines eight hold-taps and the base layer uses two. The
    /// other six describe keys the reader cannot see, so they are prompt weight
    /// for nothing.
    @Test("A layer's pack leaves out behaviors that layer does not bind")
    func excludesUnreferencedBehaviors() throws {
        let context = try Self.context()
        let pack = ContextPack.forLayer(try Self.baseLayer(context), context: context)

        for code in ["&rpi", "&qt", "&ht", "&hold_temp_layer", "&ht_pref_hold", "&sticky_tap"] {
            #expect(!pack.contains(code), "the pack should not mention \(code)")
        }
    }

    /// A combo is often the only way off a layer, so its behaviors are as much
    /// part of the layer's story as the layer's own — `&sl 4` is how the
    /// settings layer is reached and nothing on any layer binds it.
    @Test("A layer's pack defines the behaviors the combos bind")
    func includesComboBehaviors() throws {
        let context = try Self.context()
        let pack = ContextPack.forLayer(try Self.baseLayer(context), context: context)

        #expect(pack.contains("&sl —"))
        #expect(pack.contains("&mo —"))
    }

    /// `hold_temp_layer` holds `&mo` and taps `&tog`, and momentary-versus-toggle
    /// is the whole difference between the two halves of that key.
    @Test("A wrapped behavior is pulled in with the behavior that wraps it")
    func closesOverWrappedBehaviors() throws {
        let context = try Self.context()
        let pack = ContextPack.forKeymap(context)

        #expect(pack.contains("&hold_temp_layer —"))
        #expect(pack.contains("&tog —"), "&tog is only reachable through &hold_temp_layer")
    }

    /// A diff can add the first use of a behavior nothing binds yet, which is
    /// exactly the change worth reviewing carefully.
    @Test("The whole-keymap pack carries every behavior the keymap defines")
    func keymapPackCarriesEveryDefinedBehavior() throws {
        let context = try Self.context()
        let pack = ContextPack.forKeymap(context)

        for behavior in try Fixture.cradio().behaviors {
            #expect(pack.contains("&\(behavior.label) —"), "&\(behavior.label) is missing")
        }
    }

    // MARK: - The rest of the pack

    @Test("The pack names every layer")
    func namesEveryLayer() throws {
        let context = try Self.context()
        let pack = ContextPack.forLayer(try Self.baseLayer(context), context: context)

        for layer in context.layers {
            #expect(pack.contains("\"\(layer.displayName)\""), "layer \(layer.id) is missing")
        }
    }

    /// The layer prompt used to be handed `layerNames` explicitly. It now reads
    /// them out of the context, and this is what says nothing was dropped.
    @Test("The layer list survives the move into KeymapContext")
    func layerNamesComeFromTheContext() throws {
        let context = try Self.context()
        #expect(
            context.layers.map(\.displayName)
                == ["Default Layer", "Nav", "Num", "Symbols", "Settings Layer"]
        )
    }

    @Test("The pack lists the combos, with the position macros they were written with")
    func listsCombos() throws {
        let context = try Self.context()
        let pack = ContextPack.forLayer(try Self.baseLayer(context), context: context)

        #expect(pack.contains("`settings-layer`"))
        #expect(pack.contains("&sl 4"))
        #expect(pack.contains("`layer-nums`"))
    }

    // MARK: - Determinism

    /// The pack is the prompt prefix. A prefix that reorders itself between
    /// calls is a prefix that never caches.
    @Test("The same keymap produces byte-identical packs")
    func isDeterministic() throws {
        // Two independent parses, so nothing shared can be carrying the order.
        for _ in 0..<5 {
            let first = try Self.context()
            let second = try Self.context()
            #expect(
                ContextPack.forLayer(try Self.baseLayer(first), context: first)
                    == ContextPack.forLayer(try Self.baseLayer(second), context: second)
            )
            #expect(ContextPack.forKeymap(first) == ContextPack.forKeymap(second))
        }
    }

    @Test("Behaviors are listed in sorted order")
    func behaviorsAreSorted() throws {
        let context = try Self.context()
        let pack = ContextPack.forKeymap(context)
        let codes = pack.components(separatedBy: "\n")
            .filter { $0.hasPrefix("&") }
            .compactMap { $0.components(separatedBy: " ").first }

        #expect(codes.count > 5)
        #expect(codes == codes.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    /// The primer is in every prompt, so it is worth one test that it is there
    /// and says the things the prompts lean on.
    @Test("The primer explains what the parser cannot")
    func primerCoversTheBasics() throws {
        for phrase in ["tap-preferred", "hold-trigger-key-positions", "&trans", "&tog", "combo"] {
            #expect(ContextPack.primer.lowercased().contains(phrase.lowercased()))
        }
    }

    // MARK: - Nothing open

    @Test("An empty context does not claim a keymap it does not have")
    func emptyContext() {
        let pack = ContextPack.forKeymap(KeymapContext())
        #expect(pack.contains("This keymap binds no behaviors."))
        #expect(pack.contains("This keymap has no layers."))
        #expect(pack.contains("This keymap has no combos."))
    }
}
