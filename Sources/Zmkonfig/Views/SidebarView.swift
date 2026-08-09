import SwiftUI
import ZmkonfigKit

struct SidebarView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            repoHeader
                .padding(theme.metric(.spacingM))
            Divider()
            layerList
        }
        .background(theme.color(.sidebarBackground))
    }

    // MARK: - Repo header

    private var repoHeader: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
            SectionLabel(text: "Repository")

            if let repo = model.repo {
                Text(repo.slug)
                    .font(theme.font(.heading))
                    .foregroundStyle(theme.color(.primaryText))
                    .lineLimit(1)
                    .truncationMode(.head)

                HStack(spacing: theme.metric(.spacingS)) {
                    if let status = model.gitStatus {
                        Badge(text: status.branch)
                        if status.isDirty {
                            Badge(text: "\(status.changedFiles.count) changed", tint: theme.color(.warning))
                        }
                        if status.ahead > 0 {
                            Badge(text: "↑\(status.ahead)", tint: theme.color(.accent))
                        }
                    } else {
                        Badge(text: "no git status")
                    }
                }

                if let keyboard = model.keyboard {
                    Caption(keyboard.name ?? keyboard.id ?? "unknown keyboard")
                }
            } else {
                Text("No repository open")
                    .font(theme.font(.body))
                    .foregroundStyle(theme.color(.secondaryText))
                Button("Open Repository…") { model.isShowingRepoSheet = true }
                .font(theme.font(.caption))
            }
        }
    }

    // MARK: - Layers and combos

    private var layerList: some View {
        List(selection: $model.sidebarSelection) {
            Section {
                ForEach(model.layers) { layer in
                    layerRow(layer)
                        .tag(SidebarSelection.layer(layer.id))
                }
            } header: {
                SectionLabel(text: "Layers")
            }

            Section {
                ForEach(model.combos) { combo in
                    comboRow(combo)
                        .tag(SidebarSelection.combo(combo.id))
                }
                if model.combos.isEmpty {
                    Caption("No combos yet", tone: .tertiaryText)
                }
            } header: {
                HStack(spacing: theme.metric(.spacingS)) {
                    SectionLabel(text: "Combos")
                    Spacer(minLength: 0)
                    Button {
                        model.addCombo()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.keymap == nil)
                    .help("Add a combo")
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Text on a selected row. A theme color cannot be right here: the fill
    /// under it is drawn by AppKit and is the accent when the list has focus
    /// but a pale grey when it does not, and nothing is legible on both. These
    /// hand the two lines to SwiftUI's `primary`/`secondary`, which is what the
    /// list already inverts to match whichever fill it drew. An unselected row
    /// is the theme's, as everything else is.
    private func rowTitle(_ text: String, font: ThemeFontToken, selected: Bool) -> some View {
        Text(text)
            .font(theme.font(font))
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(theme.color(.primaryText)))
    }

    private func rowDetail(_ text: String, font: ThemeFontToken = .caption, selected: Bool) -> some View {
        Text(text)
            .font(theme.font(font))
            .foregroundStyle(selected ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.color(.tertiaryText)))
    }

    private func layerRow(_ layer: KeymapLayer) -> some View {
        let selected = model.sidebarSelection == .layer(layer.id)
        return HStack(spacing: theme.metric(.spacingS)) {
            rowDetail("\(layer.id)", font: .monoSmall, selected: selected)
                .frame(minWidth: 14, alignment: .trailing)
            VStack(alignment: .leading, spacing: 0) {
                rowTitle(layer.displayName, font: .body, selected: selected)
                rowDetail(layer.nodeName, selected: selected)
            }
            Spacer(minLength: 0)
            rowDetail("\(layer.bindings.count)", selected: selected)
        }
        .padding(.vertical, 2)
    }

    private func comboRow(_ combo: KeymapCombo) -> some View {
        let selected = model.sidebarSelection == .combo(combo.id)
        return HStack(spacing: theme.metric(.spacingS)) {
            VStack(alignment: .leading, spacing: 0) {
                rowTitle(combo.binding.text, font: .monoSmall, selected: selected)
                    .lineLimit(1)
                rowDetail(comboSubtitle(combo), selected: selected)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !model.problems(for: combo).isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.color(.danger))
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Delete", role: .destructive) { model.removeCombo(id: combo.id) }
        }
    }

    /// The positions as the file states them, so this cannot disagree with the
    /// inspector about a combo whose positions are `POS_*` macros.
    private func comboSubtitle(_ combo: KeymapCombo) -> String {
        let tokens = model.keymap?.positionTokens(of: combo) ?? combo.keyPositions.map(String.init)
        if tokens.isEmpty { return "no keys yet" }
        return "keys \(tokens.joined(separator: ", "))"
    }
}
