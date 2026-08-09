import SwiftUI
import ZmkonfigKit

/// Edits one binding: pick a behavior, then fill one slot per parameter the
/// behavior declares. Every change is handed straight back through `apply`, so
/// there is no separate "apply" step to forget.
///
/// A key on the board and a combo both bind exactly one behavior, so they share
/// this view — only where the binding comes from and where it goes differ.
struct BindingFieldsView: View {
    @Environment(\.theme) private var theme
    let model: AppModel
    let binding: KeyBinding
    let apply: (KeyBinding) -> Void
    /// `&trans` and `&none` mean nothing on a combo, so its editor leaves the
    /// shortcuts out.
    var showsTransparentAndNone = true

    @State private var keycodePickerSlot: SlotIndex?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingL)) {
            behaviorPicker
            slots
            if showsTransparentAndNone { quickActions }
        }
        .sheet(item: $keycodePickerSlot) { slot in
            KeycodePickerView(
                keycodes: model.keycodes,
                current: currentBase(atSlot: slot.value)?.value ?? "",
                onPick: { value in setBase(atSlot: slot.value, to: value) }
            )
        }
    }

    // MARK: - Sections

    private var behaviorPicker: some View {
        FieldRow(label: "Behavior") {
            Picker("Behavior", selection: behaviorSelection) {
                ForEach(model.availableBehaviors) { behavior in
                    Text("\(behavior.name)  \(behavior.code)").tag(behavior.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var slots: some View {
        let kinds = slotKinds
        if kinds.isEmpty {
            Caption("This behavior takes no parameters.")
        } else {
            // A custom behavior with two inferred slots is a hold-tap; say so
            // rather than calling them "Keycode" and "Keycode 2".
            let isHoldTap = !model.isDocumentedBehavior(binding.behavior) && kinds.count == 2
            ForEach(Array(kinds.enumerated()), id: \.offset) { slot, kind in
                FieldRow(label: isHoldTap
                         ? (slot == 0 ? "Hold" : "Tap")
                         : Self.slotTitle(kind: kind, slot: slot)) {
                    slotEditor(kind: kind, slot: slot)
                }
            }
        }
    }

    @ViewBuilder
    private func slotEditor(kind: ParamKind, slot: Int) -> some View {
        switch kind {
        case .layer:
            layerSlot(slot: slot)
        case .command:
            commandSlot(slot: slot)
        case .code, .mod:
            keycodeSlot(slot: slot)
        }
    }

    private var quickActions: some View {
        HStack(spacing: theme.metric(.spacingS)) {
            Button("&trans") { apply(KeyBinding(behavior: "&trans")) }
                .disabled(binding.behavior == "&trans")
            Button("&none") { apply(KeyBinding(behavior: "&none")) }
                .disabled(binding.behavior == "&none")
            Spacer()
        }
        .font(theme.font(.caption))
    }

    // MARK: - Slot editors

    @ViewBuilder
    private func keycodeSlot(slot: Int) -> some View {
        let decomposed = Self.decompose(param(at: slot) ?? BindingParam(value: ""))
        VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
            HStack(spacing: theme.metric(.spacingXS)) {
                ForEach(Self.modifierFamilies, id: \.left) { family in
                    let isOn = decomposed.mods.contains(family.left) || decomposed.mods.contains(family.right)
                    Button(family.symbol) {
                        toggleModifier(family, slot: slot)
                    }
                    .buttonStyle(.bordered)
                    .tint(isOn ? theme.color(.accent) : nil)
                    .help(family.name)
                }
                Spacer(minLength: 0)
            }

            Button {
                keycodePickerSlot = SlotIndex(value: slot)
            } label: {
                HStack {
                    Text(decomposed.base.value.isEmpty ? "Choose a keycode…" : decomposed.base.value)
                        .font(theme.font(.mono))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(theme.font(.caption))
                }
                .contentShape(Rectangle())
            }

            if let current = param(at: slot), !current.text.isEmpty {
                Caption(BindingLabel.keycodeLabel(current))
            }
        }
    }

    @ViewBuilder
    private func layerSlot(slot: Int) -> some View {
        let current = param(at: slot)?.value ?? ""
        Picker("Layer", selection: Binding(
            get: { current },
            set: { setParam(at: slot, to: BindingParam(value: $0)) }
        )) {
            ForEach(model.layers) { layer in
                Text("\(layer.id) · \(layer.displayName)").tag(String(layer.id))
            }
            // The keymap may reference a layer through a #define; keep it
            // selectable rather than silently rewriting it to a number.
            if !model.layers.contains(where: { String($0.id) == current }) {
                Text(current.isEmpty ? "(unset)" : current).tag(current)
            }
        }
        .labelsHidden()
    }

    @ViewBuilder
    private func commandSlot(slot: Int) -> some View {
        let behavior = model.behavior(for: binding.behavior)
        let commands = behavior?.commands ?? []
        let current = param(at: slot)?.value ?? ""
        let selected = commands.first { $0.code == current }

        VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
            Picker("Command", selection: Binding(
                get: { current },
                set: { newValue in
                    setParam(at: slot, to: BindingParam(value: newValue))
                    syncCommandArgument(for: newValue, in: commands, slot: slot)
                }
            )) {
                ForEach(commands) { command in
                    Text(command.code).tag(command.code)
                }
                if !commands.contains(where: { $0.code == current }) {
                    Text(current.isEmpty ? "(unset)" : current).tag(current)
                }
            }
            .labelsHidden()

            if let description = selected?.description {
                Caption(description)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Commands such as BT_SEL take a trailing number, which lives in the
            // next binding parameter.
            if let extra = selected?.additionalParams?.first {
                FieldRow(label: extra.name ?? "value") {
                    IntegerField(
                        value: param(at: slot + 1)?.value ?? "0",
                        onCommit: { setParam(at: slot + 1, to: BindingParam(value: $0)) }
                    )
                }
            }
        }
    }

    // MARK: - Binding maths

    private struct SlotIndex: Identifiable {
        let value: Int
        var id: Int { value }
    }

    static let modifierFamilies: [(left: String, right: String, symbol: String, name: String)] = [
        ("LC", "RC", "⌃", "Control"),
        ("LA", "RA", "⌥", "Option"),
        ("LS", "RS", "⇧", "Shift"),
        ("LG", "RG", "⌘", "Command"),
    ]

    /// `LG(LS(A))` → mods `["LG", "LS"]`, base `A`.
    static func decompose(_ param: BindingParam) -> (mods: [String], base: BindingParam) {
        var mods: [String] = []
        var current = param
        while current.params.count == 1, BindingLabel.modifierSymbols[current.value] != nil {
            mods.append(current.value)
            current = current.params[0]
        }
        return (mods, current)
    }

    static func compose(mods: [String], base: BindingParam) -> BindingParam {
        mods.reversed().reduce(base) { inner, mod in BindingParam(value: mod, params: [inner]) }
    }

    private var slotKinds: [ParamKind] {
        let declared = model.behavior(for: binding.behavior)?.params ?? []
        guard declared.isEmpty else { return declared }
        // `AppModel.rebuildBehaviorIndex` synthesizes an entry for every
        // behavior a binding names, so the only gap left is a binding carrying
        // more parameters than its behavior admits to — a custom behavior whose
        // `#binding-cells` the parser could not read. Give it a slot each
        // rather than nothing to edit.
        return binding.params.map { _ in .code }
    }

    static func slotTitle(kind: ParamKind, slot: Int) -> String {
        switch kind {
        case .layer: "Layer"
        case .command: "Command"
        case .mod: "Modifier"
        case .code: slot == 0 ? "Keycode" : "Keycode \(slot + 1)"
        }
    }

    private func param(at slot: Int) -> BindingParam? {
        binding.params.indices.contains(slot) ? binding.params[slot] : nil
    }

    private func currentBase(atSlot slot: Int) -> BindingParam? {
        param(at: slot).map { Self.decompose($0).base }
    }

    private func setParam(at slot: Int, to newValue: BindingParam) {
        var edited = binding
        while edited.params.count <= slot {
            edited.params.append(BindingParam(value: "0"))
        }
        edited.params[slot] = newValue
        apply(edited)
    }

    private func setBase(atSlot slot: Int, to value: String) {
        let mods = Self.decompose(param(at: slot) ?? BindingParam(value: "")).mods
        setParam(at: slot, to: Self.compose(mods: mods, base: BindingParam(value: value)))
    }

    private func toggleModifier(
        _ family: (left: String, right: String, symbol: String, name: String),
        slot: Int
    ) {
        let decomposed = Self.decompose(param(at: slot) ?? BindingParam(value: ""))
        var mods = decomposed.mods
        if mods.contains(family.left) || mods.contains(family.right) {
            mods.removeAll { $0 == family.left || $0 == family.right }
        } else {
            mods.append(family.left)
        }
        setParam(at: slot, to: Self.compose(mods: mods, base: decomposed.base))
    }

    /// Adds or drops the trailing argument when the chosen command needs one.
    private func syncCommandArgument(for command: String, in commands: [ZMKCommand], slot: Int) {
        var edited = binding
        let needsArgument = commands.first { $0.code == command }?.additionalParams?.isEmpty == false
        let hasArgument = edited.params.count > slot + 1
        if needsArgument, !hasArgument {
            edited.params.append(BindingParam(value: "0"))
            apply(edited)
        } else if !needsArgument, hasArgument {
            edited.params.removeSubrange((slot + 1)...)
            apply(edited)
        }
    }

    private var behaviorSelection: Binding<String> {
        Binding(
            get: { binding.behavior },
            set: { code in
                guard code != binding.behavior, let behavior = model.behavior(for: code) else { return }
                apply(Self.rebuild(binding, as: behavior, layers: model.layers))
            }
        )
    }

    /// Keeps whatever parameters still make sense when the behavior changes and
    /// fills the rest with something valid.
    static func rebuild(_ binding: KeyBinding, as behavior: ZMKBehavior, layers: [KeymapLayer]) -> KeyBinding {
        let kinds = behavior.params ?? []
        var params: [BindingParam] = []
        for (index, kind) in kinds.enumerated() {
            if binding.params.indices.contains(index) {
                params.append(binding.params[index])
            } else {
                params.append(BindingParam(value: defaultValue(for: kind, behavior: behavior, layers: layers)))
            }
        }
        return KeyBinding(behavior: behavior.code, params: params)
    }

    static func defaultValue(for kind: ParamKind, behavior: ZMKBehavior, layers: [KeymapLayer]) -> String {
        switch kind {
        case .layer: String(layers.first?.id ?? 0)
        case .command: behavior.commands?.first?.code ?? ""
        case .mod: "LEFT_SHIFT"
        case .code: "A"
        }
    }
}
