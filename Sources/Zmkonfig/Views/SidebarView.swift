import SwiftUI
import ZmkonfigKit

struct SidebarView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    /// The add/rename sheet, or nil. One piece of state rather than two flags
    /// and an index, so the sheet cannot be open about a layer that is gone.
    @State private var layerSheet: LayerSheet.Intent?
    /// The layer a delete has been asked for and not yet confirmed. Deleting a
    /// layer renumbers the ones after it, so it is the one sidebar action that
    /// changes what a binding elsewhere in the file means.
    @State private var layerPendingDeletion: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            repoHeader
                .padding(theme.metric(.spacingM))
            Divider()
            layerList
        }
        .sheet(item: $layerSheet) { intent in
            LayerSheet(model: model, intent: intent)
        }
        .confirmationDialog(
            layerPendingDeletion.map { "Delete layer \($0)?" } ?? "Delete layer?",
            isPresented: Binding(
                get: { layerPendingDeletion != nil },
                set: { if !$0 { layerPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let index = layerPendingDeletion { model.removeLayer(at: index) }
                layerPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { layerPendingDeletion = nil }
        } message: {
            Text(deletionWarning)
        }
    }

    /// What removing the pending layer costs, in the assistant's own words —
    /// the bindings that keep the number they were written with and will point
    /// somewhere else afterwards. Nothing rewrites them; see `LayerSheet`.
    private var deletionWarning: String {
        guard let index = layerPendingDeletion, let keymap = model.keymap,
              model.layers.indices.contains(index)
        else { return "" }
        let layer = model.layers[index]
        let head = "“\(layer.displayName)” and its \(layer.bindings.count) bindings are removed "
            + "from the keymap."
        guard let note = AssistantTools.renumbering(keymap.layerReferencesAffected(byRemoving: index))
        else { return head }
        return head + " " + note
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
                sectionHeader("Layers", help: "Add a layer at the end") {
                    layerSheet = .add(at: model.layers.count)
                }
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
                sectionHeader("Combos", help: "Add a combo") { model.addCombo() }
            }

            Section {
                ForEach(model.behaviors) { behavior in
                    behaviorRow(behavior)
                        .tag(SidebarSelection.behavior(behavior.id))
                }
                if model.behaviors.isEmpty {
                    Caption("No custom behaviors yet", tone: .tertiaryText)
                }
            } header: {
                // A menu rather than a plain `+`: a behavior's kind decides the
                // shape of every field in the editor, so it is the one thing
                // that cannot be filled in afterwards without redoing the rest.
                HStack(spacing: theme.metric(.spacingS)) {
                    SectionLabel(text: "Behaviors")
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(Self.behaviorKinds, id: \.self) { kind in
                            Button(kind.displayName) { model.addBehavior(kind: kind) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(model.keymap == nil)
                    .help("Define a behavior")
                }
                .padding(.trailing, theme.metric(.scrollerGutter))
            }

            Section {
                ForEach(model.macros) { macro in
                    macroRow(macro)
                        .tag(SidebarSelection.macro(macro.id))
                }
                if model.macros.isEmpty {
                    Caption("No macros yet", tone: .tertiaryText)
                }
            } header: {
                sectionHeader("Macros", help: "Define a macro") { model.addMacro() }
            }
        }
        .listStyle(.sidebar)
        // The sidebar list paints its own background, which would fill the
        // pane card's corners back in and hide the surface the card chose.
        .scrollContentBackground(.hidden)
    }

    /// A macro is a behavior node too, but `BehaviorReader` hands
    /// `zmk,behavior-macro*` to `MacroReader` and never reads one back — so a
    /// macro made here would disappear from this editor on the next parse. The
    /// Macros section is where one is made.
    private static let behaviorKinds = BehaviorKind.allCases.filter { $0 != .macroBehavior }

    /// The `+` is inset from the trailing edge by `scrollerGutter`: the list's
    /// overlay scroller is drawn over the header and would otherwise swallow
    /// the click whenever the sidebar is scrolled.
    private func sectionHeader(
        _ title: String, help: String, add: @escaping () -> Void
    ) -> some View {
        HStack(spacing: theme.metric(.spacingS)) {
            SectionLabel(text: title)
            Spacer(minLength: 0)
            Button(action: add) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .disabled(model.keymap == nil)
            .help(help)
        }
        .padding(.trailing, theme.metric(.scrollerGutter))
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
        // The board goes on showing a layer while a combo, behavior or macro is
        // selected, and then no row is highlighted — which reads as though no
        // layer were open. This marks the one the board is actually drawing.
        let onBoard = model.selectedLayerID == layer.id
        return HStack(spacing: theme.metric(.spacingS)) {
            // The layer's identity color, as a bar rather than a filled row.
            LayerAccentBar(layerID: layer.id)
            // Always laid out, so a row does not shift when the mark appears.
            StatusDot(color: onBoard && !selected ? theme.color(.accent) : .clear)
                .help(onBoard ? "Showing on the board" : "")
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
        // The selected row's own wash, in the layer's own accent.
        .listRowBackground(selected ? theme.layerAccentSoft(layer.id) : Color.clear)
        // `.sidebar` style still paints its own emphasized/unemphasized
        // selection fill on top of `listRowBackground` — AppKit's own blue
        // when the list has focus, pale grey when it does not — regardless of
        // the wash above. `.tint` is what that fill is actually drawn in, so
        // this is what makes a selected row read as *this layer's* color
        // instead of the universal accent every other row would share.
        .tint(theme.layerAccent(layer.id))
        .contextMenu {
            Button("Rename…") { layerSheet = .rename(at: layer.id) }
            Button("Add Layer Above…") { layerSheet = .add(at: layer.id) }
            Button("Add Layer Below…") { layerSheet = .add(at: layer.id + 1) }
            Divider()
            Button("Delete", role: .destructive) { layerPendingDeletion = layer.id }
                // A keymap needs at least one layer, and `removeLayer` refuses
                // the last one. Saying so with a disabled item beats an alert.
                .disabled(model.layers.count < 2)
        }
    }

    private func behaviorRow(_ behavior: KeymapBehavior) -> some View {
        let selected = model.sidebarSelection == .behavior(behavior.id)
        return HStack(spacing: theme.metric(.spacingS)) {
            VStack(alignment: .leading, spacing: 0) {
                rowTitle("&\(behavior.label)", font: .monoSmall, selected: selected)
                    .lineLimit(1)
                rowDetail(behavior.kind?.displayName ?? behavior.compatible, selected: selected)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            problemBadge(BehaviorWriter.problems(with: behavior))
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Delete", role: .destructive) { model.removeBehavior(id: behavior.id) }
        }
    }

    private func macroRow(_ macro: KeymapMacro) -> some View {
        let selected = model.sidebarSelection == .macro(macro.id)
        return HStack(spacing: theme.metric(.spacingS)) {
            VStack(alignment: .leading, spacing: 0) {
                rowTitle("&\(macro.label)", font: .monoSmall, selected: selected)
                    .lineLimit(1)
                rowDetail("\(macro.bindings.count) steps", selected: selected)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            problemBadge(MacroWriter.problems(with: macro))
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Delete", role: .destructive) { model.removeMacro(id: macro.id) }
        }
    }

    /// The same warning triangle a combo with problems gets, carrying the
    /// writer's own sentences as its tooltip.
    @ViewBuilder
    private func problemBadge(_ problems: [String]) -> some View {
        if !problems.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(theme.font(.caption))
                .foregroundStyle(theme.color(.danger))
                .help(problems.joined(separator: "\n"))
        }
    }

    private func comboRow(_ combo: KeymapCombo) -> some View {
        let selected = model.sidebarSelection == .combo(combo.id)
        return HStack(spacing: theme.metric(.spacingS)) {
            LayerTargetDot(binding: combo.binding, layers: model.layers)
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
        let tokens = model.positionTokens(of: combo)
        if tokens.isEmpty { return "no keys yet" }
        return "keys \(tokens.joined(separator: ", "))"
    }
}
