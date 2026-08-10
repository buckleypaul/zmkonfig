import SwiftUI
import ZmkonfigKit

/// A small question mark beside a label that explains the term it is attached
/// to: hover for the short version, click for the full entry in the glossary
/// window.
///
/// The hover half is `hoverPopover`, shared with `ToolbarActionButton`. What is
/// new here is that the text comes from the glossary rather than from the call
/// site, so
/// the twenty places that mention `flavor` cannot each word it differently, and
/// a badge for a term nobody has written up draws nothing at all rather than an
/// empty popover.
struct HelpBadge: View {
    @Environment(\.theme) private var theme
    @Environment(\.glossary) private var glossary
    @Environment(\.openWindow) private var openWindow
    /// Optional so that a badge in a scene that never registered one — the
    /// menubar panel, a future sheet — draws and hovers rather than trapping.
    /// Only the click needs it.
    @Environment(GlossaryModel.self) private var glossaryModel: GlossaryModel?

    /// The ``GlossaryEntry/term`` to explain — `&kp`, `flavor`, `hold-tap`.
    let term: String

    @State private var isHovering = false

    var body: some View {
        if let entry = glossary.entry(for: term) {
            Button { glossaryModel?.show(term, using: openWindow) } label: {
                Image(systemName: "questionmark.circle")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.color(isHovering ? .accent : .tertiaryText))
            }
            .buttonStyle(.plain)
            .hoverPopover(isHovering: $isHovering) {
                GlossaryCard(entry: entry, showsFooter: true)
                    .padding(theme.metric(.spacingM))
                    .frame(width: theme.metric(.helpPopoverWidth))
            }
            .accessibilityLabel("What is \(entry.title)?")
            .accessibilityHint(entry.summary)
        }
    }
}

/// One glossary entry laid out for reading: what it is, what it does, and a
/// worked example where there is one.
///
/// Shared by the hover popover and the glossary window so that the short answer
/// and the long one are the same answer — the window adds the values, the
/// cross-references and the link, and nothing else differs.
struct GlossaryCard: View {
    @Environment(\.theme) private var theme
    let entry: GlossaryEntry
    /// Whether to say that clicking opens the full entry. True in the popover,
    /// false in the window, which *is* the full entry.
    var showsFooter = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
            HStack(alignment: .firstTextBaseline, spacing: theme.metric(.spacingS)) {
                Text(entry.title)
                    .font(theme.font(.heading))
                    .foregroundStyle(theme.color(.primaryText))
                Text(entry.term)
                    .font(theme.font(.monoSmall))
                    .foregroundStyle(theme.color(.tertiaryText))
            }

            Text(entry.summary)
                .font(theme.font(.body))
                .foregroundStyle(theme.color(.primaryText))
                .fixedSize(horizontal: false, vertical: true)

            Text(entry.detail)
                .font(theme.font(.caption))
                .foregroundStyle(theme.color(.secondaryText))
                .fixedSize(horizontal: false, vertical: true)

            if let example = entry.example {
                GlossaryExampleView(example: example)
            }

            if showsFooter {
                Caption("Click for the full entry", tone: .tertiaryText)
            }
        }
    }
}

/// A worked binding and what it means. The binding is set in mono because it is
/// something the user would type, and the meaning is not.
struct GlossaryExampleView: View {
    @Environment(\.theme) private var theme
    let example: GlossaryEntry.Example

    var body: some View {
        ContentBox {
            VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                Text(example.binding)
                    .font(theme.font(.mono))
                    .foregroundStyle(theme.color(.primaryText))
                    .textSelection(.enabled)
                Caption(example.meaning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
