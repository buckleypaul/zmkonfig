import AppKit
import SwiftUI
import ZmkonfigKit

/// The menubar popover: every layer of the open keymap as a small board, and
/// the combos as a compact list. Read-only — clicking a key hands the selection
/// to the main window rather than editing anything here.
///
/// Its scene root applies `themedScene`; this view only reads the theme.
struct MenuBarPanel: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    /// Brings the editor forward. Passed in because only the app scene can open
    /// a window, and the panel has to work when none is open.
    let showEditor: () -> Void

    /// Which layer is zoomed, or nil for the grid.
    @State private var zoomedLayerID: Int?

    var body: some View {
        // Resolved once: half the panel branches on it, including every combo
        // row, and each lookup is a scan of the layers.
        let zoomed = zoomedLayerID.flatMap { id in model.layers.first { $0.id == id } }
        VStack(spacing: 0) {
            header(zoomed: zoomed)
            Divider()
            board(zoomed: zoomed)
            if !model.combos.isEmpty {
                Divider()
                combos(zoomed: zoomed)
            }
            Divider()
            footer
        }
        .frame(
            width: theme.metric(.menuBarPanelWidth),
            height: theme.metric(.menuBarPanelHeight)
        )
        .background(theme.color(.windowBackground))
    }

    // MARK: - Header

    @ViewBuilder
    private func header(zoomed: KeymapLayer?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.metric(.spacingS)) {
            if let zoomed {
                Button {
                    zoomedLayerID = nil
                } label: {
                    Label("All layers", systemImage: "chevron.left")
                        .font(theme.font(.caption))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.color(.accent))

                Text(zoomed.displayName)
                    .font(theme.font(.title))
                    .foregroundStyle(theme.color(.primaryText))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.repo?.slug ?? "No repository")
                        .font(theme.font(.title))
                        .foregroundStyle(theme.color(.primaryText))
                    Caption(subtitle)
                }
            }

            Spacer(minLength: 0)

            if model.hasUnsavedEdits {
                Badge(text: "unsaved edits", tint: theme.color(.warning))
            }
        }
        .padding(.horizontal, theme.metric(.spacingM))
        .padding(.vertical, theme.metric(.spacingS))
    }

    private var subtitle: String {
        guard model.repo != nil else { return "Open one in the editor to see it here" }
        let keyboard = model.layoutVariant?.name ?? model.keyboard?.name ?? "unknown keyboard"
        return "\(keyboard) · \(model.layers.count) layer(s) · \(model.combos.count) combo(s)"
    }

    // MARK: - Boards

    @ViewBuilder
    private func board(zoomed: KeymapLayer?) -> some View {
        if model.repo == nil {
            Hint(text: "No repository open.\nOpen one in Zmkonfig and it will show up here.")
        } else if model.layout.isEmpty {
            Hint(text: "No keyboard layout loaded.\nChoose a keyboard from the catalog in the editor.")
        } else if model.layers.isEmpty {
            Hint(text: "This keymap has no layers.")
        } else if let zoomed {
            zoomedBoard(zoomed)
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(minimum: theme.metric(.menuBarThumbnailWidth)),
                    spacing: theme.metric(.spacingS)
                )],
                spacing: theme.metric(.spacingS)
            ) {
                ForEach(model.layers) { layer in
                    thumbnail(layer)
                }
            }
            .padding(theme.metric(.spacingM))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func thumbnail(_ layer: KeymapLayer) -> some View {
        let combos = model.combos(onLayer: layer.id).count
        return Button {
            zoomedLayerID = layer.id
        } label: {
            Card {
                VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                    HStack(spacing: theme.metric(.spacingXS)) {
                        Text(layer.displayName)
                            .font(theme.font(.heading))
                            .foregroundStyle(theme.color(.primaryText))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if combos > 0 {
                            Caption("\(combos) combo\(combos == 1 ? "" : "s")", tone: .tertiaryText)
                        }
                    }
                    board(layer, density: .thumbnail)
                        .frame(height: theme.metric(.menuBarThumbnailHeight))
                        .padding(theme.metric(.spacingXS))
                        .background(
                            RoundedRectangle(cornerRadius: theme.metric(.cornerRadiusSmall))
                                .fill(theme.color(.boardBackground))
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .help("\(layer.nodeName) — click to open it")
    }

    private func zoomedBoard(_ layer: KeymapLayer) -> some View {
        VStack(spacing: theme.metric(.spacingXS)) {
            board(layer, density: .thumbnail) { index in
                model.reveal(layerID: layer.id, keyIndex: index)
                showEditor()
            }
            .padding(theme.metric(.spacingS))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.color(.boardBackground))

            Caption("Click a key to edit it in Zmkonfig", tone: .tertiaryText)
                .padding(.bottom, theme.metric(.spacingXS))
        }
    }

    private func board(
        _ layer: KeymapLayer,
        density: BoardDensity,
        onSelect: ((Int) -> Void)? = nil
    ) -> some View {
        KeyboardView(
            layout: model.layout,
            bindings: layer.bindings,
            layers: model.layers,
            behaviors: model.behaviorIndex,
            onSelect: onSelect,
            density: density
        )
    }

    // MARK: - Combos

    private func combos(zoomed: KeymapLayer?) -> some View {
        let rows = zoomed.map { model.combos(onLayer: $0.id) } ?? model.combos
        return VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
            SectionLabel(text: zoomed == nil ? "Combos" : "Combos on this layer")
                .padding(.horizontal, theme.metric(.spacingM))
                .padding(.top, theme.metric(.spacingS))

            if rows.isEmpty {
                Caption("None active on this layer", tone: .tertiaryText)
                    .padding(.horizontal, theme.metric(.spacingM))
                    .padding(.bottom, theme.metric(.spacingS))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                        ForEach(rows) { combo in
                            comboRow(combo, showScope: zoomed == nil)
                        }
                    }
                    .padding(.horizontal, theme.metric(.spacingM))
                    .padding(.bottom, theme.metric(.spacingS))
                }
                .frame(maxHeight: theme.metric(.menuBarComboListHeight))
            }
        }
    }

    private func comboRow(_ combo: KeymapCombo, showScope: Bool) -> some View {
        let tokens = model.positionTokens(of: combo)
        // Named off the base layer: `J + K` says more than `21 + 22`. The
        // numbers stay in the tooltip for anyone editing the file itself.
        let names = BindingLabel.keyNames(
            for: tokens,
            on: model.layers.first,
            layers: model.layers,
            behaviors: model.behaviorIndex
        )
        return HStack(alignment: .firstTextBaseline, spacing: theme.metric(.spacingS)) {
            Text(names.isEmpty ? "no keys" : names.joined(separator: " + "))
                .font(theme.font(.monoSmall))
                .foregroundStyle(theme.color(.secondaryText))
                .lineLimit(1)
            Text("→")
                .font(theme.font(.caption))
                .foregroundStyle(theme.color(.tertiaryText))
            Text(combo.binding.text)
                .font(theme.font(.monoSmall))
                .foregroundStyle(theme.color(.primaryText))
                .lineLimit(1)
            Spacer(minLength: 0)
            if showScope {
                Caption(scope(of: combo), tone: .tertiaryText)
                    .lineLimit(1)
            }
        }
        .help("\(combo.nodeName) — positions \(tokens.isEmpty ? "none" : tokens.joined(separator: ", "))")
    }

    private func scope(of combo: KeymapCombo) -> String {
        guard let layers = combo.layers, !layers.isEmpty else { return "all layers" }
        let names = layers.map { index in
            model.layers.indices.contains(index) ? model.layers[index].displayName : "layer \(index)"
        }
        return names.joined(separator: ", ")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: theme.metric(.spacingM)) {
            Button("Open Zmkonfig") { showEditor() }
            Spacer(minLength: 0)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(theme.color(.secondaryText))
        }
        .font(theme.font(.caption))
        .padding(.horizontal, theme.metric(.spacingM))
        .padding(.vertical, theme.metric(.spacingS))
        .background(theme.color(.panelBackground))
    }
}
