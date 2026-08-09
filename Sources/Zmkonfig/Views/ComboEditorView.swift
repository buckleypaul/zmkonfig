import SwiftUI
import ZmkonfigKit

/// Edits the selected combo: its name, the chord that fires it, what it sends,
/// and the timing and layer scoping ZMK allows.
///
/// Key positions are picked by clicking keys on the board rather than typed,
/// which is the whole reason a combo stays selected while a layer goes on
/// showing — see `AppModel.selectKey`.
struct ComboEditorView: View {
    @Environment(\.theme) private var theme
    let model: AppModel
    let combo: KeymapCombo

    @State private var isShowingAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metric(.spacingL)) {
                summary
                problems
                nameField
                positions
                SectionLabel(text: "Sends")
                BindingFieldsView(
                    model: model,
                    binding: combo.binding,
                    apply: { sent in model.updateCombo(with { $0.binding = sent }) },
                    showsTransparentAndNone: false
                )
                timing
                layerScope
                advanced
                Divider()
                removeButton
            }
            .padding(theme.metric(.spacingM))
        }
    }

    // MARK: - Sections

    private var summary: some View {
        // The tokens rather than the resolved numbers, so an untouched combo
        // reads here the way the sidebar and the file both say it.
        let tokens = model.keymap?.positionTokens(of: combo) ?? []
        return Card {
            VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                SectionLabel(text: "Combo")
                Text(combo.binding.text)
                    .font(theme.font(.mono))
                    .foregroundStyle(theme.color(.primaryText))
                    .textSelection(.enabled)
                Caption(tokens.isEmpty
                        ? "no key positions yet"
                        : "keys \(tokens.joined(separator: " + "))")
            }
        }
    }

    @ViewBuilder
    private var problems: some View {
        ForEach(model.problems(for: combo), id: \.self) { message in
            WarningStrip(text: message, tone: .danger)
        }
        // Whether the macros actually go is the writer's call, not something
        // this view should work out again from `unresolvedPositions`.
        if model.keymap?.willDiscardMacros(combo) == true {
            // Only shown once the positions have actually been edited, so it
            // says what saving will do now rather than what it might do later.
            WarningStrip(text: """
                This combo's key positions were written as \
                \(combo.unresolvedPositions.joined(separator: ", ")), which are \
                #defines this editor cannot resolve. Because you changed the \
                positions, saving replaces them with plain numbers.
                """)
        }
    }

    private var nameField: some View {
        FieldRow(label: "Node name") {
            TextField("combo-name", text: Binding(
                get: { combo.nodeName },
                set: { name in model.updateCombo(with { $0.nodeName = name }) }
            ))
            .font(theme.font(.mono))
            .textFieldStyle(.roundedBorder)
        }
    }

    private var positions: some View {
        FieldRow(label: "Key positions") {
            VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                if combo.keyPositions.isEmpty {
                    Caption("Click two or more keys on the board.")
                } else {
                    HStack(spacing: theme.metric(.spacingXS)) {
                        ForEach(combo.keyPositions, id: \.self) { position in
                            Button {
                                model.selectKey(position)
                            } label: {
                                Badge(text: "\(position) ×", tint: theme.color(.accent))
                            }
                            .buttonStyle(.plain)
                            .help("Remove key \(position) from this combo")
                        }
                        Spacer(minLength: 0)
                    }
                    Caption("Click a key on the board to add or remove it.", tone: .tertiaryText)
                }
            }
        }
    }

    private var timing: some View {
        FieldRow(label: "Timing") {
            OptionalIntegerField(
                label: "Timeout (ms)",
                placeholder: 50,
                value: combo.timeoutMs,
                onChange: { ms in model.updateCombo(with { $0.timeoutMs = ms }) }
            )
        }
    }

    private var layerScope: some View {
        FieldRow(label: "Layers") {
            VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                Toggle("All layers", isOn: Binding(
                    get: { combo.layers == nil },
                    set: { all in
                        let layers = all ? nil : model.layers.map(\.id)
                        model.updateCombo(with { $0.layers = layers })
                    }
                ))
                .toggleStyle(.checkbox)
                .font(theme.font(.body))

                if let layers = combo.layers {
                    HStack(spacing: theme.metric(.spacingXS)) {
                        ForEach(model.layers) { layer in
                            Button("\(layer.id)") { toggleLayer(layer.id) }
                                .buttonStyle(.bordered)
                                .tint(layers.contains(layer.id) ? theme.color(.accent) : nil)
                                .help(layer.displayName)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var advanced: some View {
        DisclosureGroup("Advanced", isExpanded: $isShowingAdvanced) {
            VStack(alignment: .leading, spacing: theme.metric(.spacingM)) {
                OptionalIntegerField(
                    label: "Require prior idle (ms)",
                    placeholder: 125,
                    value: combo.requirePriorIdleMs,
                    onChange: { ms in model.updateCombo(with { $0.requirePriorIdleMs = ms }) }
                )
                Toggle("Slow release", isOn: Binding(
                    get: { combo.isSlowRelease },
                    set: { on in model.updateCombo(with { $0.isSlowRelease = on }) }
                ))
                .toggleStyle(.checkbox)
                .font(theme.font(.body))
                .help("Release the combo's binding when the last key is let go, not the first")
            }
            .padding(.top, theme.metric(.spacingS))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(theme.font(.body))
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            model.removeCombo(id: combo.id)
        } label: {
            Label("Delete combo", systemImage: "trash")
        }
        .font(theme.font(.caption))
    }

    // MARK: - Editing

    /// A copy of the combo with one field changed.
    ///
    /// Every setter below is written out as a literal closure rather than built
    /// by a helper that returns one: a `Binding`'s setter is `@isolated(any)
    /// @Sendable`, and handing it a ready-made function value needs a
    /// reabstraction thunk that crashes the Swift 6.3.3 compiler in IRGen
    /// ("SmallVector unable to grow"). A closure written in place needs no
    /// thunk.
    private func with(_ assign: (inout KeymapCombo) -> Void) -> KeymapCombo {
        var edited = combo
        assign(&edited)
        return edited
    }

    private func toggleLayer(_ id: Int) {
        var layers = combo.layers ?? []
        if let index = layers.firstIndex(of: id) {
            layers.remove(at: index)
        } else {
            layers.append(id)
            layers.sort()
        }
        model.updateCombo(with { $0.layers = layers })
    }
}
