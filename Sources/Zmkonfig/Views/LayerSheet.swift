import SwiftUI
import ZmkonfigKit

/// Adds a layer or renames one.
///
/// The two share a sheet because they share the field that matters — the
/// display name — and differ only in what else has to be decided. Renaming
/// writes `display-name` and nothing else: a layer's *node* name is what
/// `KeymapFile` anchors its bindings splice to, so it is shown and not editable.
///
/// Adding is the one edit in the app that changes what a number elsewhere in the
/// file means, so the renumbering warning is on the sheet rather than after the
/// fact. Nothing rewrites those references — they can sit inside behaviors and
/// `#define`s this editor does not model, and a partial rewrite is worse than
/// none — so being told is the whole of the mitigation.
struct LayerSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let model: AppModel
    let intent: Intent

    @State private var displayName = ""
    @State private var nodeName = ""
    /// True once the user types in the node name field. Until then it follows
    /// the display name, which is what makes naming a layer one decision rather
    /// than two.
    @State private var isNodeNameEdited = false

    enum Intent: Identifiable, Hashable {
        /// Insert a new layer at this index.
        case add(at: Int)
        /// Rename the layer at this index.
        case rename(at: Int)

        var id: Self { self }

        var index: Int {
            switch self {
            case .add(let index), .rename(let index): index
            }
        }

        var isAdd: Bool {
            if case .add = self { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingM)) {
            SheetTitle(intent.isAdd ? "Add layer" : "Rename layer")

            FieldRow(label: "Display name") {
                TextField("Symbols", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                    .onChange(of: displayName) { _, _ in syncNodeName() }
            }

            FieldRow(label: "Node name") {
                VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                    TextField("symbol_layer", text: Binding(
                        get: { nodeName },
                        set: { name in
                            nodeName = name
                            isNodeNameEdited = true
                        }
                    ))
                    .font(theme.font(.mono))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!intent.isAdd)
                    Caption(intent.isAdd
                            ? "The devicetree node the layer is written as."
                            : "A layer's node name is what its bindings are spliced against, so "
                              + "it cannot be changed here.",
                            tone: .tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if intent.isAdd {
                FieldRow(label: "Position") {
                    Caption(placement)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let warning = renumbering {
                    WarningStrip(text: warning)
                }
            }

            // An empty field is not a mistake the user has made yet; the
            // disabled button already says it is not finished.
            if !trimmedDisplayName.isEmpty,
               let problem = KeymapFile.displayNameProblem(trimmedDisplayName) {
                WarningStrip(text: problem, tone: .danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(intent.isAdd ? "Add" : "Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(theme.metric(.spacingL))
        .frame(width: theme.metric(.dialogWidth))
        .background(theme.color(.panelBackground))
        .onAppear(perform: seed)
    }

    // MARK: - State

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNodeName: String {
        nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        guard KeymapFile.displayNameProblem(trimmedDisplayName) == nil else { return false }
        guard intent.isAdd else { return true }
        return KeymapCombo.isValidNodeName(trimmedNodeName)
            && model.keymap?.modelledNodeNames.contains(trimmedNodeName) != true
    }

    private var placement: String {
        let count = model.layers.count
        if intent.index >= count {
            return "Layer \(intent.index), at the end. No existing layer is renumbered."
        }
        return "Layer \(intent.index). Layer \(intent.index) and everything after it moves up "
            + "one number."
    }

    private var renumbering: String? {
        guard let affected = model.keymap?.layerReferencesAffected(byInsertingAt: intent.index)
        else { return nil }
        return AssistantTools.renumbering(affected)
    }

    private func seed() {
        switch intent {
        case .add:
            displayName = ""
            nodeName = model.uniqueNodeName(startingFrom: "layer")
        case .rename(let index):
            guard model.layers.indices.contains(index) else { return }
            displayName = model.layers[index].displayName
            nodeName = model.layers[index].nodeName
        }
    }

    /// Keeps the node name following the display name until the user takes it
    /// over, so naming a layer is one decision rather than two.
    private func syncNodeName() {
        guard intent.isAdd, !isNodeNameEdited else { return }
        nodeName = model.uniqueNodeName(
            startingFrom: trimmedDisplayName.isEmpty ? "layer" : "\(trimmedDisplayName) layer"
        )
    }

    private func commit() {
        guard isValid else { return }
        let name = trimmedDisplayName
        dismiss()
        switch intent {
        case .add(let index):
            model.addLayer(nodeName: trimmedNodeName, displayName: name, at: index)
        case .rename(let index):
            model.renameLayer(at: index, to: name)
        }
    }
}
