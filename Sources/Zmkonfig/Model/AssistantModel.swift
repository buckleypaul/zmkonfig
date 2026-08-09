import Foundation
import Observation
import ZmkonfigKit

/// The chat assistant: a conversation about the open keymap that can *stage*
/// changes to it but never make them.
///
/// The safety story is structural rather than a matter of prompting. The model
/// is given tools, and its edit tools do nothing but hand a ``ProposedEdit``
/// back to this object; the proposal sits in the transcript until the user
/// presses Apply, and applying goes through ``AppModel/applyProposal(_:)`` →
/// `KeymapFile` mutators → `SourceEdit` like every other edit in the app. No
/// model output is ever spliced into the `.keymap`, and none of it can be:
/// there is no case of `ProposedEdit` that carries devicetree text.
@MainActor
@Observable
final class AssistantModel {

    /// One turn as the user sees it. The wire history is kept separately —
    /// the API needs tool calls and tool results as messages, and the user
    /// needs prose and a card of staged edits.
    struct ChatMessage: Identifiable {
        enum Role { case user, assistant }

        let id = UUID()
        let role: Role
        var text: String
        /// Tool calls made while producing this message, for the "what it did"
        /// disclosure. Display only — nothing reads these back.
        var activity: [String] = []
        /// Edits staged by this turn, and whether they have been acted on.
        var proposal: [ProposedEdit] = []
        var proposalState: ProposalState = .pending
    }

    enum ProposalState: Equatable { case pending, applied, discarded, failed }

    /// The composer's text. Owned by the view, cleared by ``send()``.
    var draft = ""
    private(set) var messages: [ChatMessage] = []
    private(set) var isRunning = false
    /// The tool call in flight, for the running indicator: `read_layer(layer: 1)`.
    private(set) var activity: String?
    /// An API failure, in the API's own words. Cleared when the next turn starts.
    private(set) var failure: String?

    var isConfigured: Bool { llm.isConfigured }

    /// A turn may call tools several times over before it has an answer —
    /// reading three layers to find a free key is normal, and defining a
    /// behavior means reading the raw source first, which on a long keymap
    /// arrives a piece at a time. Twelve rounds covers that and is still
    /// bounded: a model that has misunderstood the tools can otherwise call
    /// them until the context runs out, and the user watches a spinner pay for
    /// it.
    private static let maxRounds = 12

    private let llm: LLMModel
    private let app: AppModel

    /// The conversation as the API sees it.
    private var history: [ClaudeMessage] = []
    /// Where `history` stood before the turn now running started, so a cancel
    /// can roll it back — see ``cancel()``.
    private var checkpoint = 0
    /// Something that happened outside the conversation and the model needs to
    /// know, folded into the next user message.
    ///
    /// It cannot be sent on its own: the Messages API requires roles to
    /// alternate, and "the user applied those changes" arriving as a second
    /// consecutive user message is a 400. It also is not worth a turn of its
    /// own — the model has nothing to say about it until the user asks for
    /// something else.
    private var pendingNote: String?
    private var task: Task<Void, Never>?
    /// The assistant message the running turn is filling in. Held by id rather
    /// than by index because ``apply(messageID:)`` can mutate `messages` while
    /// the turn is in flight, and an index would then point at the wrong one.
    private var turnID: ChatMessage.ID?

    init(llm: LLMModel, app: AppModel) {
        self.llm = llm
        self.app = app
    }

    // MARK: - Driving the conversation

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        guard let client = llm.client() else {
            failure = AnthropicError.notConfigured.description
            return
        }

        draft = ""
        failure = nil
        checkpoint = history.count
        messages.append(ChatMessage(role: .user, text: text))

        // The assistant's message is appended now, empty, and filled in as the
        // turn runs. It has to exist before the first tool call so the panel can
        // name the tool actually running rather than saying "Thinking…" for the
        // whole turn — `AssistantPanelView` reads `messages.last?.activity.last`.
        // Empty on all three fields it renders as nothing, so the first tick
        // shows no stray bubble.
        let placeholder = ChatMessage(role: .assistant, text: "")
        messages.append(placeholder)
        turnID = placeholder.id

