import Foundation

/// One change the assistant proposes.
///
/// Each case maps 1:1 onto a mutator `KeymapFile` already has, so a proposal
/// cannot express an edit the manual editor could not make. That is the whole
/// safety argument for the feature: the model writes no devicetree and picks no
/// byte ranges — it names a layer and a key position, and the same
/// `SourceEdit` splice that serves every button in the UI does the rest.
public enum ProposedEdit: Identifiable, Equatable, Sendable {
    case setBinding(layer: Int, index: Int, binding: KeyBinding)
    /// A whole combo, either an edited copy of one the file has (matched by id)
    /// or a brand new one.
    case setCombo(KeymapCombo)
    case removeCombo(id: KeymapCombo.ID)
    case renameLayer(layer: Int, name: String)
    /// A whole behavior node — `hml: hml { compatible = "zmk,behavior-hold-tap"; … }`
    /// — either an edited copy of one the file defines (matched by id) or a new
    /// one. The model never writes the node; it names a kind and fills in
    /// fields, and `BehaviorWriter` renders it.
    case setBehavior(KeymapBehavior)
    case removeBehavior(id: KeymapBehavior.ID)
    case setMacro(KeymapMacro)
    case removeMacro(id: KeymapMacro.ID)
    case addLayer(nodeName: String, displayName: String?, bindings: [KeyBinding], at: Int)
    case removeLayer(at: Int)

    /// Identifies the *target*, not the edit, so a second proposal aimed at the
    /// same key, combo or layer replaces the first instead of stacking up. A
    /// model that reconsiders — sets a key, then sets it again — would otherwise
    /// stage two edits and show the user a card listing both.
    ///
    /// `setCombo` and `removeCombo` deliberately share a namespace: staging a
    /// removal of a combo you just edited must cancel the edit, not queue after
    /// it. Behaviors, macros and layers follow the same rule. `set_behavior`
    /// reuses the id of the behavior it is editing — including one staged
    /// earlier in the same turn — so two calls naming the same `&label` collapse
    /// to one proposal rather than staging two nodes with two fresh ids.
    ///
    /// `addLayer` is the exception that has no target yet, so it keys on the
    /// node name it would create. `removeLayer` shares `renameLayer`'s
    /// namespace: removing a layer you just renamed cancels the rename.
    public var id: String {
        switch self {
        case .setBinding(let layer, let index, _): "binding:\(layer):\(index)"
        case .setCombo(let combo): "combo:\(combo.id)"
        case .removeCombo(let id): "combo:\(id)"
        case .renameLayer(let layer, _): "layer:\(layer)"
        case .setBehavior(let behavior): "behavior:\(behavior.id)"
        case .removeBehavior(let id): "behavior:\(id)"
        case .setMacro(let macro): "macro:\(macro.id)"
        case .removeMacro(let id): "macro:\(id)"
        case .addLayer(let nodeName, _, _, _): "layer-new:\(nodeName)"
        case .removeLayer(let index): "layer:\(index)"
        }
    }
}

/// Why a staged proposal could not be applied after the fact.
///
/// The tools validate everything against the live keymap before staging, so
/// these only fire when the keymap moved underneath a proposal — the user
/// reloaded the repo, or deleted a combo, between the model staging a change
/// and clicking Apply. That is a real failure and gets a real message rather
/// than a silently skipped edit.
public enum ProposalError: Error, CustomStringConvertible {
    case comboGone

    public var description: String {
        switch self {
        case .comboGone:
            "a combo the change would have removed is no longer in this keymap; "
                + "it may have been deleted, or the repo reloaded, since the "
                + "change was suggested"
        }
    }
}

/// The tools Claude may call, and what happens when it calls one.
///
/// The read tools run immediately and answer from a ``KeymapContext`` — a
/// snapshot of the editor taken per call. The edit tools **mutate nothing**:
/// they validate their arguments against the keymap as it stands, stage a
/// ``ProposedEdit``, and tell the model plainly that it has been staged rather
/// than applied. Nothing here can write a `KeymapFile`, so there is no path
/// from a tool call to the file on disk.
public enum AssistantTools {

    /// What one tool call produced: the answer to send back, and any change to
    /// the staged set.
    public struct Outcome {
        public let result: ClaudeToolResult
        /// An edit to stage, replacing any staged edit with the same id.
        public var staged: ProposedEdit?
        /// A staged edit to drop — how `remove_combo` cancels the creation of a
        /// combo staged earlier in the same turn, which was never in the file
        /// and so cannot be removed from it.
        public var unstage: ProposedEdit.ID?
    }

    enum Name {
        static let listLayers = "list_layers"
        static let readLayer = "read_layer"
        static let listCombos = "list_combos"
        static let findKeycodes = "find_keycodes"
        static let listBehaviors = "list_behaviors"
        static let listBehaviorsDefined = "list_behaviors_defined"
        static let listMacros = "list_macros"
        static let readKeymapSource = "read_keymap_source"
        static let setBinding = "set_binding"
        static let setCombo = "set_combo"
        static let removeCombo = "remove_combo"
        static let renameLayer = "rename_layer"
        static let setBehavior = "set_behavior"
        static let removeBehavior = "remove_behavior"
        static let setMacro = "set_macro"
        static let removeMacro = "remove_macro"
        static let addLayer = "add_layer"
        static let removeLayer = "remove_layer"
    }

    /// `find_keycodes` answers are capped: the keycode table is 300-odd entries
    /// and a query like "a" matches most of them. A truncated list that says it
    /// is truncated is better than a tool result that crowds out the keymap.
    static let keycodeLimit = 40

    /// The same cap `ExplainModel.diffCharacterLimit` puts on a diff, and for
    /// the same reason: a keymap is usually a few hundred lines, but a generated
    /// one can be enormous, and a silently half-read file is worse than no file
    /// — the model would reason about includes and behaviors that are simply
    /// missing from what it was shown. Past this the answer is clipped on a line
    /// boundary and says so, and says how to ask for the rest.
    static let sourceCharacterLimit = 40_000

    // MARK: - Declarations

