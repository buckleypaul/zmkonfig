import Foundation
import Observation
import ZmkonfigKit

/// What the app asks Claude to do, and the prompts it asks with.
///
/// Both features are read-only. Nothing here touches `KeymapFile`, so no answer
/// can reach the `.keymap` on disk.
@MainActor
@Observable
final class ExplainModel {
    /// Describes the selected layer.
    let layer: ClaudeRequest
    /// Reviews the diff about to be committed.
    let changes: ClaudeRequest

    /// Diffs are usually a handful of lines, but a layout change rewrites the
    /// whole binding table. Past this the prompt is cut and both the model and
    /// the user are told so — a silently half-read diff would be reviewed as if
    /// it were the whole thing.
    static let diffCharacterLimit = 40_000

    init(llm: LLMModel) {
        layer = ClaudeRequest(llm: llm)
        changes = ClaudeRequest(llm: llm)
    }

    // MARK: - Layers

    /// What a layer's answer is filed under, so a view can ask whether the one
    /// it is about to draw is still current.
    static func layerSubject(_ layerID: Int) -> String { "layer-\(layerID)" }

    func explainLayer(_ layer: KeymapLayer, layerNames: [String], layout: [KeyPosition]) {
        self.layer.run(
            subject: Self.layerSubject(layer.id),
            system: Self.layerSystemPrompt,
            prompt: Self.layerPrompt(for: layer, layerNames: layerNames, layout: layout),
            // A few paragraphs of prose about a grid the model can already see.
            // Nothing here needs deep thinking, and the default of `high` is
            // most of the spinner.
            effort: .low
        )
    }

    private static let layerSystemPrompt = """
        You are helping someone read a ZMK keyboard keymap. You will be given one \
        layer of a keymap laid out the way the keys physically sit under the hands: \
        one line per row, columns aligned, and on a split board a gap between the \
        halves. Read it spatially — which finger reaches a key, and which row it \
        sits on, is most of what the layer means. An index legend follows the grid \
        so you can cite key positions by number; where a layout is unknown the grid \
        is omitted and only the numbered bindings are given.

        Explain what the layer is for and how it is organised, in prose a keyboard \
        hobbyist would recognise. Call out the home-row mods, layer-switching keys, \
        thumb keys, and anything that looks like a mistake — an unreachable layer, a \
        duplicated key, a modifier with no matching pair. Keep it to a few short \
        paragraphs, and do not restate the list back key by key.
        """

    private static func layerPrompt(
        for layer: KeymapLayer, layerNames: [String], layout: [KeyPosition]
    ) -> String {
        let names = layerNames.enumerated()
            .map { "\($0.offset) = \($0.element)" }
            .joined(separator: ", ")
        let header = """
            Layer \(layer.id), "\(layer.displayName)".
            Layers in this keymap: \(names).
            """

        // The grid, the legend and the no-layout fallback all live in
        // `KeymapDigest`, because the assistant's `read_layer` tool has to
        // describe a layer in exactly the words this prompt does — see the note
        // there on why one renderer rather than two.
        return """
            \(header)

            \(KeymapDigest.layer(layer, layout: layout))
            """
    }

    // MARK: - Changes

    func explainChanges(diff: String, path: String?) {
        let (body, wasTruncated) = Self.clip(diff)
        changes.run(
            subject: Self.changesSubject(for: diff),
            system: Self.changesSystemPrompt,
            prompt: """
                Unified diff of \(path ?? "the keymap")\
                \(wasTruncated ? ", truncated after \(Self.diffCharacterLimit) characters" : ""):

                \(body)
                """,
            // Higher-stakes than the layer writeup: this is the last read of a
            // change before it ships to firmware, and a missed unreachable
            // layer costs a flash to find.
            effort: .medium
        )
    }

    /// True when the diff would not fit in the prompt whole.
    func isTruncated(_ diff: String) -> Bool {
        diff.count > Self.diffCharacterLimit
    }

    /// Keyed on the diff's own text, so editing the keymap and saving again
    /// asks afresh rather than showing the review of an older diff.
    static func changesSubject(for diff: String) -> String {
        "diff-\(diff.hashValue)"
    }

    private static func clip(_ diff: String) -> (String, Bool) {
        guard diff.count > diffCharacterLimit else { return (diff, false) }
        return (String(diff.prefix(diffCharacterLimit)), true)
    }

    private static let changesSystemPrompt = """
        You are reviewing a change to a ZMK keymap file before it is committed and \
        pushed to a firmware build.

        Say in plain language what the change does to the keyboard — which keys move, \
        what they do now, which layers and combos are affected. Then flag anything \
        worth a second look before it ships: a key that is now unreachable, a layer \
        with no way back, a lost modifier, a combo whose key positions no longer make \
        a chord, or an edit that touches more of the file than the described change \
        should need.

        Be brief and concrete. If the change is small and clearly fine, say so in a \
        sentence rather than padding the review.
        """
}
