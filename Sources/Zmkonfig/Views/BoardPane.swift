import SwiftUI
import ZmkonfigKit

/// The middle column: which layer is showing, the board itself, and a status
/// line that never lies about the state of the working tree.
struct BoardPane: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel

    /// Discarding is not undoable, so it goes through a dialog that names what
    /// it is about to throw away.
    @State private var isConfirmingDiscard = false

    var body: some View {
        let comboProblems = model.comboProblems
        let inset = theme.metric(.panePadding)
        VStack(spacing: 0) {
            header
            if let mismatch = model.layoutMismatch {
                WarningStrip(
                    text: "This layer has \(mismatch.bindings) bindings but the layout has \(mismatch.positions) key positions. Pick a different layout or keyboard before saving."
                )
                .padding(.horizontal, inset)
                .padding(.bottom, theme.metric(.spacingS))
            }
            if !comboProblems.isEmpty {
                WarningStrip(text: comboProblems.map(\.message).joined(separator: " "), tone: .danger)
                    .padding(.horizontal, inset)
                    .padding(.bottom, theme.metric(.spacingS))
            }
            // The plate. It is the one recessed surface in the window, and it
            // is what says the board is a physical thing mounted in the pane
            // rather than more of the pane — so no divider above it: the step
            // down in surface is the separation.
            board
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .boardWell()
                .padding(.horizontal, inset)
            statusBar
        }
        .toolbar { toolbarContent }
        .confirmationDialog(
            "Discard local changes?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                Task { await model.discardLocalChanges() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(discardWarning)
        }
    }

    // MARK: - Working-copy recovery

    /// Tracked files a discard would put back to HEAD. Untracked ones are not
    /// counted: `discardLocalChanges` leaves those alone, so a dirty tree that
    /// is only untracked build output gives the button nothing to do.
    private var discardableFiles: [String] { model.gitStatus?.trackedChangedFiles ?? [] }

    /// Rebase is offered only for the one state a fast-forward cannot reach:
    /// commits on both sides. `behind` comes from the last fetch, so this
    /// lights up after a Pull has failed and refreshed the status — which is
    /// exactly when it is wanted.
    private var canRebase: Bool {
        guard let status = model.gitStatus else { return false }
        return status.ahead > 0 && status.behind > 0
    }

    /// What Discard costs, said plainly and in full — including which working
    /// copy it is talking about, because the app's checkout is not the one the
    /// user has open in a terminal.
    private var discardWarning: String {
        let files = discardableFiles
        let named = files.count <= 4
            ? files.joined(separator: ", ")
            : files.prefix(3).joined(separator: ", ") + " and \(files.count - 3) more"
        var lines = ["Uncommitted changes to \(named) are put back to the last commit. This cannot be undone."]
        if model.hasUnsavedEdits {
            lines.append("Unsaved edits in the editor are reloaded away with them.")
        }
        let untracked = model.gitStatus?.untrackedFiles.count ?? 0
        if untracked > 0 {
            lines.append("\(untracked) untracked file(s) are left alone.")
        }
        if let path = model.repo?.localURL.path {
            lines.append("Working copy: \(path)")
        }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.metric(.spacingM)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: theme.metric(.spacingS)) {
                    // The layer's own identity color on its name — the same
                    // mark the sidebar row carries, so the eyebrow over the
                    // board never disagrees with the list beside it.
                    if let layer = model.selectedLayer {
                        LayerAccentBar(layerID: layer.id)
                    }
                    Text(model.selectedLayer?.displayName ?? "No layer")
                        .font(theme.font(.title))
                        .foregroundStyle(theme.color(.primaryText))
                }
                // The bar fills whatever height it is offered; here nothing
                // above the board clamps that offer, so the title must be
                // what sets the row's height.
                .fixedSize(horizontal: false, vertical: true)
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
        .padding(.horizontal, theme.metric(.panePadding))
        .padding(.vertical, theme.metric(.spacingM))
    }

    // MARK: - Board

    @ViewBuilder
    private var board: some View {
        if model.repo == nil {
            Hint(text: "Open a repository to start editing.\nA GitHub owner/name slug, cloned on first use.")
        } else if model.layout.isEmpty {
            VStack(spacing: theme.metric(.spacingM)) {
                Caption("This repository does not say which keyboard it is for, so there is nothing to draw the keymap on yet.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose a Keyboard…") { model.promptForKeyboard() }
            }
            .frame(maxWidth: theme.metric(.dialogWidth), maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .padding(theme.metric(.spacingL))
        } else if let layer = model.selectedLayer {
            KeyboardView(
                layout: model.layout,
                bindings: layer.bindings,
                layers: model.layers,
                behaviors: model.behaviorIndex,
                selectedIndex: model.selectedKeyIndex,
                highlightedIndices: model.highlightedPositions,
                onSelect: { model.selectKey($0) }
            )
            .padding(theme.metric(.spacingL))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // No strip of its own colour and no rule above it: the status line sits
        // on the pane's own surface, below the well, and the gap is enough.
        .padding(.horizontal, theme.metric(.panePadding))
        .padding(.vertical, theme.metric(.spacingM))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ToolbarActionButton(
                title: "Repository",
                systemImage: "folder",
                help: "Open a different repository"
            ) {
                model.isShowingRepoSheet = true
            }

            ToolbarActionButton(
                title: "Keyboard",
                systemImage: "keyboard",
                help: "Change the keyboard layout"
            ) {
                model.isShowingCatalogSheet = true
                Task { await model.loadCatalog() }
            }
            .disabled(model.repo == nil)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            ToolbarActionButton(
                title: "Pull",
                systemImage: "arrow.down",
                help: "Pull: fetch the latest commits from GitHub and reload the keymap"
            ) {
                Task { await model.pull() }
            }
            .disabled(model.repo == nil || model.busyMessage != nil)

            ToolbarActionButton(
                title: "Rebase",
                systemImage: "arrow.triangle.branch",
                help: "Rebase: replay your local commits on top of the latest from GitHub, for when both sides have moved and a plain Pull cannot fast-forward. A conflict is rolled back, leaving the branch where it was."
            ) {
                Task { await model.pullRebase() }
            }
            .disabled(!canRebase || model.busyMessage != nil)

            ToolbarActionButton(
                title: "Discard Changes",
                systemImage: "arrow.uturn.backward",
                help: "Discard Changes: put every tracked file in the working copy back to the last commit, throwing away uncommitted edits, and reload the keymap. Untracked files are left alone."
            ) {
                isConfirmingDiscard = true
            }
            .disabled(discardableFiles.isEmpty || model.busyMessage != nil)

            ToolbarActionButton(
                title: "Reload",
                systemImage: "arrow.clockwise",
                help: "Reload: re-read the keymap from disk, discarding unsaved edits"
            ) {
                Task { await model.reloadKeymap() }
            }
            .disabled(model.repo == nil || model.busyMessage != nil)

            ToolbarActionButton(
                title: "Save & Review",
                systemImage: "square.and.arrow.down",
                help: "Save & Review: write the keymap, show the diff, then commit and push it to build new firmware"
            ) {
                Task { await model.saveAndReview() }
            }
            .disabled(model.repo == nil || model.keymap == nil || model.busyMessage != nil)
        }
    }
}
