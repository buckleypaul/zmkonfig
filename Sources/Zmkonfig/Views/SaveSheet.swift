import SwiftUI
import ZmkonfigKit

/// Shows what actually changed on disk before anything is committed or pushed.
struct SaveSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @Bindable var model: AppModel
    let explain: ExplainModel
    let onPushed: (String) -> Void

    @State private var message = "Update keymap"
    @State private var isPushing = false

    var body: some View {
        // Both of these walk the whole diff — `changesSubject` hashes it and
        // `isTruncated` counts its graphemes — and the header, the review and
        // the review's warning all need them. `message` is @State on this view,
        // so without hoisting they would be recomputed on every keystroke in
        // the commit field.
        let subject = ExplainModel.changesSubject(for: model.pendingDiff)
        let isTruncated = explain.isTruncated(model.pendingDiff)
        let hasReview = explain.changes.text(for: subject) != nil
        VStack(alignment: .leading, spacing: 0) {
            header(hasReview: hasReview)
            Divider()
            if explain.changes.isRunning || explain.changes.failure != nil || hasReview {
                review(subject: subject, isTruncated: isTruncated)
            }
            // A rounded, bordered card rather than a flat panel run edge to
            // edge: every other surface transition in the app says "this is a
            // separate thing" with elevation, not a hairline, and the diff was
            // the one place still doing it the old way.
            DiffView(diff: model.pendingDiff)
                .outlinedCard()
                .padding(theme.metric(.spacingM))
            footer
        }
        .frame(width: theme.metric(.sheetWidthLarge), height: theme.metric(.sheetHeightLarge))
        .background(theme.color(.panelBackground))
    }

    private func header(hasReview: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                SheetTitle("Review changes")
                Text(model.keymapRelativePath ?? "keymap")
                    .font(theme.font(.monoSmall))
                    .foregroundStyle(theme.color(.secondaryText))
                if model.pendingDiff.isEmpty {
                    Caption("git reports no changes to this file — the keymap on disk already matches what you see.")
                }
            }

            Spacer(minLength: theme.metric(.spacingM))

            // Reading a unified diff of a binding table is exactly the job
            // worth handing off, so the button sits with the diff rather than
            // in the inspector.
            if explain.changes.isConfigured && !model.pendingDiff.isEmpty {
                Button(hasReview ? "Explain again" : "Explain changes") {
                    explain.explainChanges(
                        diff: model.pendingDiff,
                        path: model.keymapRelativePath,
                        context: model.context
                    )
                }
                .disabled(explain.changes.isRunning)
            }
        }
        .padding(theme.metric(.spacingM))
    }

    /// The review only takes space once it has been asked for.
    private func review(subject: String, isTruncated: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                if isTruncated {
                    WarningStrip(
                        text: """
                            This diff is larger than \(ExplainModel.diffCharacterLimit) characters, \
                            so Claude was only shown the start of it.
                            """
                    )
                }
                ClaudeAnswer(
                    request: explain.changes,
                    subject: subject,
                    working: "Reading the diff…"
                )
            }
            .padding(theme.metric(.spacingM))
        }
        .frame(maxHeight: theme.metric(.sheetHeightSmall))
    }

    private var footer: some View {
        HStack(spacing: theme.metric(.spacingM)) {
            TextField("Commit message", text: $message)
                .textFieldStyle(.roundedBorder)
                .font(theme.font(.body))

            if isPushing {
                ProgressView().controlSize(.small)
            }

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Commit & Push") {
                Task {
                    isPushing = true
                    let sha = await model.commitAndPush(message: message)
                    isPushing = false
                    if let sha {
                        onPushed(sha)
                        dismiss()
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isPushing || message.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(theme.metric(.spacingM))
    }
}

/// A plain unified-diff renderer: enough color to read it, no cleverness.
struct DiffView: View {
    @Environment(\.theme) private var theme
    let diff: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let lineStyle = style(for: line)
                    Text(line.isEmpty ? " " : line)
                        .font(theme.font(.monoSmall))
                        .foregroundStyle(lineStyle.text)
                        .padding(.horizontal, theme.metric(.spacingS))
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(lineStyle.background)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, theme.metric(.spacingS))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color(.contentBackground))
    }

    private var lines: [String] {
        diff.isEmpty ? ["(no diff)"] : diff.components(separatedBy: .newlines)
    }

    /// Foreground and background together: the file header lines start with the
    /// same characters as added and removed lines, so deciding the two colors
    /// apart is how they end up disagreeing.
    private func style(for line: String) -> (text: Color, background: Color) {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return (theme.color(.diffMeta), .clear)
        }
        if line.hasPrefix("@@") { return (theme.color(.accent), .clear) }
        if line.hasPrefix("+") { return (theme.color(.diffAddText), theme.color(.diffAddBackground)) }
        if line.hasPrefix("-") { return (theme.color(.diffRemoveText), theme.color(.diffRemoveBackground)) }
        return (theme.color(.primaryText), .clear)
    }
}