    public static let all: [ClaudeTool] = [
        ClaudeTool(
            name: Name.listLayers,
            description: """
                Lists every layer in the open keymap: its layer number, its \
                display name, its devicetree node name, and how many keys it \
                binds. Layer numbers are what `&mo`, `&lt` and `&to` refer to \
                and are what every other tool here means by "layer".
                """,
            inputSchema: schema()
        ),
        ClaudeTool(
            name: Name.readLayer,
            description: """
                Shows one layer's bindings, drawn as the keys physically sit \
                under the hands — one line per row, and on a split board a gap \
                between the halves — followed by a legend giving each key's \
                position number. Read the layer you are about to change before \
                you change it; key position numbers cannot be guessed from a \
                description.
                """,
            inputSchema: schema(
                ["layer": integer("Layer number, as reported by list_layers.")],
                required: ["layer"]
            )
        ),
        ClaudeTool(
            name: Name.listCombos,
            description: """
                Lists every combo: node name, the key positions that make up \
                the chord, the behavior it fires, which layers it is active on, \
                and its timing properties. Combos are addressed by node name \
                everywhere in these tools.
                """,
            inputSchema: schema()
        ),
        ClaudeTool(
            name: Name.findKeycodes,
            description: """
                Searches ZMK's keycode table by name or description, e.g. \
                "volume", "F11", "bluetooth". Use it to confirm the exact \
                spelling of a keycode before binding it — ZMK will not build \
                with a keycode that does not exist.
                """,
            inputSchema: schema(
                ["query": string("What to search for. Matched against keycode names and descriptions.")],
                required: ["query"]
            )
        ),
        ClaudeTool(
            name: Name.listBehaviors,
            description: """
                Lists every behavior this keymap can bind, including the \
                hold-taps, macros and other behaviors the keymap defines for \
                itself, with the parameters each one takes. Check here before \
                binding anything other than `&kp`.
                """,
            inputSchema: schema()
        ),
        ClaudeTool(
            name: Name.listBehaviorsDefined,
            description: """
                Lists the behaviors this keymap defines for itself — the \
                hold-taps, tap-dances, mod-morphs and sticky keys written into \
                the file — with the kind of each, the behaviors it wraps and \
                every property it sets. This is the one to read before editing a \
                behavior; list_behaviors gives the names and parameter shapes of \
                everything bindable, but not how the keymap's own behaviors are \
                configured.
                """,
            inputSchema: schema()
        ),
        ClaudeTool(
            name: Name.listMacros,
            description: """
                Lists the macros this keymap defines: node name, label, how many \
                parameters each takes, its timing, and the full sequence of \
                bindings it plays. Read it before editing a macro.
                """,
            inputSchema: schema()
        ),
        ClaudeTool(
            name: Name.readKeymapSource,
            description: """
                Shows the raw text of the `.keymap` file as the editor last \
                parsed it: includes, `#define`s, custom behaviors, macros, \
                comments, node overrides — everything the other tools do not \
                model. Read it before changing anything you have not already \
                looked at, and whenever you need to know how the file is \
                actually written rather than what it binds. This is read-only \
                and cannot change anything. A long file is shown in pieces; the \
                answer says so and how to ask for the next one.
                """,
            inputSchema: schema(
                ["from_line": integer("Line to start from, counting from 1. Omit to start at the top.")]
            )
        ),
        ClaudeTool(
            name: Name.setBinding,
            description: """
                Stages a change to one key on one layer. This does NOT edit the \
                keymap: the change is shown to the user, who applies or \
                discards it. Read the layer first so the key position is the one \
                you mean.
                """,
            inputSchema: schema(
                [
                    "layer": integer("Layer number to change."),
                    "key_position": integer("Key position on that layer, from the layer's legend."),
                    "binding": string("The binding in ZMK syntax, e.g. `&kp ESC`, `&mo 2`, `&hml LGUI A`. Exactly one binding."),
                ],
                required: ["layer", "key_position", "binding"]
            )
        ),
        ClaudeTool(
            name: Name.setCombo,
            description: """
                Stages a combo. If `name` matches an existing combo, only the \
                properties you give are changed and the rest are left as the \
                file has them; if it does not, a new combo is created and both \
                `key_positions` and `binding` are required. This does NOT edit \
                the keymap — the change is staged for the user.
                """,
            inputSchema: schema(
                [
                    "name": string("The combo's devicetree node name, e.g. `esc-combo`."),
                    "key_positions": integers("The key positions that form the chord. At least two."),
                    "binding": string("What the chord fires, in ZMK syntax, e.g. `&kp ESC`. Exactly one binding."),
                    "layers": integers("Layer numbers the combo is active on. Omit to leave it active on every layer."),
                    "timeout_ms": integer("How close together the keys must be pressed, in milliseconds."),
                ],
                required: ["name"]
            )
        ),
        ClaudeTool(
            name: Name.removeCombo,
            description: """
                Stages the removal of a combo, by node name. This does NOT edit \
                the keymap — the removal is staged for the user.
                """,
            inputSchema: schema(
                ["name": string("The combo's devicetree node name, as given by list_combos.")],
                required: ["name"]
            )
        ),
        ClaudeTool(
            name: Name.renameLayer,
            description: """
                Stages a new display name for a layer. This is the label shown \
                on the keyboard's display and in this editor; it does not change \
                the layer's number or its devicetree node name, so nothing that \
                refers to the layer breaks. This does NOT edit the keymap — the \
                rename is staged for the user.
                """,
            inputSchema: schema(
                [
                    "layer": integer("Layer number to rename."),
                    "name": string("The new display name, e.g. `Nav`."),
                ],
                required: ["layer", "name"]
            )
        ),
        ClaudeTool(
            name: Name.setBehavior,
            description: """
                Stages a behavior the keymap defines for itself — a hold-tap, \
                tap-dance, mod-morph, sticky key and so on. If `label` matches a \
                behavior the keymap already defines, only the fields you give are \
                changed and the rest are left as the file has them; if it does \
                not, a new behavior is created and `kind` and `bindings` are \
                required. The label is what a binding refers to: a behavior \
                labelled `hml` is bound as `&hml`. This does NOT edit the keymap \
                — the change is staged for the user.
                """,
            inputSchema: schema(
                [
                    "label": string("The behavior's label, without the `&`, e.g. `hml`. This is what bindings refer to."),
                    "kind": enumeration(
                        behaviorKinds.map(\.rawValue),
                        """
                        What kind of behavior it is. Required when creating one. \
                        \(behaviorKinds.map { kindSummary($0) }.joined(separator: " "))
                        """
                    ),
                    "bindings": strings("""
                        The behaviors this one wraps, e.g. `["&kp", "&kp"]` for a \
                        hold-tap — the hold behavior first, then the tap. A \
                        hold-tap and a sticky key take bare references with no \
                        parameters; a mod-morph and a tap dance take whole \
                        bindings, `["&kp MINUS", "&kp UNDER"]`.
                        """),
                    "binding_cells": integer("""
                        How many parameters a binding of this behavior takes. Fixed \
                        by the kind — a hold-tap is 2, a sticky key 1, the rest 0 — \
                        so omit it unless you have a reason.
                        """),
                    "properties": object("""
                        The rest of the behavior's devicetree properties, as \
                        name → value, e.g. {"tapping-term-ms": 280, "flavor": \
                        "balanced", "hold-trigger-key-positions": [0, 1, 2]}. A \
                        number writes as a number, a string as a quoted string, an \
                        array of numbers as a cell list, and `true` as a bare flag \
                        property. Property names are devicetree's, hyphenated.
                        """),
                ],
                required: ["label"]
            )
        ),
        ClaudeTool(
            name: Name.removeBehavior,
            description: """
                Stages the removal of a behavior the keymap defines, by label. \
                Check first whether anything still binds it — a binding of a \
                behavior that no longer exists will not build. This does NOT edit \
                the keymap — the removal is staged for the user.
                """,
            inputSchema: schema(
                ["label": string("The behavior's label, without the `&`, as given by list_behaviors_defined.")],
                required: ["label"]
            )
        ),
        ClaudeTool(
            name: Name.setMacro,
            description: """
                Stages a macro: a labelled sequence of bindings the keyboard \
                plays back when the macro is pressed. If `label` matches an \
                existing macro only the fields you give are changed; if it does \
                not, a new macro is created and `bindings` is required. This does \
                NOT edit the keymap — the change is staged for the user.
                """,
            inputSchema: schema(
                [
                    "label": string("The macro's label, without the `&`, e.g. `email`. Bound as `&email`."),
                    "bindings": strings("""
                        The sequence to play, in order, in ZMK syntax: \
                        `["&kp H", "&kp I"]`. Macro control behaviors belong here \
                        too — `&macro_tap`, `&macro_press`, `&macro_release`, \
                        `&macro_wait_time 50`. An entry may hold several bindings \
                        separated by spaces.
                        """),
                    "parameters": integer("""
                        How many parameters the macro takes, 0, 1 or 2. Omit for 0. \
                        A parameterised macro uses `&macro_param_1to1` and friends \
                        in its sequence.
                        """),
                    "wait_ms": integer("Milliseconds between steps. Omit to leave it at ZMK's default."),
                    "tap_ms": integer("How long each tap is held, in milliseconds. Omit for the default."),
                ],
                required: ["label"]
            )
        ),
        ClaudeTool(
            name: Name.removeMacro,
            description: """
                Stages the removal of a macro, by label. Check first whether \
                anything still binds it. This does NOT edit the keymap — the \
                removal is staged for the user.
                """,
            inputSchema: schema(
                ["label": string("The macro's label, without the `&`, as given by list_macros.")],
                required: ["label"]
            )
        ),
        ClaudeTool(
            name: Name.addLayer,
            description: """
                Stages a new layer. Layers are numbered from 0 and a new one \
                added anywhere but the end renumbers every layer after it, while \
                `&mo 2` and `&lt 3 TAB` elsewhere in the file go on saying 2 and \
                3 — so they end up pointing at different layers. Add at the end \
                unless the user asked otherwise, and tell them what gets \
                renumbered either way. This does NOT edit the keymap — the new \
                layer is staged for the user.
                """,
            inputSchema: schema(
                [
                    "name": string("The layer's display name, e.g. `Nav`."),
                    "position": integer("""
                        Layer number the new layer takes. Omit to add it at the end, \
                        which renumbers nothing.
                        """),
                    "node_name": string("""
                        The devicetree node name, e.g. `nav_layer`. Omit to derive one \
                        from the display name.
                        """),
                    "bindings": strings("""
                        What the layer binds, one entry per key position in order, \
                        starting at position 0. Omit to fill the layer with `&trans`, \
                        which is usually what you want — a new layer that falls \
                        through to the one below.
                        """),
                ],
                required: ["name"]
            )
        ),
        ClaudeTool(
            name: Name.removeLayer,
            description: """
                Stages the removal of a layer. Every layer after it moves down a \
                number, while `&mo`, `&lt`, `&to` and combos elsewhere in the \
                file keep the numbers they were written with — so they end up \
                pointing at different layers. The answer lists what is affected; \
                tell the user before they apply it. This does NOT edit the keymap \
                — the removal is staged for the user.
                """,
            inputSchema: schema(
                ["layer": integer("Layer number to remove, as reported by list_layers.")],
                required: ["layer"]
            )
        ),
    ]