        let note = pendingNote
        pendingNote = nil
        history.append(.user(note.map { "\($0)\n\n\(text)" } ?? text))

        let model = llm.selectedModelID
        // Reading a keymap and reasoning about which key is free is a middling
        // amount of thought: more than the layer writeup asks for, less than a
        // pre-flight review of a diff. `effort` is a request, not an
        // instruction — `LLMModel` drops it for a model that has not said it
        // accepts that level, because sending it anyway 400s on Haiku.
        let effort = llm.effort(.medium)

        isRunning = true
        task = Task { [weak self] in
            await self?.converse(client: client, model: model, effort: effort)
        }
    }

    /// Stops the turn in flight and rewinds the wire history past it.
    ///
    /// The rewind is the point. A cancelled turn can leave `history` ending on
    /// an assistant message full of `tool_use` blocks that were never answered,
    /// or on tool results with no assistant turn after them; either shape is
    /// rejected on the next request. Dropping the whole exchange back to where
    /// it started is the only repair that does not require knowing how far it
    /// got. The visible transcript keeps the user's message, because they typed
    /// it and deleting it under them would be worse than the model not
    /// remembering it.
    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        activity = nil
        if history.count > checkpoint { history.removeSubrange(checkpoint...) }
        discardPlaceholder()
    }

    func reset() {
        cancel()
        messages = []
        history = []
        checkpoint = 0
        pendingNote = nil
        failure = nil
    }

    // MARK: - The tool loop

    private func converse(client: AnthropicClient, model: String, effort: ClaudeEffort?) async {
        // Staged edits are held here and only written onto the message once the
        // turn is over. Filling `proposal` live would put an Apply button on a
        // half-built proposal — the card does not disable while running, so the
        // user could apply two of the three edits the model is still staging.
        var staged: [ProposedEdit] = []
        var prose = ""

        for _ in 0..<Self.maxRounds {
            let turn: ClaudeTurn
            do {
                turn = try await client.converse(
                    model: model,
                    // Rebuilt every round rather than captured once: the user
                    // can apply a proposal, or edit a key by hand, while the
                    // turn is in flight, and a prompt describing the keymap as
                    // it was would have the model reasoning about a keyboard
                    // that no longer exists.
                    system: systemPrompt(),
                    messages: history,
                    tools: AssistantTools.all,
                    // The kit's 16k default: the budget covers thinking and
                    // the turn together, and a turn cut short mid-loop is a
                    // half-written tool call, not just a short answer.
                    effort: effort
                )
            } catch {
                guard !Task.isCancelled else { return }
                failure = AppError.describe(error)
                // Same rewind as a cancel, for the same reason: the history
                // stops on a user-role message — the user's own, or the tool
                // results of the last round — and the next turn would append a
                // second one, which the API rejects for not alternating. A
                // failed request leaves no trace and the next message is sent
                // afresh.
                if history.count > checkpoint { history.removeSubrange(checkpoint...) }
                discardPlaceholder()
                isRunning = false
                activity = nil
                return
            }
            guard !Task.isCancelled else { return }

            // Prose can arrive alongside tool calls, and the last of it is what
            // the model has settled on. Keep it so a turn that ends on a tool
            // round still has something to show.
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { prose = text }

            // Checked before the tools run, not after. A turn that hit
            // `max_tokens` stopped in the middle of writing itself, so its
            // last tool call may be one the model had not finished asking
            // for — running it and going round again would build the rest of
            // the conversation on a turn that never happened. The staged
            // edits from earlier, complete rounds are kept; `finish` says the
            // answer is partial so the user does not read them as the whole
            // of what was suggested.
            guard !turn.wasTruncated else {
                finish(prose: prose, staged: staged, ending: .truncated)
                return
            }

            guard !turn.toolUses.isEmpty else {
                finish(prose: prose, staged: staged, ending: .complete)
                return
            }

            history.append(.assistant(text: turn.text, toolUses: turn.toolUses))
            var results: [ClaudeToolResult] = []
            for use in turn.toolUses {
                let label = AssistantTools.label(for: use)
                activity = label
                update { $0.activity.append(label) }
                let outcome = AssistantTools.run(use, context: app.context, staged: staged)
                if let id = outcome.unstage { staged.removeAll { $0.id == id } }
                if let edit = outcome.staged { stage(edit, into: &staged) }
                // Every `tool_use` gets a `tool_result`, including the ones
                // whose arguments were rejected — `run` returns an errored
                // result rather than nothing. A `tool_use` with no matching
                // result is a 400 on the *next* request, a whole round trip
                // away from the call that caused it.
                results.append(outcome.result)
            }
            history.append(.toolResults(results))
        }

        finish(prose: prose, staged: staged, ending: .roundsExhausted)
    }

    /// Edits the assistant message this turn is filling in, if it is still there.
    private func update(_ change: (inout ChatMessage) -> Void) {
        guard let turnID, let index = index(of: turnID) else { return }
        change(&messages[index])
    }

    /// Drops the turn's message when it never got as far as saying anything.
    /// A cancelled or failed turn must not leave an empty bubble behind; what
    /// went wrong is on `failure`, and what it managed to look at before dying
    /// is not worth a row on its own.
    private func discardPlaceholder() {
        if let turnID, let index = index(of: turnID) { messages.remove(at: index) }
        turnID = nil
    }

    /// Replaces any staged edit aimed at the same target rather than appending.
    /// See ``ProposedEdit/id`` — a model that sets a key and then changes its
    /// mind should show the user one change, not two.
    private func stage(_ edit: ProposedEdit, into staged: inout [ProposedEdit]) {
        if let index = staged.firstIndex(where: { $0.id == edit.id }) {
            staged[index] = edit
        } else {
            staged.append(edit)
        }
    }

    /// Why a turn stopped. Only `.complete` means the model was finished.
    private enum Ending {
        /// The model answered and asked for no more tools.
        case complete
        /// `maxRounds` of tool calls went by without an answer.
        case roundsExhausted
        /// The turn hit `max_tokens` and is a fragment.
        case truncated
    }

    private func finish(prose: String, staged: [ProposedEdit], ending: Ending) {
        var text = prose
        switch ending {
        case .complete:
            break
        case .roundsExhausted:
            let note = """
                I stopped after \(Self.maxRounds) rounds of looking things up \
                without reaching an answer. Nothing has been changed. Try asking \
                for one thing at a time, or tell me the layer and key you mean.
                """
            text = text.isEmpty ? note : text + "\n\n" + note
        case .truncated:
            // Said plainly because anything above it is a fragment: the prose
            // may stop mid-sentence and any card below it is whatever was
            // staged before the cut, not the whole suggestion.
            let note = """
                I ran out of room part-way through that answer and stopped, so \
                whatever is above may be incomplete — including any changes I \
                had suggested. Try asking for something narrower.
                """
            text = text.isEmpty ? note : text + "\n\n" + note
        }
        if text.isEmpty {
            text = "I did not have an answer for that. Try asking again, or more specifically."
        }

        // The wire history has to end on an assistant message or the next user
        // message is two user messages in a row. The displayed text goes in
        // rather than the model's own, so an empty turn is recorded as the
        // substitute the user actually saw.
        history.append(.assistant(text: text, toolUses: []))

        // The message has been on screen since the turn started, collecting
        // activity lines; this is what it was collecting them for.
        update {
            $0.text = text
            $0.proposal = staged
            $0.proposalState = .pending
        }
        turnID = nil
        self.activity = nil
        isRunning = false
    }

    // MARK: - Acting on a proposal

    func apply(messageID: ChatMessage.ID) {
        guard let index = index(of: messageID), messages[index].proposalState == .pending else { return }
        if app.applyProposal(messages[index].proposal) {
            messages[index].proposalState = .applied
            pendingNote = "(The user applied those changes.)"
        } else {
            // `applyProposal` has already raised the alert carrying the reason.
            messages[index].proposalState = .failed
            pendingNote = "(Those changes could not be applied and are not in the keymap.)"
        }
    }

    func discard(messageID: ChatMessage.ID) {
        guard let index = index(of: messageID), messages[index].proposalState == .pending else { return }
        messages[index].proposalState = .discarded
        pendingNote = "(The user discarded those changes.)"
    }

    private func index(of id: ChatMessage.ID) -> Int? {
        messages.firstIndex { $0.id == id }
    }

    // MARK: - The prompt

    private func systemPrompt() -> String {
        "\(Self.instructions)\n\n\(context())"
    }

    private static let instructions = """
        You are built into Zmkonfig, a small macOS editor for ZMK keyboard \
        firmware. The person you are talking to owns the keyboard whose keymap \
        is open, and wants to change it by describing what they want rather than \
        by clicking keys. Assume they know their own keyboard and how they type \
        on it, and that they may not know ZMK's vocabulary at all.

        HOW YOUR CHANGES REACH THE KEYBOARD

        You cannot edit anything. The edit tools only *stage* a change: it \
        appears in the conversation as a card the user reads and then either \
        applies or discards. Nothing you do touches the keymap file, and the \
        user has to press a button before anything does.

        So never say you have changed, updated, moved or set anything. Say what \
        you have suggested, and that it is waiting for them. "I've suggested \
        moving Escape to the left thumb — apply it when you're happy" is right; \
        "I've moved Escape to the left thumb" is a lie the user will believe \
        until their firmware builds without it.

        WHAT YOU CAN CHANGE

        More than bindings. You can set a key on a layer, add, change and remove \
        combos, rename a layer, add and remove layers, and define, change and \
        remove the keymap's own behaviors and macros — a hold-tap so a home-row \
        key sends a modifier when held, a tap-dance, a mod-morph, a macro that \
        types an address. So do not tell the user something is beyond you \
        without checking the tools you have; "I can only change bindings" is no \
        longer true and they will believe it.

        You still write no devicetree. A behavior is staged by naming its kind, \
        the behaviors it wraps and its properties; a macro by its sequence of \
        bindings. If a request genuinely needs something these do not \
        express — a conditional layer, a `&bt` profile count, an include, \
        anything under `#define` — say plainly what has to be edited by hand and \
        where in the file it goes. read_keymap_source is how you find that out.

        ASK BEFORE YOU GUESS

        Most requests about a keymap are ambiguous, and a wrong guess costs the \
        user a firmware build to discover. "Put Escape somewhere on the left" \
        does not say which key, and "add a copy/paste combo" does not say which \
        two keys or which layers. When more than one reasonable reading exists \
        and they lead to different keys, ask one short question and stage \
        nothing. One question, not a list; the most useful one.

        Do not ask when the answer is in front of you. If the request names a \
        key, or only one key on the layer plausibly matches, get on with it.

        READ BEFORE YOU WRITE

        Every tool that changes something takes a key position number, and key \
        position numbers cannot be inferred — they depend on the physical layout \
        and on how the keymap orders its bindings. Call read_layer on the layer \
        you are about to change, every time, before you change it. Do the same \
        with list_combos before touching a combo, list_behaviors_defined before \
        touching a behavior, and list_macros before touching a macro. If you are \
        about to bind a keycode you have not seen in this keymap, check the \
        spelling with find_keycodes; if you are about to bind anything other than \
        &kp, check list_behaviors for what parameters it takes.

        Read the raw file with read_keymap_source before you edit any part of it \
        you have not already looked at, and before you define a behavior or a \
        macro. The other tools show you what the keymap binds; the source shows \
        you how it is written — its includes, its `#define`s, the behaviors and \
        macros it already defines, its comments, and the conventions the user \
        has been following. A hold-tap staged without reading it is a hold-tap \
        that duplicates one already there, or ignores a `#define` the user names \
        their keys with. It is a long file and comes back in pieces; ask for the \
        next piece when you need it.

        Look at what is already there before you take a key. A key that is \
        currently &kp Q is not free. Say what you are displacing.

        LAYER NUMBERS MOVE

        Layers are numbered from 0, and that number is what `&mo 2`, `&lt 3 TAB`, \
        `&to 1` and a combo's layer list all mean. Removing a layer, or inserting \
        one anywhere but the end, shifts the number of every layer after it — and \
        the bindings that name those numbers keep the numbers they were written \
        with, so they end up pointing somewhere else. The editor does not rewrite \
        them, because they can sit inside macros and behaviors it cannot safely \
        touch.

        add_layer and remove_layer tell you exactly what is affected. Say it back \
        to the user in your own words, in the same message as the change — "layer \
        3 becomes layer 2, and the `&mo 3` on your left thumb will now open the \
        wrong layer; you'll want to fix that too". Adding a layer at the end \
        moves nothing, and is the right answer unless the user asked for a \
        particular position. Never stage one of these silently.

        HOW TO WRITE BACK

        Write as one keyboard hobbyist to another: short, concrete, ordinary \
        words. Describe the staged change by where the key is under the hand and \
        what it will do — "the left inner thumb key becomes Escape; it was the \
        symbol layer hold" — not as JSON, not as devicetree, not as a table of \
        tool arguments. The user is looking at a picture of their keyboard, not \
        at code. Mention a key position number only when they need it to find \
        the key.

        Two or three sentences is usually the whole answer. If something about \
        the change is worth a second thought — it makes a layer unreachable, it \
        removes the only Shift, the combo's two keys are on different hands and \
        awkward to press — say so plainly in one more sentence. If a request \
        cannot be done with the tools you have, say what you cannot do and what \
        the user would have to do by hand; do not stage something close to it \
        and hope.
        """

    /// The live state of the app, rebuilt per request. What is open, what is on
    /// screen and what the user has selected are all things the user takes for
    /// granted the assistant can see — and a model that has to call three tools
    /// to learn there are five layers wastes a round doing it.
    private func context() -> String {
        var lines = ["THE KEYMAP RIGHT NOW"]

        if let repo = app.repo {
            lines.append("Repository: \(repo.slug).")
        } else {
            lines.append("No repository is open yet, so there is nothing to read or change.")
        }

        if let keyboard = app.keyboard {
            let name = keyboard.name ?? keyboard.id ?? "unknown"
            let variant = app.layoutKey.map { " (layout \"\($0)\")" } ?? ""
            lines.append("Keyboard: \(name)\(variant), \(app.layout.count) key positions.")
        }

        if app.layers.isEmpty {
            lines.append("No layers are loaded.")
        } else {
            lines.append("Layers:\n\(KeymapDigest.layers(app.layers))")
        }

        lines.append("Combos:\n\(KeymapDigest.combos(app.combos, keymap: app.keymap))")

        switch app.sidebarSelection {
        case .layer(let id):
            let name = app.layers.first { $0.id == id }?.displayName ?? "?"
            let key = app.selectedKeyIndex.map { ", with key position \($0) selected" } ?? ""
            lines.append("The user is looking at layer \(id), \"\(name)\"\(key).")
        case .combo(let id):
            let name = app.combos.first { $0.id == id }?.nodeName ?? "?"
            lines.append("The user is editing the combo `\(name)`.")
        case nil:
            break
        }

        // A binding count that disagrees with the layout means the grids and
        // the key position numbers are wrong, and staging an edit against them
        // would put a key somewhere nobody asked for. The model has to know
        // before it reads a layer, not after.
        if let mismatch = app.layoutMismatch {
            lines.append("""
                Warning: the layer on screen has \(mismatch.bindings) bindings but \
                the selected layout has \(mismatch.positions) key positions. The \
                wrong keyboard layout is probably selected, key positions cannot \
                be trusted, and you should say so and stage nothing until it is \
                fixed.
                """)
        }

        if app.hasUnsavedEdits {
            lines.append("There are unsaved edits; the file on disk is behind what you can see.")
        }

        return lines.joined(separator: "\n")
    }
}
