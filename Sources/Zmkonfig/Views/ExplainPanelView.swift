import SwiftUI
import ZmkonfigKit

/// Whatever Claude last said, or why it could not say it. Shared by the two
/// features so a spinner, a failure and an answer look the same in both.
struct ClaudeAnswer: View {
    @Environment(\.theme) private var theme
    let request: ClaudeRequest
    /// What the answer must be about to still be worth showing.
    let subject: String
    let working: String
    /// Shown before anything has been asked. Nil where the view only appears
    /// once there is something to say.
    var placeholder: String?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
            if request.isRunning {
                HStack(spacing: theme.metric(.spacingS)) {
                    ProgressView().controlSize(.small)
                    Caption(working)
                }
            }

            if let failure = request.failure {
                WarningStrip(text: failure, tone: .danger)
            }

            if let text = request.text(for: subject) {
                Text(Self.rendered(text))
                    .font(theme.font(.body))
                    .foregroundStyle(theme.color(.primaryText))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if request.wasTruncated {
                    WarningStrip(
                        text: """
                            Claude ran out of room and this answer stops mid-way. \
                            Ask again for another attempt.
                            """
                    )
                }
            } else if let placeholder, !request.isRunning, request.failure == nil {
                Caption(placeholder)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Claude answers in markdown, and `Text` only parses it from a literal —
    /// a plain `String` renders the asterisks and backticks verbatim.
    ///
    /// Inline-only, so the newlines that separate paragraphs and list items
    /// survive; full block parsing would collapse them into one run. Text that
    /// will not parse is still worth reading, so it falls through as-is rather
    /// than becoming an error.
    private static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}

/// Asks Claude to describe the selected layer. Read-only: nothing here can
/// change the keymap.
struct ExplainPanelView: View {
    @Environment(\.theme) private var theme
    let model: AppModel
    let explain: ExplainModel

    var body: some View {
        Group {
            if !explain.layer.isConfigured {
                Hint(text: "Add an Anthropic API key in Settings (⌘,) to use this.")
            } else if let layer = model.selectedLayer {
                content(for: layer)
            } else {
                Hint(text: "Select a layer to have it explained.")
            }
        }
        // A stale writeup under a newly selected layer would read as if it
        // described that layer.
        .onChange(of: model.selectedLayerID) { _, _ in
            explain.layer.clear()
            explain.key.clear()
        }
        // `ClaudeAnswer` keys its text by subject, so a stale writeup cannot
        // appear under the wrong key — but a *failure* is not subject-keyed, and
        // one left over from the last key would read as this one's.
        .onChange(of: model.selectedKeyIndex) { _, _ in explain.key.clear() }
    }

    private func content(for layer: KeymapLayer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metric(.spacingL)) {
                ExplainSection(
                    title: layer.displayName,
                    request: explain.layer,
                    subject: ExplainModel.layerSubject(layer.id),
                    working: "Reading the layer…",
                    placeholder: "Claude reads this layer's bindings and describes what it is for.",
                    ask: { explain.explainLayer(layer, context: model.context) }
                )

                if let index = model.selectedKeyIndex {
                    Divider()
                    key(at: index, on: layer)
                }
            }
            .padding(theme.metric(.spacingM))
        }
    }

    /// The selected key, explained on its own.
    ///
    /// The glossary and the narrated sentence in the editor already say what a
    /// binding *does*, and they say it with no API key and no waiting. This
    /// answers the part they cannot: why this key is here, what it pairs with,
    /// and what the same position does elsewhere.
    private func key(at index: Int, on layer: KeymapLayer) -> some View {
        ExplainSection(
            title: "Key \(index)",
            request: explain.key,
            subject: ExplainModel.keySubject(layerID: layer.id, index: index),
            working: "Reading the key…",
            placeholder: "Claude reads this key in the context of the layer around it.",
            ask: { explain.explainKey(at: index, on: layer, context: model.context) }
        ) {
            if let binding = layer.bindings.indices.contains(index) ? layer.bindings[index] : nil {
                Text(binding.text)
                    .font(theme.font(.mono))
                    .foregroundStyle(theme.color(.secondaryText))
                    .textSelection(.enabled)
            }
        }
    }
}

/// A heading, an ask button that knows whether it is asking again, whatever
/// came back, and optionally something of the section's own between the two.
///
/// The layer and the key wrote this out separately and identically, differing
/// only in their strings — so a change to how asking works had to be made twice
/// and kept in step by eye.
struct ExplainSection<Detail: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let request: ClaudeRequest
    let subject: String
    let working: String
    let placeholder: String
    let ask: () -> Void
    @ViewBuilder var detail: Detail

    init(
        title: String,
        request: ClaudeRequest,
        subject: String,
        working: String,
        placeholder: String,
        ask: @escaping () -> Void,
        @ViewBuilder detail: () -> Detail = { EmptyView() }
    ) {
        self.title = title
        self.request = request
        self.subject = subject
        self.working = working
        self.placeholder = placeholder
        self.ask = ask
        self.detail = detail()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingM)) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                // "Again" rather than "Explain" once there is an answer, so the
                // button says what pressing it would do rather than what it did.
                Button(request.text(for: subject) == nil ? "Explain" : "Again", action: ask)
                    .disabled(request.isRunning)
            }

            detail

            ClaudeAnswer(
                request: request,
                subject: subject,
                working: working,
                placeholder: placeholder
            )
        }
    }
}
