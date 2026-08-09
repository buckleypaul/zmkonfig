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
        .onChange(of: model.selectedLayerID) { _, _ in explain.layer.clear() }
    }

    private func content(for layer: KeymapLayer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metric(.spacingM)) {
                HStack {
                    SectionLabel(text: layer.displayName)
                    Spacer()
                    Button(explain.layer.text(for: ExplainModel.layerSubject(layer.id)) == nil ? "Explain" : "Again") {
                        explain.explainLayer(layer, context: model.context)
                    }
                    .disabled(explain.layer.isRunning)
                }

                ClaudeAnswer(
                    request: explain.layer,
                    subject: ExplainModel.layerSubject(layer.id),
                    working: "Reading the layer…",
                    placeholder: "Claude reads this layer's bindings and describes what it is for."
                )
            }
            .padding(theme.metric(.spacingM))
        }
    }
}