    /// How a call reads in the "what it did" disclosure: `read_layer(layer: 1)`.
    public static func label(for use: ClaudeToolUse) -> String {
        let arguments = (use.input.objectValue ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.jsonText)" }
            .joined(separator: ", ")
        return "\(use.name)(\(arguments))"
    }

    // MARK: - Execution

    public static func run(
        _ use: ClaudeToolUse, context: KeymapContext, staged: [ProposedEdit]
    ) -> Outcome {
        switch use.name {
        case Name.listLayers:
            return answer(use, KeymapDigest.layers(context.layers))
        case Name.readLayer:
            return readLayer(use, context: context)
        case Name.listCombos:
            return answer(use, KeymapDigest.combos(context.combos, keymap: context.keymap))
        case Name.findKeycodes:
            return findKeycodes(use, context: context)
        case Name.listBehaviors:
            return answer(use, behaviorList(context))
        case Name.listBehaviorsDefined:
            return answer(use, definedBehaviorList(context))
        case Name.listMacros:
            return answer(use, macroList(context))
        case Name.readKeymapSource:
            return readKeymapSource(use, context: context)
        case Name.setBinding:
            return setBinding(use, context: context)
        case Name.setCombo:
            return setCombo(use, context: context, staged: staged)
        case Name.removeCombo:
            return removeCombo(use, context: context, staged: staged)
        case Name.renameLayer:
            return renameLayer(use, context: context)
        case Name.setBehavior:
            return setBehavior(use, context: context, staged: staged)
        case Name.removeBehavior:
            return removeBehavior(use, context: context, staged: staged)
        case Name.setMacro:
            return setMacro(use, context: context, staged: staged)
        case Name.removeMacro:
            return removeMacro(use, context: context, staged: staged)
        case Name.addLayer:
            return addLayer(use, context: context)
        case Name.removeLayer:
            return removeLayer(use, context: context)
        default:
            // Only ``all`` is ever sent, so this is the API echoing back a name
            // nothing here declares. Saying so is more use than a generic error.
            return failure(use, "there is no tool called `\(use.name)`")
        }
    }

    // MARK: - Read tools

    private static func readLayer(_ use: ClaudeToolUse, context: KeymapContext) -> Outcome {
        guard let index = field(use, "layer")?.intValue else {
            return badArgument(use, "layer", "an integer")
        }
        guard let layer = layer(index, in: context) else {
            return failure(use, noSuchLayer(index, in: context))
        }
        return answer(use, """
            Layer \(layer.id), "\(layer.displayName)".

            \(KeymapDigest.layer(layer, layout: context.layout))
            """)
    }

    private static func findKeycodes(_ use: ClaudeToolUse, context: KeymapContext) -> Outcome {
        guard let query = field(use, "query")?.stringValue,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return badArgument(use, "query", "a non-empty string")
        }

        // The same match the keycode picker makes, so a keycode the assistant
        // recommends is one the user finds by typing the same string.
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = needle.lowercased()
        let matches = context.keycodes.filter { $0.matches(folded) }
        guard !matches.isEmpty else {
            return answer(use, "No keycode matches \"\(needle)\".")
        }

