import Foundation

/// The local context a prompt about this keymap needs before it can say
/// anything true about it.
///
/// A layer on its own is a list of tokens. `&hml LEFT_GUI A` is a home-row mod
/// only because `hold_tap_left` sets `flavor`, `tapping-term-ms` and
/// `hold-trigger-key-positions` two hundred lines further up the file; `&lt 3
/// SPACE` is only reachable if some other layer leads to layer 3; and a layer
/// with no `&to`/`&mo` pointing back at it is often escaped by a combo. All
/// three are parsed and sat unused while the model was asked to infer them.
/// This assembles them.
///
/// Everything here is a pure function of ``KeymapContext``, and every list is
/// sorted, because the pack goes in the prompt prefix and a prefix that
/// reorders itself between calls cannot be cached.
///
/// Nothing here can reach the `.keymap` on disk.
public enum ContextPack {

    // MARK: - Packs

    /// The pack for a question about one layer.
    ///
    /// Behaviors are narrowed to what this layer and the combos actually bind —
    /// the fixture defines eight hold-taps and the base layer uses two of them,
    /// and the other six are prompt weight that describes keys the reader
    /// cannot see.
    public static func forLayer(_ layer: KeymapLayer, context: KeymapContext) -> String {
        pack(
            behaviors: behaviorReference(
                for: referencedCodes(in: layer.bindings + context.combos.map(\.binding)),
                context: context
            ),
            context: context
        )
    }

    /// The pack for a review of a diff.
    ///
    /// A diff can name anything in the file, including a behavior that nothing
    /// binds yet — adding the first `&qt` to a layer is exactly the kind of
    /// change worth reviewing — so this carries every behavior and macro the
    /// keymap defines, plus whatever the layers and combos bind on top.
    public static func forKeymap(_ context: KeymapContext) -> String {
        let bound = context.layers.flatMap(\.bindings) + context.combos.map(\.binding)
        let defined = (context.keymap?.behaviors.map { "&\($0.label)" } ?? [])
            + (context.keymap?.macros.map { "&\($0.label)" } ?? [])
        return pack(
            behaviors: behaviorReference(
                for: referencedCodes(in: bound).union(defined),
                context: context
            ),
            context: context
        )
    }

    private static func pack(behaviors: String, context: KeymapContext) -> String {
        // Primer first and keymap-specific material after it, so the constant
        // half of the prefix is a constant *prefix* and a cache hit does not
        // depend on which layer is being asked about.
        """
        \(primer)

        ## The behaviors this keymap binds

        \(behaviors)

        ## The layers of this keymap

        \(KeymapDigest.layers(context.layers))

        ## The combos of this keymap

        Combos fire when their key positions are pressed together. They are \
        often the only way onto or off a layer, so read them before calling a \
        layer unreachable.

        \(KeymapDigest.combos(context.combos, keymap: context.keymap))
        """
    }

    // MARK: - Behaviors

    /// Every behavior in `codes`, defined as far as the keymap defines it, one
    /// per line and sorted by code.
    ///
    /// ``AssistantTools/summary(of:)-(KeymapBehavior)`` renders the definition,
    /// because `list_behaviors_defined` already answers this question and the
    /// two must not describe the same `&hml` differently.
    static func behaviorReference(for codes: Set<String>, context: KeymapContext) -> String {
        let ordered = closure(of: codes, context: context)
        guard !ordered.isEmpty else { return "This keymap binds no behaviors." }
        return ordered.map { line(for: $0, context: context) }.joined(separator: "\n")
    }

    private static func line(for code: String, context: KeymapContext) -> String {
        if let behavior = definedBehavior(code, in: context) {
            return "\(code) — defined by this keymap in node `\(behavior.nodeName)`, "
                + "\(behavior.bindingCells) parameter(s): \(AssistantTools.summary(of: behavior))"
        }
        if let macro = definedMacro(code, in: context) {
            return "\(code) — a macro defined by this keymap in node `\(macro.nodeName)`, "
                + "\(macro.bindingCells) parameter(s): "
                + AssistantTools.summary(of: macro, sequenceLimit: nil)
        }

        let known = context.behaviors.behavior(for: code)
        let params = known?.params ?? []
        let shape = params.isEmpty ? "no parameters" : params.map(\.rawValue).joined(separator: ", ")
        guard context.isDocumentedBehavior(code) else {
            // Bound but defined nowhere this editor can see — an include, or a
            // node it could not model. Saying so is the honest answer; letting
            // it read as a stock behavior would invite the model to explain a
            // behavior it is guessing at.
            return "\(code) — no definition in this keymap or in ZMK's own list; "
                + "it comes from an include this editor does not read. Takes \(shape)."
        }
        return "\(code) — \(known?.name ?? code), a stock ZMK behavior: \(shape)"
    }

