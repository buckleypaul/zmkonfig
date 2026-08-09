import SwiftUI
import ZmkonfigKit

/// A chat with Claude about the open keymap. It can read the keymap through
/// tools and *stage* edits, but nothing it proposes reaches the file until the
/// user presses Apply on the card — see `AssistantModel`.
struct AssistantPanelView: View {
    @Environment(\.theme) private var theme
    let model: AppModel
    @Bindable var assistant: AssistantModel

    var body: some View {
        Group {
            if !assistant.isConfigured {
                // The same wording `ExplainPanelView` uses; two phrasings for
                // one missing key would read as two different problems.
                Hint(text: "Add an Anthropic API key in Settings (⌘,) to use this.")
            } else {
                VStack(spacing: 0) {
                    transcript
                    Divider()
                    composer
                }
            }
        }
    }

    // MARK: - Transcript

    /// The conversation so far, kept pinned to the newest message.
    ///
    /// The pinning is declarative — `defaultScrollAnchor(.bottom)` — and that is
    /// deliberate. Driving it imperatively instead, with a `ScrollViewReader`
    /// and `scrollTo` fired from `onChange`, does nothing at all while the
    /// transcript still fits on screen and only starts doing real work once it
    /// overflows: scrolling during a layout pass that is itself reacting to the
    /// content growing, which is how that shape hangs. An anchor cannot, since
    /// it is resolved as part of the same layout rather than provoking another.
    ///
    /// A plain `VStack` for the same reason. A chat is tens of rows, so laziness
    /// buys nothing here, and rows that are not realized are exactly what makes
    /// scrolling to one unreliable.
    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metric(.spacingM)) {
                if assistant.messages.isEmpty {
                    Caption("Describe a change in plain English — \"make the right thumb key a layer tap for Nav\". Claude reads the keymap, then proposes edits for you to apply.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(assistant.messages) { message in
                    MessageRow(model: model, assistant: assistant, message: message)
                }

                if assistant.isRunning {
                    HStack(spacing: theme.metric(.spacingS)) {
                        ProgressView().controlSize(.small)
                        Caption(workingLine)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(theme.metric(.spacingM))
        }
        .defaultScrollAnchor(.bottom)
    }

    /// While a turn is in flight the model's prose has not arrived yet, so the
    /// most recent tool call is the only thing there is to report.
    private var workingLine: String {
        assistant.messages.last?.activity.last ?? "Thinking…"
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
            // Never swallowed: an API failure says what went wrong, in place.
            if let failure = assistant.failure {
                WarningStrip(text: failure, tone: .danger)
            }

            TextField("Ask for a change…", text: $assistant.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(theme.font(.body))
                .lineLimit(1...6)
                .disabled(assistant.isRunning)
                // A single-line draft behaves like a chat box; a multi-line one
                // needs ⌘↩, because ↩ is how the second line got there.
                .onSubmit { if !assistant.draft.contains("\n") { assistant.send() } }

            HStack(spacing: theme.metric(.spacingS)) {
                if !assistant.messages.isEmpty {
                    Button("New Chat") { assistant.reset() }
                        .buttonStyle(.link)
                        .font(theme.font(.caption))
                        .disabled(assistant.isRunning)
                }

                Spacer(minLength: 0)

                if assistant.isRunning {
                    Button("Stop") { assistant.cancel() }
                } else {
                    Button("Send") { assistant.send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(theme.metric(.spacingM))
    }
}

// MARK: - One turn

/// A single turn. The user's words sit in a tinted bubble and the assistant's
/// run full width, so the two never read as one voice.
private struct MessageRow: View {
    @Environment(\.theme) private var theme
    let model: AppModel
    let assistant: AssistantModel
    let message: AssistantModel.ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
            switch message.role {
            case .user:
                Text(message.text)
                    .font(theme.font(.body))
                    .foregroundStyle(theme.color(.primaryText))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, theme.metric(.spacingM))
                    .padding(.vertical, theme.metric(.spacingS))
                    .background(
                        RoundedRectangle(cornerRadius: theme.metric(.cornerRadiusMedium))
                            .fill(theme.color(.accentSoft))
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)

            case .assistant:
                if !message.activity.isEmpty {
                    ActivityDisclosure(activity: message.activity)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(theme.font(.body))
                        .foregroundStyle(theme.color(.primaryText))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !message.proposal.isEmpty {
                    ProposalCard(model: model, assistant: assistant, message: message)
                }
            }
        }
    }
}

/// What the assistant looked at while answering, folded away. A turn can make a
/// dozen tool calls and none of them are the answer.
private struct ActivityDisclosure: View {
    @Environment(\.theme) private var theme
    let activity: [String]

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                ForEach(Array(activity.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(theme.font(.monoSmall))
                        .foregroundStyle(theme.color(.secondaryText))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, theme.metric(.spacingXS))
        } label: {
            Caption("Looked at \(activity.count) thing\(activity.count == 1 ? "" : "s")", tone: .tertiaryText)
        }
    }
}

// MARK: - Staged edits

/// The edits a turn staged, and the only place they can be applied. The prose
/// explanation is the message above; this lists what would actually change.
private struct ProposalCard: View {
    @Environment(\.theme) private var theme
    let model: AppModel
    let assistant: AssistantModel
    let message: AssistantModel.ChatMessage

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                SectionLabel(text: heading)

                ForEach(message.proposal) { edit in
                    Text(model.describe(edit))
                        .font(theme.font(.monoSmall))
                        .foregroundStyle(theme.color(.primaryText))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                switch message.proposalState {
                case .pending:
                    HStack(spacing: theme.metric(.spacingS)) {
                        Spacer(minLength: 0)
                        Button("Discard") { assistant.discard(messageID: message.id) }
                        // Deliberately not `.defaultAction`. Return already
                        // sends the composer, several proposals can sit pending
                        // at once, and the one thing that must not happen by
                        // accident is a keymap change landing because someone
                        // pressed Return while typing.
                        Button("Apply") { assistant.apply(messageID: message.id) }
                    }
                case .applied:
                    Caption("Applied to the keymap.", tone: .success)
                case .discarded:
                    Caption("Discarded.", tone: .tertiaryText)
                case .failed:
                    Caption("These changes did not go through.", tone: .danger)
                }
            }
        }
    }

    private var heading: String {
        let count = message.proposal.count
        return count == 1 ? "Proposed change" : "Proposed changes (\(count))"
    }
}