        let lines = matches.prefix(keycodeLimit).map { keycode -> String in
            let aliases = keycode.names.dropFirst()
            var line = keycode.primaryName
            if !aliases.isEmpty { line += " (also \(aliases.joined(separator: ", ")))" }
            if let description = keycode.description { line += " — \(description)" }
            if let context = keycode.context { line += " [\(context)]" }
            return line
        }
        let header = matches.count > keycodeLimit
            ? "\(matches.count) keycodes match \"\(needle)\"; the first \(keycodeLimit) are listed. Narrow the query to see the rest."
            : "\(matches.count) keycode(s) match \"\(needle)\"."
        return answer(use, ([header] + lines).joined(separator: "\n"))
    }

    private static func behaviorList(_ context: KeymapContext) -> String {
        guard !context.availableBehaviors.isEmpty else {
            return "The behavior list has not loaded; no keymap is open yet."
        }
        return context.availableBehaviors.map { behavior -> String in
            let params = behavior.params ?? []
            let shape = params.isEmpty
                ? "no parameters"
                : params.map(\.rawValue).joined(separator: ", ")
            let origin = context.isDocumentedBehavior(behavior.code) ? "" : " (defined by this keymap)"
            return "\(behavior.code) — \(behavior.name)\(origin): \(shape)"
        }
        .joined(separator: "\n")
    }

    private static func definedBehaviorList(_ context: KeymapContext) -> String {
        guard let keymap = context.keymap else { return noKeymap }
        guard !keymap.behaviors.isEmpty else {
            return """
                This keymap defines no behaviors of its own. Everything it binds \
                comes from ZMK; use set_behavior to define one.
                """
        }
        return keymap.behaviors.map { behavior in
            "&\(behavior.label) (node `\(behavior.nodeName)`, \(behavior.bindingCells) parameter(s)) — "
                + summary(of: behavior)
        }
        .joined(separator: "\n")
    }

    private static func macroList(_ context: KeymapContext) -> String {
        guard let keymap = context.keymap else { return noKeymap }
        guard !keymap.macros.isEmpty else {
            return "This keymap defines no macros. Use set_macro to define one."
        }
        return keymap.macros.map { macro in
            "&\(macro.label) (node `\(macro.nodeName)`, \(macro.bindingCells) parameter(s)) — "
                + summary(of: macro, sequenceLimit: nil)
        }
        .joined(separator: "\n")
    }

    /// The `.keymap` as text, straight out of the parsed document.
    ///
    /// The document's bytes rather than the file on disk, deliberately. They are
    /// the same bytes every `SourceEdit` offset is measured against, so what the
    /// model reads here is what the editor is working on. A model reasoning
    /// about a file it re-read from disk would be reasoning about different
    /// bytes the moment anything was unsaved — which is the mistake this tool
    /// exists to prevent, so the answer says when there are unsaved edits rather
    /// than leaving it to be discovered.
    private static func readKeymapSource(_ use: ClaudeToolUse, context: KeymapContext) -> Outcome {
        guard let keymap = context.keymap else { return failure(use, noKeymap) }

        let source = String(decoding: keymap.document.source, as: UTF8.self)
        let lines = source.components(separatedBy: "\n")

        var start = 0
        switch integerArgument(use, "from_line") {
        case .failure(let outcome): return outcome
        case .absent: break
        case .value(let from):
            guard from >= 1 else {
                return failure(use, "`from_line` counts from 1, so \(from) is not a line")
            }
            guard from <= lines.count else {
                return failure(use, """
                    `from_line` is \(from) but \(name(of: context)) has only \
                    \(lines.count) lines
                    """)
            }
            start = from - 1
        }

        // Clipped on a line boundary rather than mid-token: half a `#define` is
        // worse than an honest "there is more". The first line is always
        // included even if it alone is over the limit, so a file of one enormous
        // line still answers with something.
        var shown: [String] = []
        var characters = 0
        var index = start
        while index < lines.count {
            let line = lines[index]
            if !shown.isEmpty, characters + line.count + 1 > sourceCharacterLimit { break }
            shown.append(line)
            characters += line.count + 1
            index += 1
        }

        var header = "\(name(of: context)), \(lines.count) line(s)"
        if start > 0 || index < lines.count {
            header += ", showing lines \(start + 1) to \(index)"
        }
        header += "."
        if index < lines.count {
            header += """
                 The rest is not shown; call read_keymap_source again with \
                from_line: \(index + 1) for the next part.
                """
        }
        if context.hasUnsavedEdits {
            header += """
                 Note: there are edits in the editor that are not yet saved, so \
                this text is the file as it was last parsed. The layer, combo, \
                behavior and macro tools show the current state.
                """
        }

        return answer(use, "\(header)\n\n\(shown.joined(separator: "\n"))")
    }

    private static func name(of context: KeymapContext) -> String {
        context.keymapRelativePath.map { "`\($0)`" } ?? "the keymap"
    }

    // MARK: - Describing behaviors and macros

    /// One behavior in a phrase: "hold-tap — holds `&kp`, taps `&kp`,
    /// tapping-term-ms 280". Shared with the app's proposal cards so the tool
    /// result the model reads and the card the user reads say the same thing.
    public static func summary(of behavior: KeymapBehavior) -> String {
        let kind = BehaviorKind.kind(forCompatible: behavior.compatible)
        var parts: [String] = []
        if kind == .holdTap, behavior.bindings.count == 2 {
            // A hold-tap's `bindings` is hold first, tap second, and getting
            // that backwards in a description is worse than not saying it.
            parts.append("holds `\(behavior.bindings[0])`, taps `\(behavior.bindings[1])`")
        } else if !behavior.bindings.isEmpty {
            parts.append("wraps \(behavior.bindings.map { "`\($0)`" }.joined(separator: ", "))")
        }
        parts += behavior.properties.map { "\($0.name) \(text($0.value))" }
        let head = kind?.displayName ?? behavior.compatible
        return parts.isEmpty ? head : "\(head) — \(parts.joined(separator: ", "))"
    }

    /// One macro in a phrase. `sequenceLimit` caps how many steps are spelled
    /// out; nil spells out all of them, which is what `list_macros` wants and
    /// what a card in a chat bubble does not.
    public static func summary(of macro: KeymapMacro, sequenceLimit: Int?) -> String {
        var parts: [String] = []
        let steps = macro.bindings.map(\.text)
        if let limit = sequenceLimit, steps.count > limit {
            parts.append(
                "\(steps.prefix(limit).joined(separator: " ")) … (\(steps.count) steps)"
            )
        } else {
            parts.append(steps.isEmpty ? "no steps" : steps.joined(separator: " "))
        }
        if let wait = macro.waitMs { parts.append("wait \(wait) ms") }
        if let tap = macro.tapMs { parts.append("tap \(tap) ms") }
        return parts.joined(separator: ", ")
    }

    /// A property value as a human reads it, not as devicetree writes it —
    /// `BehaviorWriter.line` is for the file, this is for a sentence.
    public static func text(_ value: BehaviorValue) -> String {
        switch value {
        case .integer(let number): "\(number)"
        case .string(let string): "\"\(string)\""
        case .integers(let numbers): numbers.map(String.init).joined(separator: " ")
        case .references(let references): references.joined(separator: ", ")
        // Preprocessor macros the file wrote and the editor could not resolve.
        // Shown as they are written, because that is the only thing about them
        // that is known to be true.
        case .tokens(let tokens): tokens.joined(separator: " ")
        case .flag: "yes"
        }
    }

    // MARK: - Edit tools

    private static func setBinding(_ use: ClaudeToolUse, context: KeymapContext) -> Outcome {
        guard let layerIndex = field(use, "layer")?.intValue else {
            return badArgument(use, "layer", "an integer")
        }
        guard let layer = layer(layerIndex, in: context) else {
            return failure(use, noSuchLayer(layerIndex, in: context))
        }
        guard let position = field(use, "key_position")?.intValue else {
            return badArgument(use, "key_position", "an integer")
        }
        guard layer.bindings.indices.contains(position) else {
            return failure(use, """
                layer \(layerIndex) has no key position \(position); it binds \
                \(layer.bindings.count) keys, numbered 0 to \(layer.bindings.count - 1)
                """)
        }
        guard let text = field(use, "binding")?.stringValue else {
            return badArgument(use, "binding", "a string")
        }
        let binding: KeyBinding
        switch parseBinding(text) {
        case .success(let parsed): binding = parsed
        case .failure(let reason): return failure(use, reason)
        }

        let previous = layer.bindings[position].text
        return Outcome(
            result: ClaudeToolResult(toolUseID: use.id, content: """
                Staged for the user's approval; not applied. Layer \(layerIndex) \
                key \(position) would change from `\(previous)` to `\(binding.text)`.
                """),
            staged: .setBinding(layer: layerIndex, index: position, binding: binding)
        )
    }

    private static func setCombo(
        _ use: ClaudeToolUse, context: KeymapContext, staged: [ProposedEdit]
    ) -> Outcome {
        guard let keymap = context.keymap else { return failure(use, noKeymap) }
        guard let name = field(use, "name")?.stringValue,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return badArgument(use, "name", "a non-empty string")
        }

        // Start from what already exists, so properties the call does not
        // mention survive — including `sourcePositionTokens` and
        // `unresolvedPositions`, which are how a combo written with `POS_*`
        // macros keeps them when something else about it is edited.
        var combo: KeymapCombo
        let isNew: Bool
        if let existing = stagedCombo(named: name, in: staged) ?? context.combos.first(where: { $0.nodeName == name }) {
            combo = existing
            isNew = false
        } else {
            guard field(use, "binding") != nil, field(use, "key_positions") != nil else {
                return failure(use, """
                    there is no combo named `\(name)`, so this call would create \
                    one — which needs both `key_positions` and `binding`. The \
                    combos this keymap has are: \(comboNames(context))
                    """)
            }
            combo = KeymapCombo(
                nodeName: keymap.uniqueComboName(startingFrom: name),
                binding: KeyBinding(behavior: "&none"),
                keyPositions: []
            )
            isNew = true
        }

        switch stringArgument(use, "binding") {
        case .failure(let outcome): return outcome
        case .absent: break
        case .value(let text):
            switch parseBinding(text) {
            case .success(let parsed): combo.binding = parsed
            case .failure(let reason): return failure(use, reason)
            }
        }

        switch arrayArgument(use, "key_positions", "an array of integers") {
        case .failure(let outcome): return outcome
        case .absent: break
        case .value(let positions):
            let numbers = positions.compactMap(\.intValue)
            guard numbers.count == positions.count else {
                return failure(use, "every entry in `key_positions` must be an integer")
            }
            guard numbers.count >= 2 else {
                return failure(use, "a combo needs at least two key positions; \(numbers.count) were given")
            }
            let keyCount = context.layout.count
            if keyCount > 0, let outside = numbers.first(where: { $0 < 0 || $0 >= keyCount }) {
                return failure(use, """
                    key position \(outside) is not on this keyboard; it has \
                    \(keyCount) keys, numbered 0 to \(keyCount - 1)
                    """)
            }
            combo.keyPositions = numbers
        }

        switch arrayArgument(use, "layers", "an array of integers") {
        case .failure(let outcome): return outcome
        case .absent: break
        case .value(let layers):
            let numbers = layers.compactMap(\.intValue)
            guard numbers.count == layers.count else {
                return failure(use, "every entry in `layers` must be an integer")
            }
            if let outside = numbers.first(where: { layer($0, in: context) == nil }) {
                return failure(use, noSuchLayer(outside, in: context))
            }
            combo.layers = numbers
        }

        switch integerArgument(use, "timeout_ms") {
        case .failure(let outcome): return outcome
        case .absent: break
        case .value(let timeout):
            guard timeout > 0 else {
                return failure(use, "`timeout_ms` must be greater than zero; \(timeout) was given")
            }
            combo.timeoutMs = timeout
        }

        // `uniqueComboName` sanitizes, so a name devicetree would reject comes
        // back changed. Say so rather than let the model go on believing the
        // combo is called what it asked for.
        let renamed = isNew && combo.nodeName != name
            ? " The name was adjusted to `\(combo.nodeName)`, because devicetree node names allow only letters, digits and `,._+-`."
            : ""
        let verb = isNew ? "create a combo" : "change the combo"
        return Outcome(
            result: ClaudeToolResult(toolUseID: use.id, content: """
                Staged for the user's approval; not applied. It would \(verb) \
                `\(combo.nodeName)`: keys \
                <\(combo.keyPositions.map(String.init).joined(separator: " "))> \
                → \(combo.binding.text).\(renamed)
                """),
            staged: .setCombo(combo)
        )
    }

    private static func removeCombo(
        _ use: ClaudeToolUse, context: KeymapContext, staged: [ProposedEdit]
    ) -> Outcome {
        guard let name = field(use, "name")?.stringValue else {
            return badArgument(use, "name", "a string")
        }
        return stageRemoval(
            use,
            named: "`\(name)`",
            pending: stagedCombo(named: name, in: staged),
            in: context.combos,
            matching: { $0.nodeName == name },
            unstage: { ProposedEdit.setCombo($0).id },
            notFound: "there is no combo named `\(name)`. This keymap has: \(comboNames(context))",
            describe: { "the combo `\(name)` (\($0.binding.text))" },
            removal: { .removeCombo(id: $0.id) }
        )
    }

    private static func renameLayer(_ use: ClaudeToolUse, context: KeymapContext) -> Outcome {
        guard let index = field(use, "layer")?.intValue else {
            return badArgument(use, "layer", "an integer")
        }
        guard let layer = layer(index, in: context) else {
            return failure(use, noSuchLayer(index, in: context))
        }
        guard let raw = field(use, "name")?.stringValue else {
            return badArgument(use, "name", "a string")
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The same rule `KeymapFile.setLayerDisplayName` enforces, asked of the
        // same function. Catching it here means the model gets to fix it, rather
        // than the user meeting the error when they click Apply.
        if let problem = KeymapFile.displayNameProblem(name) {
            return failure(use, problem)
        }
        guard name != layer.displayName else {
            return failure(use, "layer \(index) is already called \"\(name)\"")
        }
        return Outcome(
            result: ClaudeToolResult(toolUseID: use.id, content: """
                Staged for the user's approval; not applied. Layer \(index) would \
                be renamed from "\(layer.displayName)" to "\(name)".
                """),
            staged: .renameLayer(layer: index, name: name)
        )
    }

    private static func setBehavior(
        _ use: ClaudeToolUse, context: KeymapContext, staged: [ProposedEdit]
    ) -> Outcome {
        guard let keymap = context.keymap else { return failure(use, noKeymap) }
        guard let label = reference(use, "label") else {
            return badArgument(use, "label", "a non-empty string")
        }

        var kind: BehaviorKind?
        if field(use, "kind") != nil {
            switch behaviorKind(use) {
            case .success(let parsed): kind = parsed
            case .failure(let reason): return failure(use, reason)
            }
        }

        // Same shape as `setCombo`: start from what exists so untouched fields
        // survive, and reuse its id so a second call about the same `&label`
        // replaces the staged proposal rather than staging a second node.
        var behavior: KeymapBehavior
        let isNew: Bool
        if let existing = stagedBehavior(labelled: label, in: staged)
            ?? keymap.behaviors.first(where: { $0.label == label })
        {
            behavior = existing
            isNew = false
        } else {
            guard let kind else {
                return failure(use, """
                    there is no behavior labelled `&\(label)`, so this call would \
                    define one — which needs `kind`. This keymap defines: \
                    \(behaviorLabels(keymap))
                    """)
            }
            // A caps-word or a key-repeat has no `bindings` property at all, so
            // demanding one would refuse to create the two kinds that need it
            // least.
            guard !kind.bindings.isWritten || field(use, "bindings") != nil else {
                return failure(use, """
                    defining a new behavior needs `bindings` — the behaviors \
                    `&\(label)` wraps. A \(kind.displayName) takes \
                    \(shape(of: kind.bindings)).
                    """)
            }
            behavior = KeymapBehavior(
                nodeName: uniqueNodeName(from: label, in: keymap),
                label: label,
                compatible: kind.compatible,
                bindingCells: kind.bindingCells,
                bindings: [],
                properties: []
            )
            isNew = true
        }

        // `#binding-cells` is fixed by the kind rather than chosen — upstream
        // declares it a `const` — so changing the kind carries it along.
        if let kind {
            behavior.compatible = kind.compatible
            behavior.bindingCells = kind.bindingCells
        }

        switch arrayArgument(use, "bindings", "an array of strings") {
        case .failure(let outcome): return outcome
        case .absent: break
        case .value(let raw):
            // A hold-tap's entries are bare references and a mod-morph's carry
            // parameters. Which it is comes from the kind, so the message can
            // say what this behavior wants rather than one blanket rule.
            let allowsParameters = behavior.kind?.bindings.allowsParameters ?? true
            var references: [String] = []
            for entry in raw {
                guard let text = entry.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                else {
                    return failure(use, "every entry in `bindings` must be a string")
                }
                guard text.hasPrefix("&") else {
                    return failure(use, "`\(text)` is not a behavior reference; those start with `&`")
                }
                guard allowsParameters || !text.contains(" ") else {
                    return failure(use, """
                        `\(text)` gives a parameter to a behavior that must not \
                        take one here. A \(behavior.kind?.displayName ?? "behavior") \
                        names the behaviors it wraps and nothing else — `&kp`, not \
                        `&kp A`. The parameters come from whatever binds `&\(label)`.
                        """)
                }
                references.append(text)
            }
            behavior.bindings = references
        }

        switch integerArgument(use, "binding_cells") {
        case .failure(let outcome): return outcome
        case .absent: break
        // Checked against the kind by `BehaviorWriter.problems`, along with
        // everything else that would not write — one place, one set of
        // messages.
        case .value(let cells): behavior.bindingCells = cells
        }

        switch objectArgument(use, "properties", "an object of property names and values") {
        case .failure(let outcome): return outcome
        case .absent: break
        case .value(let properties):
            switch behaviorProperties(properties, merging: behavior.properties) {
            case .success(let merged): behavior.properties = merged
            case .failure(let reason): return failure(use, reason)
            }
        }

        // Validated before staging, not at Apply. A behavior that cannot be
        // written is a mistake the model can still fix; the same mistake found
        // when the user presses Apply is a card that fails in front of them.
        let problems = BehaviorWriter.problems(with: behavior)
        guard problems.isEmpty else {
            return failure(use, """
                `&\(label)` cannot be written as it stands: \
                \(problems.joined(separator: "; "))
                """)
        }

        let renamed = isNew && behavior.nodeName != label
            ? " Its devicetree node is named `\(behavior.nodeName)`."
            : ""
        let verb = isNew ? "define the behavior" : "change the behavior"
        return Outcome(
            result: ClaudeToolResult(toolUseID: use.id, content: """
                Staged for the user's approval; not applied. It would \(verb) \
                `&\(label)` — \(summary(of: behavior)). A binding of it takes \
                \(behavior.bindingCells) parameter(s).\(renamed)
                """),
            staged: .setBehavior(behavior)
        )
    }

    private static func removeBehavior(
        _ use: ClaudeToolUse, context: KeymapContext, staged: [ProposedEdit]
    ) -> Outcome {
        guard let keymap = context.keymap else { return failure(use, noKeymap) }
        guard let label = reference(use, "label") else {
            return badArgument(use, "label", "a non-empty string")
        }
        return stageRemoval(
            use,
            named: "`&\(label)`",
            pending: stagedBehavior(labelled: label, in: staged),
            in: keymap.behaviors,
            matching: { $0.label == label },
            unstage: { ProposedEdit.setBehavior($0).id },
            notFound: """
                this keymap defines no behavior labelled `&\(label)`. It defines: \
                \(behaviorLabels(keymap))
                """,
            describe: { "the behavior `&\(label)` (\(summary(of: $0)))" },
            note: usage(of: "&\(label)", in: context),
            removal: { .removeBehavior(id: $0.id) }
        )
    }

    private static func setMacro(
        _ use: ClaudeToolUse, context: KeymapContext, staged: [ProposedEdit]
    ) -> Outcome {
        guard let keymap = context.keymap else { return failure(use, noKeymap) }
        guard let label = reference(use, "label") else {
            return badArgument(use, "label", "a non-empty string")
        }

        // The parameter count and the `compatible` are the same fact told twice,
        // and `MacroWriter.problems` rejects a node where they disagree — so the
        // count picks the kind rather than being carried alongside it.
        var kind: MacroKind?
        switch integerArgument(use, "parameters") {
        case .failure(let outcome): return outcome
        case .absent: break
        case .value(let count):
            guard let parsed = MacroKind.allCases.first(where: { $0.bindingCells == count }) else {
                return failure(use, "`parameters` must be 0, 1 or 2; \(count) was given")
            }
            kind = parsed
        }

        var macro: KeymapMacro
        let isNew: Bool
        if let existing = stagedMacro(labelled: label, in: staged)
            ?? keymap.macros.first(where: { $0.label == label })
        {
            macro = existing
            isNew = false
        } else {
            guard field(use, "bindings") != nil else {
                return failure(use, """
                    there is no macro labelled `&\(label)`, so this call would \
                    define one — which needs `bindings`, the sequence it plays. \
                    This keymap defines: \(macroLabels(keymap))
                    """)
            }
            let shape = kind ?? .plain
            macro = KeymapMacro(
                nodeName: uniqueNodeName(from: label, in: keymap),
                label: label,
                compatible: shape.compatible,
                bindingCells: shape.bindingCells,
                bindings: [],
                waitMs: nil,
                tapMs: nil
            )
            isNew = true
        }

        if let kind {
            macro.compatible = kind.compatible
            macro.bindingCells = kind.bindingCells
        }

        switch arrayArgument(use, "bindings", "an array of strings") {
        case .failure(let outcome): return outcome
        case .absent: break
        case .value(let raw):
            // A macro's sequence is one long cell, so an entry holding several
            // bindings is not a mistake to reject — it is how a keymap writes
            // `&macro_tap &kp A &kp B`. Flatten in order.
            var sequence: [KeyBinding] = []
            for entry in raw {
                guard let text = entry.stringValue else {
                    return failure(use, "every entry in `bindings` must be a string")
                }
                let parsed = BindingParser.parse(text)
                guard !parsed.isEmpty else {
                    return failure(use, """
                        `\(text)` is not a ZMK binding. Every step of a macro \
                        starts with `&`, e.g. `&kp A` or `&macro_tap`.
                        """)
                }
                sequence += parsed
            }
            macro.bindings = sequence
        }

        // A negative wait or tap is caught by `MacroWriter.problems` below,
        // under the property's devicetree name — one check, one wording.
        switch integerArgument(use, "wait_ms") {
        case .failure(let outcome): return outcome
        case .absent: break
        case .value(let wait): macro.waitMs = wait
        }

        switch integerArgument(use, "tap_ms") {
        case .failure(let outcome): return outcome
        case .absent: break
        case .value(let tap): macro.tapMs = tap
        }

        let problems = MacroWriter.problems(with: macro)
        guard problems.isEmpty else {
            return failure(use, """
                `&\(label)` cannot be written as it stands: \
                \(problems.joined(separator: "; "))
                """)
        }

        let renamed = isNew && macro.nodeName != label
            ? " Its devicetree node is named `\(macro.nodeName)`."
            : ""
        let verb = isNew ? "define the macro" : "change the macro"
        return Outcome(
            result: ClaudeToolResult(toolUseID: use.id, content: """
                Staged for the user's approval; not applied. It would \(verb) \
                `&\(label)` — \(summary(of: macro, sequenceLimit: nil)). A binding \
                of it takes \(macro.bindingCells) parameter(s).\(renamed)
                """),
            staged: .setMacro(macro)
        )
    }

    private static func removeMacro(
        _ use: ClaudeToolUse, context: KeymapContext, staged: [ProposedEdit]
    ) -> Outcome {
        guard let keymap = context.keymap else { return failure(use, noKeymap) }
        guard let label = reference(use, "label") else {
            return badArgument(use, "label", "a non-empty string")
        }

        return stageRemoval(
            use,
            named: "`&\(label)`",
            pending: stagedMacro(labelled: label, in: staged),
            in: keymap.macros,
            matching: { $0.label == label },
            unstage: { ProposedEdit.setMacro($0).id },
            notFound: """
                this keymap defines no macro labelled `&\(label)`. It defines: \
                \(macroLabels(keymap))
                """,
            describe: { "the macro `&\(label)` (\(summary(of: $0, sequenceLimit: 6)))" },
            note: usage(of: "&\(label)", in: context),
            removal: { .removeMacro(id: $0.id) }
        )
    }

    private static func addLayer(_ use: ClaudeToolUse, context: KeymapContext) -> Outcome {
        guard let keymap = context.keymap else { return failure(use, noKeymap) }
        guard let raw = field(use, "name")?.stringValue else {
            return badArgument(use, "name", "a string")
        }
        let displayName = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = KeymapFile.displayNameProblem(displayName) {
            return failure(use, problem)
        }

        var index = context.layers.count
        switch integerArgument(use, "position") {
        case .failure(let outcome): return outcome
        case .absent: break
        case .value(let position):
            guard (0...context.layers.count).contains(position) else {
                return failure(use, """
                    a new layer can go anywhere from 0 to \(context.layers.count) — \
                    this keymap has \(context.layers.count) layers — but \(position) \
                    was given
                    """)
            }
            index = position
        }

        // The key count comes from the layout, or from an existing layer when
        // no layout is loaded. Guessing it would put a layer of the wrong length
        // into the file, which does not build.
        let keyCount = context.layout.isEmpty ? context.layers.first?.bindings.count : context.layout.count

        var bindings: [KeyBinding]
        switch arrayArgument(use, "bindings", "an array of strings") {
        case .failure(let outcome): return outcome
        case .value(let raw):
            var parsed: [KeyBinding] = []
            for entry in raw {
                guard let text = entry.stringValue else {
                    return failure(use, "every entry in `bindings` must be a string")
                }
                switch parseBinding(text) {
                case .success(let binding): parsed.append(binding)
                case .failure(let reason): return failure(use, reason)
                }
            }
            if let keyCount, parsed.count != keyCount {
                return failure(use, """
                    this keyboard has \(keyCount) key positions, so a layer needs \
                    \(keyCount) bindings; \(parsed.count) were given. Use `&trans` \
                    for the keys the layer does not change.
                    """)
            }
            bindings = parsed
        case .absent:
            guard let keyCount else {
                return failure(use, """
                    no keyboard layout is loaded and there is no existing layer to \
                    take a key count from, so `bindings` has to be given in full
                    """)
            }
            bindings = Array(repeating: KeyBinding(behavior: "&trans"), count: keyCount)
        }

        let nodeName: String
        switch stringArgument(use, "node_name") {
        case .failure(let outcome): return outcome
        case .value(let given):
            nodeName = given.trimmingCharacters(in: .whitespacesAndNewlines)
            guard KeymapCombo.isValidNodeName(nodeName) else {
                return failure(use, """
                    `\(nodeName)` is not a devicetree node name; those are letters, \
                    digits and `,._+-`, starting with a letter or a digit
                    """)
            }
            guard !keymap.modelledNodeNames.contains(nodeName) else {
                return failure(use, "this keymap already has a node called `\(nodeName)`")
            }
        case .absent:
            nodeName = uniqueNodeName(from: "\(displayName) layer", in: keymap)
        }

        let affected = keymap.layerReferencesAffected(byInsertingAt: index)
        let placement = index == context.layers.count
            ? "It goes at the end, so no existing layer is renumbered."
            : "Layer \(index) and everything after it moves up one number."
        return Outcome(
            result: ClaudeToolResult(toolUseID: use.id, content: """
                Staged for the user's approval; not applied. It would add layer \
                \(index), "\(displayName)" (node `\(nodeName)`), binding \
                \(bindings.count) keys. \(placement) \
                \(renumbering(affected) ?? "Nothing elsewhere in the keymap names a layer number that moves.") \
                Tell the user this before they apply it.
                """),
            staged: .addLayer(
                nodeName: nodeName, displayName: displayName, bindings: bindings, at: index
            )
        )
    }

    private static func removeLayer(_ use: ClaudeToolUse, context: KeymapContext) -> Outcome {
        guard let keymap = context.keymap else { return failure(use, noKeymap) }
        guard let index = field(use, "layer")?.intValue else {
            return badArgument(use, "layer", "an integer")
        }
        guard let layer = layer(index, in: context) else {
            return failure(use, noSuchLayer(index, in: context))
        }
        guard context.layers.count > 1 else {
            return failure(use, """
                a keymap needs at least one layer, and this is the only one left
                """)
        }

        let affected = keymap.layerReferencesAffected(byRemoving: index)
        let moved = index == context.layers.count - 1
            ? "It is the last layer, so no other layer is renumbered."
            : "Every layer after it moves down one number."
        return Outcome(
            result: ClaudeToolResult(toolUseID: use.id, content: """
                Staged for the user's approval; not applied. It would remove layer \
                \(index), "\(layer.displayName)", and the \(layer.bindings.count) \
                keys it binds. \(moved) \
                \(renumbering(affected) ?? "Nothing elsewhere in the keymap names a layer number that moves.") \
                Tell the user this before they apply it.
                """),
            staged: .removeLayer(at: index)
        )
    }

    /// What `remove_combo`, `remove_behavior` and `remove_macro` all do.
    ///
    /// An item staged for creation this turn is not in the file, so there is
    /// nothing to remove — the creation is un-staged instead. Staging a removal
    /// of it would fail on apply with "no such combo", which is true and
    /// useless.
    ///
    /// `note` is the sentence that follows the answer: for a behavior and a
    /// macro it says what still binds them, and a combo has nothing to add.
    private static func stageRemoval<Item: Identifiable>(
        _ use: ClaudeToolUse,
        named display: String,
        pending: Item?,
        in live: [Item],
        matching: (Item) -> Bool,
        unstage: (Item) -> ProposedEdit.ID,
        notFound: String,
        describe: (Item) -> String,
        note: String? = nil,
        removal: (Item) -> ProposedEdit
    ) -> Outcome {
        if let pending, !live.contains(where: { $0.id == pending.id }) {
            return Outcome(
                result: ClaudeToolResult(toolUseID: use.id, content: """
                    \(display) had only been staged for creation, not created, so \
                    it is no longer staged. Nothing was removed from the keymap.
                    """),
                unstage: unstage(pending)
            )
        }

        guard let item = live.first(where: matching) else { return failure(use, notFound) }
        return Outcome(
            result: ClaudeToolResult(toolUseID: use.id, content: """
                Staged for the user's approval; not applied. It would remove \
                \(describe(item)).\(note.map { " \($0)" } ?? "")
                """),
            staged: removal(item)
        )
    }

    // MARK: - Layer renumbering

    /// The sentence a user has to read before applying a layer insert or
    /// removal. `KeymapFile` cannot rewrite `&mo 2` safely — it may sit inside a
    /// macro or a node the editor does not model — so the bindings that name a
    /// number that moves are named instead, both here and on the card.
    public static func renumbering(_ affected: [String]) -> String? {
        guard !affected.isEmpty else { return nil }
        return """
            These keep the layer number they were written with and will point at \
            a different layer: \(affected.joined(separator: "; ")).
            """
    }

    // MARK: - Shared validation

    private static func layer(_ index: Int, in context: KeymapContext) -> KeymapLayer? {
        context.layers.indices.contains(index) ? context.layers[index] : nil
    }

    private static func noSuchLayer(_ index: Int, in context: KeymapContext) -> String {
        guard !context.layers.isEmpty else { return noKeymap }
        return """
            layer \(index) does not exist; this keymap has \(context.layers.count) \
            layers, numbered 0 to \(context.layers.count - 1)
            """
    }

    private static let noKeymap = "no keymap is open, so there is nothing to read or change"

    /// Things the model can name, as a sentence fragment: "`a`, `b`" — or
    /// "none", because an empty list has to read as an answer rather than as a
    /// message that trails off.
    private static func list<Item>(_ items: [Item], _ describe: (Item) -> String) -> String {
        items.isEmpty ? "none" : items.map(describe).joined(separator: ", ")
    }

    private static func comboNames(_ context: KeymapContext) -> String {
        list(context.combos) { "`\($0.nodeName)`" }
    }

    private static func stagedCombo(named name: String, in staged: [ProposedEdit]) -> KeymapCombo? {
        for case .setCombo(let combo) in staged where combo.nodeName == name { return combo }
        return nil
    }

    private static func stagedBehavior(
        labelled label: String, in staged: [ProposedEdit]
    ) -> KeymapBehavior? {
        for case .setBehavior(let behavior) in staged where behavior.label == label { return behavior }
        return nil
    }

    private static func stagedMacro(labelled label: String, in staged: [ProposedEdit]) -> KeymapMacro? {
        for case .setMacro(let macro) in staged where macro.label == label { return macro }
        return nil
    }

    private static func behaviorLabels(_ keymap: KeymapFile) -> String {
        list(keymap.behaviors) { "`&\($0.label)`" }
    }

    private static func macroLabels(_ keymap: KeymapFile) -> String {
        list(keymap.macros) { "`&\($0.label)`" }
    }

    /// What still refers to a behavior or macro about to be removed.
    ///
    /// Every reference the editor models is walked: a layer's bindings, a
    /// combo's binding, another behavior's `bindings` and its phandle-list
    /// properties, and a macro's sequence. A hold-tap wrapping the thing being
    /// removed used to go unmentioned, which is worse than saying nothing —
    /// the answer read as "nothing binds it".
    ///
    /// What is still *not* walked is devicetree this editor does not model: a
    /// node override outside the keymap's own nodes, a `#define` that expands
    /// to a reference, a node no reader claims. So the sentence keeps saying
    /// where it looked rather than declaring the thing unused.
    static func usage(of behavior: String, in context: KeymapContext) -> String {
        let label = behavior.hasPrefix("&") ? String(behavior.dropFirst()) : behavior
        let reference = "&" + label

        /// True when a devicetree cell — `&kp`, `&hml LSHFT A`, or a whole
        /// `<&mo>, <&sk>` entry — invokes the thing being removed.
        func refers(_ text: String) -> Bool {
            BindingParser.parse(text).contains { $0.behavior == reference }
        }

        var sites: [String] = []
        for layer in context.layers {
            let positions = layer.bindings.indices.filter { layer.bindings[$0].behavior == reference }
            guard !positions.isEmpty else { continue }
            sites.append("""
                layer \(layer.id) key\(positions.count == 1 ? "" : "s") \
                \(positions.map(String.init).joined(separator: ", "))
                """)
        }
        for combo in context.combos where combo.binding.behavior == reference {
            sites.append("combo `\(combo.nodeName)`")
        }
        // A behavior does not refer to itself, and the one being removed is
        // going away anyway — skipping it keeps "&ht is bound inside &ht" out
        // of an answer about removing `&ht`.
        for other in context.keymap?.behaviors ?? [] where other.label != label {
            if other.bindings.contains(where: refers) {
                sites.append("the `bindings` of the behavior `&\(other.label)`")
            }
            for property in other.properties {
                guard case .references(let entries) = property.value,
                      entries.contains(where: refers)
                else { continue }
                sites.append("`\(property.name)` on the behavior `&\(other.label)`")
            }
        }
        for macro in context.keymap?.macros ?? [] where macro.label != label {
            let steps = macro.bindings.filter { $0.behavior == reference }.count
            guard steps > 0 else { continue }
            sites.append("""
                the sequence of the macro `&\(macro.label)` (\(steps) \
                step\(steps == 1 ? "" : "s"))
                """)
        }

        guard !sites.isEmpty else {
            return """
                No layer, combo, other behavior or macro refers to it. Devicetree \
                this editor does not model — a node override, a `#define` that \
                expands to a reference — was not checked.
                """
        }
        return """
            It is still referred to at \(sites.joined(separator: "; ")) — those \
            references will not build once it is gone, so they have to change too.
            """
    }

    /// A free node name for a behavior, macro or layer the model is creating.
    ///
    /// Checked against every node name the editor models, not just its own
    /// kind: `upsertBehavior` throws on a duplicate, and picking a free name up
    /// front means the model is not told "no" for something it did not choose.
    /// `_` is the separator because that is how a behavior and a macro node are
    /// named; a combo counts with `-` and goes through `uniqueComboName`.
    private static func uniqueNodeName(from base: String, in keymap: KeymapFile) -> String {
        keymap.uniqueNodeName(
            startingFrom: base, separator: "_", taken: keymap.modelledNodeNames
        )
    }

    /// A label as the model gave it, with the `&` a binding would carry stripped
    /// — `&hml` and `hml` mean the same behavior and rejecting one of them would
    /// be a rule the user never sees and the model has to learn by failing.
    private static func reference(_ use: ClaudeToolUse, _ name: String) -> String? {
        guard var text = field(use, name)?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        if text.hasPrefix("&") { text.removeFirst() }
        return text.isEmpty ? nil : text
    }

    /// The kinds `set_behavior` offers.
    ///
    /// `macroBehavior` is deliberately not among them. `BehaviorReader` declines
    /// `zmk,behavior-macro*` nodes so that `MacroReader` owns them and no node
    /// is ever listed as both — which means a behavior written with that
    /// `compatible` would never be read back as a behavior. `set_macro` is the
    /// tool for a macro, and it round trips.
    static let behaviorKinds = BehaviorKind.allCases.filter { $0 != .macroBehavior }

    /// One kind of behavior as the schema advertises it. Built from
    /// ``BehaviorKind`` rather than written out, so a kind gaining a property
    /// upstream reaches the model without a second edit here — and so the model
    /// does not have to stage a behavior and be told "no" to learn that a
    /// mod-morph must set `mods`.
    private static func kindSummary(_ kind: BehaviorKind) -> String {
        var line = "`\(kind.rawValue)` (\(kind.displayName)): \(shape(of: kind.bindings))"
            + ", \(kind.bindingCells) parameter(s)"
        if !kind.requiredProperties.isEmpty {
            line += "; must set \(kind.requiredProperties.joined(separator: ", "))"
        }
        if !kind.optionalProperties.isEmpty {
            line += "; may set \(kind.optionalProperties.joined(separator: ", "))"
        }
        return line + "."
    }

    private static func shape(of bindings: BehaviorBindings) -> String {
        switch bindings {
        case .none: "no bindings at all"
        case .phandles(let count): "\(count) plain behavior reference(s), no parameters"
        case .phandleArray(let count):
            count.map { "\($0) whole binding(s), parameters included" }
                ?? "any number of whole bindings, parameters included"
        }
    }

    private static func behaviorKind(_ use: ClaudeToolUse) -> Parsed<BehaviorKind> {
        guard let raw = field(use, "kind")?.stringValue else {
            return .failure("`kind` must be a string")
        }
        // The schema constrains this to the raw values, but a model that writes
        // "hold-tap" or "Hold Tap" has said exactly what it meant and does not
        // need a round trip to be told the spelling.
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = BehaviorKind(rawValue: needle)
            ?? BehaviorKind.allCases.first {
                $0.rawValue.compare(needle, options: .caseInsensitive) == .orderedSame
                    || $0.displayName.compare(needle, options: .caseInsensitive) == .orderedSame
            }
            ?? BehaviorKind.kind(forCompatible: needle)

        guard let matched else {
            return .failure("""
                `\(raw)` is not a kind of behavior this editor can write. The \
                kinds are: \(behaviorKinds.map { "`\($0.rawValue)`" }.joined(separator: ", ")).
                """)
        }
        guard matched != .macroBehavior else {
            return .failure("""
                a macro is written with set_macro, not set_behavior — a macro node \
                holds a sequence of bindings rather than a behavior's properties, \
                and one written through set_behavior would not be readable as a \
                macro afterwards
                """)
        }
        return .success(matched)
    }

    /// The `properties` object folded into what the behavior already has.
    ///
    /// Merged rather than replaced, because a call that changes the tapping term
    /// of an existing hold-tap should not silently drop its `flavor`. A `null`
    /// value removes the property — the only way to say "stop setting this",
    /// since an absent key means "leave it alone".
    static func behaviorProperties(
        _ raw: [String: JSONValue], merging existing: [BehaviorProperty]
    ) -> Parsed<[BehaviorProperty]> {
        var merged = existing
        // JSON objects carry no order, so the order imposed is: what the file
        // already had, in source order, then anything new alphabetically.
        for name in raw.keys.sorted() {
            guard let json = raw[name] else { continue }
            guard !["compatible", "#binding-cells", "bindings"].contains(name) else {
                return .failure("""
                    `\(name)` is not set through `properties`; it comes from \
                    `kind`, `binding_cells` and `bindings`
                    """)
            }
            if json == .null {
                merged.removeAll { $0.name == name }
                continue
            }
            if json.boolValue == false {
                return .failure("""
                    a devicetree flag property is either written or absent, so \
                    `false` says nothing. Pass `null` to stop setting `\(name)`.
                    """)
            }
            guard let value = behaviorValue(json) else {
                return .failure("""
                    `\(name)` cannot be written as a devicetree property value. \
                    Give a number, a string, an array of numbers, or `true` for a \
                    bare flag; `\(json.jsonText)` is none of those.
                    """)
            }
            if let index = merged.firstIndex(where: { $0.name == name }) {
                merged[index].value = value
            } else {
                merged.append(BehaviorProperty(name: name, value: value))
            }
        }
        return .success(merged)
    }

    static func behaviorValue(_ json: JSONValue) -> BehaviorValue? {
        if let number = json.intValue { return .integer(number) }
        if let text = json.stringValue { return .string(text) }
        if json.boolValue == true { return .flag }
        if let items = json.arrayValue, !items.isEmpty {
            let numbers = items.compactMap(\.intValue)
            if numbers.count == items.count { return .integers(numbers) }
            let strings = items.compactMap(\.stringValue)
            if strings.count == items.count {
                // `["&kp", "&mo"]` is a phandle list; `["KEYS_L", "THUMBS"]` is
                // a cell of preprocessor macros, which is how real keymaps write
                // `hold-trigger-key-positions`.
                return strings.allSatisfy { $0.hasPrefix("&") }
                    ? .references(strings)
                    : .tokens(strings)
            }
        }
        return nil
    }

    /// A value read out of a tool call, or why it could not be. Absent and
    /// present-but-wrong are already told apart by ``badArgument``; this is for
    /// the readings that fail for a reason of their own.
    enum Parsed<Value> {
        case success(Value)
        case failure(String)
    }

    /// Bindings arrive as ZMK text and go through the same parser the file does,
    /// so `&kp ESC` means here exactly what it means in the keymap. Anything
    /// that is not exactly one binding is rejected: `&kp A &kp B` in one key's
    /// slot would silently drop the second half.
    static func parseBinding(_ text: String) -> Parsed<KeyBinding> {
        let parsed = BindingParser.parse(text)
        guard parsed.count == 1, let binding = parsed.first else {
            return .failure("""
                `\(text)` is not one ZMK binding. A binding starts with `&` and \
                is followed by its parameters, e.g. `&kp ESC` or `&mo 2`; \
                \(parsed.isEmpty ? "this parsed as none" : "this parsed as \(parsed.count)").
                """)
        }
        return .success(binding)
    }

    /// One tool argument, treating an explicit JSON `null` as absent.
    ///
    /// Models routinely fill an optional parameter with `null` rather than
    /// leaving it out. Reading that as "present, but not an integer" would fail
    /// the call with a complaint about a value the model never meant to send.
    static func field(_ use: ClaudeToolUse, _ name: String) -> JSONValue? {
        guard let value = use.input[name], value != .null else { return nil }
        return value
    }

    /// Why an argument could not be read.
    ///
    /// Absent and present-but-wrong are different mistakes and want different
    /// corrections, so they get different messages. `JSONValue.intValue` is nil
    /// for a non-integral number as well as for a string, so a model that sends
    /// `1.5` for a key position lands here — telling it "`key_position` is
    /// required" would be a lie it cannot act on.
    private static func badArgument(
        _ use: ClaudeToolUse, _ name: String, _ expected: String
    ) -> Outcome {
        guard let value = field(use, name) else {
            return failure(use, "`\(name)` is required and must be \(expected)")
        }
        return failure(use, "`\(name)` must be \(expected), but was `\(value.jsonText)`")
    }

    /// How an optional argument read: it was there and usable, it was not there,
    /// or it was there and wrong.
    ///
    /// The three are different outcomes and the caller has to handle all three —
    /// which is the point of the type. Written as an `if let` with an `else if`
    /// presence check, as this once was at every optional argument, the middle
    /// case is easy to leave out, and a bad argument then becomes a field the
    /// tool silently skips.
    enum ArgumentRead<Value> {
        case value(Value)
        case absent
        case failure(Outcome)
    }

    /// One optional argument, read through `read` and named exactly once.
    ///
    /// The name being written twice — once to fetch, once to complain — is what
    /// let a typo in the second spelling go unnoticed, so it is written once
    /// here and nowhere else.
    static func argument<Value>(
        _ use: ClaudeToolUse, _ name: String, _ expected: String,
        _ read: (JSONValue) -> Value?
    ) -> ArgumentRead<Value> {
        guard let value = field(use, name) else { return .absent }
        guard let read = read(value) else { return .failure(badArgument(use, name, expected)) }
        return .value(read)
    }

    static func integerArgument(_ use: ClaudeToolUse, _ name: String) -> ArgumentRead<Int> {
        argument(use, name, "an integer", \.intValue)
    }

    static func stringArgument(_ use: ClaudeToolUse, _ name: String) -> ArgumentRead<String> {
        argument(use, name, "a string", \.stringValue)
    }

    /// `expected` is spelled out by the caller because an array of integers and
    /// an array of strings are told apart only by what the tool wanted.
    static func arrayArgument(
        _ use: ClaudeToolUse, _ name: String, _ expected: String
    ) -> ArgumentRead<[JSONValue]> {
        argument(use, name, expected, \.arrayValue)
    }

    static func objectArgument(
        _ use: ClaudeToolUse, _ name: String, _ expected: String
    ) -> ArgumentRead<[String: JSONValue]> {
        argument(use, name, expected, \.objectValue)
    }

    private static func answer(_ use: ClaudeToolUse, _ content: String) -> Outcome {
        Outcome(result: ClaudeToolResult(toolUseID: use.id, content: content))
    }

    private static func failure(_ use: ClaudeToolUse, _ reason: String) -> Outcome {
        Outcome(result: ClaudeToolResult(toolUseID: use.id, content: reason, isError: true))
    }

    // MARK: - Schema building

    private static func schema(
        _ properties: [String: JSONValue] = [:], required: [String] = []
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
        ])
    }

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static func integers(_ description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("integer")]),
            "description": .string(description),
        ])
    }

    private static func strings(_ description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(description),
        ])
    }

    /// A free-form object. The values are devicetree property values, which are
    /// numbers, strings, arrays or a bare `true`, so no value type is declared —
    /// ``behaviorValue(_:)`` is what decides whether one can be written.
    private static func object(_ description: String) -> JSONValue {
        .object(["type": .string("object"), "description": .string(description)])
    }

    /// A string the model must pick from a list. Worth the extra schema over a
    /// plain string: a `compatible` typed from memory is a keymap that does not
    /// build, and the list is short and closed.
    private static func enumeration(_ values: [String], _ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string)),
            "description": .string(description),
        ])
    }
}
