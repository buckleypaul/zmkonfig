import SwiftUI
import ZmkonfigKit

/// The middle column: which layer is showing, the board itself, and a status
/// line that never lies about the state of the working tree.
struct BoardPane: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    var body: some View {
        let comboProblems = model.comboProblems
        VStack(spacing: 0) {
            header
            Divider()
            if let mismatch = model.layoutMismatch {
                WarningStrip(
                    text: "This layer has \(mismatch.bindings) bindings but the layout has \(mismatch.positions) key positions. Pick a different layout or keyboard before saving."
                )
                .padding(theme.metric(.spacingM))
            }
            if !comboProblems.isEmpty {
                WarningStrip(text: comboProblems.map(\.message).joined(separator: " "), tone: .danger)
                    .padding(theme.metric(.spacingM))
            }
            board
            Divider()
            statusBar
        }
        .background(theme.color(.contentBackground))
        .toolbar { toolbarContent }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.metric(.spacingM)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedLayer?.displayName ?? "No layer")
                    .font(theme.font(.title))
                    .foregroundStyle(theme.color(.primaryText))
                if let combo = model.selectedCombo {
                    Caption("Picking keys for `\(combo.nodeName)` — click a key to add or remove it",
                        tone: .accent
                    )
                } else if let layer = model.selectedLayer {
                    Caption("\(layer.nodeName) · \(layer.bindings.count) bindings")
                }
            }

            Spacer(minLength: 0)

            if let keyboard = model.keyboard, keyboard.layouts.count > 1 {
                Picker("Layout", selection: $model.layoutKey) {
                    Text("Default").tag(String?.none)
                    ForEach(keyboard.layouts.keys.sorted(), id: \.self) { key in
                        Text(keyboard.layouts[key]?.name ?? key).tag(String?.some(key))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
        }
        .padding(.horizontal, theme.metric(.spacingL))
        .padding(.vertical, theme.metric(.spacingM))
    }

    // MARK: - Board

    @ViewBuilder
    private var board: some View {
        if model.repo == nil {
            Hint(text: "Open a repository to start editing.\nA GitHub owner/name slug, cloned on first use.")
        } else if model.layout.isEmpty {
            Hint(text: "No keyboard layout loaded. Choose a keyboard from the catalog.")
        } else if let layer = model.selectedLayer {
            KeyboardView(
                layout: model.layout,
                bindings: layer.bindings,
                layers: model.layers,
                behaviorsByCode: model.behaviorsByCode,
                selectedIndex: model.selectedKeyIndex,
                highlightedIndices: model.highlightedPositions,
                onSelect: { model.selectKey($0) }
            )
            .padding(theme.metric(.spacingL))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.color(.boardBackground))
        } else {
            Hint(text: "Select a layer.")
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: theme.metric(.spacingM)) {
            if let busy = model.busyMessage {
                ProgressView().controlSize(.small)
                Caption(busy)
            } else if let status = model.gitStatus {
                StatusDot(color: status.isDirty ? theme.color(.warning) : theme.color(.success))
                Caption(status.isDirty
                        ? "Working tree dirty — \(status.changedFiles.count) file(s) changed"
                        : "Working tree clean"
                )
                if status.ahead > 0 {
                    Caption("· \(status.ahead) commit(s) to push")
                }
            } else {
                Caption("No git status", tone: .tertiaryText)
            }

            Spacer(minLength: 0)

            if model.hasUnsavedEdits {
                Badge(text: "unsaved edits", tint: theme.color(.warning))
            }
            if let notice = model.notice {
                Caption(notice, tone: .success)
            }
        }
        .padding(.horizontal, theme.metric(.spacingL))
        .padding(.vertical, theme.metric(.spacingS))
        .background(theme.color(.panelBackground))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.isShowingRepoSheet = true
            } label: {
                Label("Repository", systemImage: "folder")
            }
            .help("Open a different repository")

            Button {
                model.isShowingCatalogSheet = true
                Task { await model.loadCatalog() }
            } label: {
                Label("Keyboard", systemImage: "keyboard")
            }
            .disabled(model.repo == nil)
            .help("Change the keyboard layout")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.pull() }
            } label: {
                Label("Pull", systemImage: "arrow.down")
            }
            .disabled(model.repo == nil || model.busyMessage != nil)
            .help("Pull: fetch the latest commits from GitHub and reload the keymap")

            Button {
                Task { await model.reloadKeymap() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(model.repo == nil || model.busyMessage != nil)
            .help("Reload: re-read the keymap from disk, discarding unsaved edits")

            Button {
                Task { await model.saveAndReview() }
            } label: {
                Label("Save & Review", systemImage: "square.and.arrow.down")
            }
            .disabled(model.repo == nil || model.keymap == nil || model.busyMessage != nil)
            .help("Save & Review: write the keymap, show the diff, then commit and push it to build new firmware")
        }
    }
}