    /// The codes these bindings name, plus the codes those behaviors wrap.
    ///
    /// A hold-tap is only half-explained by its own properties: `hold_temp_layer`
    /// holds `&mo` and taps `&tog`, and the difference between momentary and
    /// toggle is the whole point of the key. The wrapped behaviors are pulled in
    /// transitively so the chain terminates in something stock.
    private static func closure(of codes: Set<String>, context: KeymapContext) -> [String] {
        var seen: Set<String> = []
        var pending = codes.sorted()
        while let code = pending.popLast() {
            guard seen.insert(code).inserted else { continue }
            pending += wrapped(by: code, in: context).filter { !seen.contains($0) }
        }
        return seen.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func wrapped(by code: String, in context: KeymapContext) -> [String] {
        if let behavior = definedBehavior(code, in: context) {
            // `bindings` entries may carry parameters — a mod-morph writes
            // `<&kp MINUS>, <&kp UNDER>` — so only the head is a behavior.
            return behavior.bindings.compactMap { $0.split(separator: " ").first.map(String.init) }
        }
        if let macro = definedMacro(code, in: context) {
            return macro.bindings.map(\.behavior)
        }
        return []
    }

    private static func referencedCodes(in bindings: [KeyBinding]) -> Set<String> {
        Set(bindings.map(\.behavior))
    }

    private static func definedBehavior(
        _ code: String, in context: KeymapContext
    ) -> KeymapBehavior? {
        context.keymap?.behaviors.first { "&\($0.label)" == code }
    }

    private static func definedMacro(_ code: String, in context: KeymapContext) -> KeymapMacro? {
        context.keymap?.macros.first { "&\($0.label)" == code }
    }

    // MARK: - Primer

    /// What ZMK means by the things this keymap is made of.
    ///
    /// Vendored as a constant rather than as a file in `Resources`: the kit
    /// reaches its resource bundle only through the app's `AppResources`, and a
    /// prompt prefix that can fail to load is a prefix that silently degrades
    /// the answer. It is deliberately short — the model knows ZMK, and this is
    /// here to pin down the handful of things it reliably gets wrong about a
    /// keymap it is reading rather than writing.
    ///
    /// Fetching the real docs at call time was considered and rejected in
    /// issue #14: a second network hop and credential before every call,
    /// non-deterministic retrieval, and a per-request snippet in the prefix
    /// would defeat prompt caching.
    public static let primer = """
        ## How to read a ZMK keymap

        Layers are a stack. Layer 0 is always active; the others are turned on \
        by a behavior. `&mo N` holds layer N on while the key is held, `&to N` \
        switches to N and turns the others off, `&tog N` toggles N, `&sl N` \
        makes N active for the next key only, and `&lt N KEY` is layer N on \
        hold and KEY on tap. `&trans` falls through to whatever the layer below \
        binds at that position; `&none` binds nothing at all and blocks the \
        fall-through.

        A layer is reachable only if something activates it — a binding on a \
        layer that is itself reachable, or a combo. A layer whose own keys are \
        all `&trans` except the ones that got you there is usually fine; a \
        layer reached with `&to` or `&tog` and holding no way back is not.

        A hold-tap sends one binding when tapped and another when held. Its \
        properties are what decide which:

        - `bindings = <hold>, <tap>` — hold first, tap second.
        - `flavor` — `hold-preferred` resolves to the hold as soon as another \
        key goes down, `balanced` waits for that other key to be released, \
        `tap-preferred` sends the tap unless the key is held past the term, \
        `tap-unless-interrupted` sends the tap unless another key intervenes.
        - `tapping-term-ms` — how long a hold has to last.
        - `quick-tap-ms` — tapping again within this window repeats the tap, so \
        a held key auto-repeats its letter instead of latching a modifier.
        - `require-prior-idle-ms` — no hold at all if another key was pressed \
        within this window. This is the anti-misfire setting that makes \
        home-row mods usable while typing fast.
        - `hold-trigger-key-positions` — only these key positions may resolve \
        the hold. A home-row mod normally lists the opposite hand and the \
        thumbs, so same-hand rolls stay letters.
        - `hold-trigger-on-release`, `retro-tap` — refinements on the same.

        Home-row mods are hold-taps on the home row whose hold is a modifier \
        and whose tap is the letter. They are identified by that shape, not by \
        a name.

        Key positions are numbered from 0 in the order the bindings appear, \
        which is the order of the index legend given with a layer.

        `LG()`, `LC()`, `LA()`, `LS()` and their right-hand `R…` forms wrap a \
        keycode in a modifier: `&kp LG(LS(SPACE))` is Gui+Shift+Space.
        """
}
