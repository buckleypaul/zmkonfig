import SwiftUI
import ZmkonfigKit

/// The reference: every term this editor can show you, searchable, in a window
/// of its own so it can sit open beside the keymap you are reading it about.
///
/// A window rather than a fifth inspector tab. The inspector is a column three
/// hundred points wide whose job is editing the thing you have selected, and
/// reference material that replaces it while you are trying to use it is
/// reference material you have to close to act on.
struct GlossaryWindow: View {
    @Environment(\.theme) private var theme
    @Bindable var model: GlossaryModel
    let glossary: Glossary

    var body: some View {
        // Both the list and the "nothing matched" message need the filtered
        // sections, and filtering walks every entry's prose, so it is computed
        // once per body rather than twice.
        let sections = glossary.sections(matching: model.query)
        NavigationSplitView {
            termList(sections)
                .navigationSplitViewColumnWidth(theme.metric(.glossaryTermListWidth))
        } detail: {
            detail
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: "Search terms and descriptions")
        .frame(
            minWidth: theme.metric(.glossaryWindowWidth),
            minHeight: theme.metric(.glossaryWindowHeight)
        )
        .background(theme.color(.windowBackground))
        .themedScene()
    }

    // MARK: - The list

    @ViewBuilder
    private func termList(_ sections: [(section: GlossarySection, entries: [GlossaryEntry])]) -> some View {
        if sections.isEmpty {
            Hint(text: "Nothing matches “\(model.query)”.")
                .background(theme.color(.sidebarBackground))
        } else {
            List(selection: $model.selectedTerm) {
                ForEach(sections, id: \.section) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            row(entry).tag(entry.term)
                        }
                    } header: {
                        SectionLabel(text: group.section.title)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func row(_ entry: GlossaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.title)
                .font(theme.font(.body))
                .foregroundStyle(theme.color(.primaryText))
            // Behaviors are met as `&kp` far more often than as "Key press", so
            // the token a binding actually spells stays visible in the list
            // rather than only inside the entry.
            Text(entry.term)
                .font(theme.font(.monoSmall))
                .foregroundStyle(theme.color(.tertiaryText))
        }
        .lineLimit(1)
    }

    // MARK: - The entry

    @ViewBuilder
    private var detail: some View {
        if let term = model.selectedTerm, let entry = glossary.entry(for: term) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.metric(.spacingL)) {
                    GlossaryCard(entry: entry)
                    if let values = entry.values, !values.isEmpty {
                        valueList(values)
                    }
                    footer(entry)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(theme.metric(.spacingL))
            }
            .background(theme.color(.panelBackground))
        } else {
            Hint(text: "Pick a term to read what it means.\n\nAnywhere in the editor, the ? beside a "
                 + "field opens this window at that term.")
                .background(theme.color(.panelBackground))
        }
    }

    private func valueList(_ values: [GlossaryEntry.Value]) -> some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
            SectionLabel(text: "Values")
            ForEach(values) { value in
                VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                    Text(value.value)
                        .font(theme.font(.mono))
                        .foregroundStyle(theme.color(.primaryText))
                    Caption(value.summary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func footer(_ entry: GlossaryEntry) -> some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
            let related = (entry.seeAlso ?? []).compactMap { glossary.entry(for: $0) }
            if !related.isEmpty {
                SectionLabel(text: "See also")
                // Wrapping, because a term with five cross-references would
                // otherwise push the window wider than its content needs.
                FlowRow(spacing: theme.metric(.spacingS)) {
                    ForEach(related) { entry in
                        Button(entry.title) { model.selectedTerm = entry.term }
                            .buttonStyle(.link)
                            .font(theme.font(.caption))
                    }
                }
            }

            if let documentation = entry.documentation, let url = URL(string: documentation) {
                Link("ZMK documentation", destination: url)
                    .font(theme.font(.caption))
            }
        }
    }
}

/// Lays its children out in rows, wrapping when one will not fit.
///
/// `HStack` would push the window wider than its content and `LazyVGrid` would
/// give every cross-reference the width of the longest one. This is the layout
/// SwiftUI does not ship.
struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, within: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(of: subviews, within: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(of subviews: Subviews, within limit: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            // An item wider than the whole row still gets a row; it overflows
            // rather than being dropped or shrunk to nothing.
            if needed > limit, !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
