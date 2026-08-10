import SwiftUI
import ZmkonfigKit

/// Edits one `zmk,behavior-*` node the keymap defines for itself: a hold-tap, a
/// tap dance, a mod-morph.
///
/// The shape of the form is the kind's, not this view's — how many bindings a
/// node takes, whether one may carry parameters, and which properties it may
/// set all come from ``BehaviorKind``, so a kind gaining a property upstream
/// appears here without an edit. What may be written is
/// ``BehaviorWriter/problems(with:)``, the same sentences the assistant is told,
/// shown as they are found rather than at save.
struct BehaviorEditorView: View {
    @Environment(\.theme) private var theme
    let model: AppModel
    let explain: ExplainModel
    let behavior: KeymapBehavior

    @State private var isConfirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metric(.spacingL)) {
                summary
                problems
                description
                kindPicker
                names
                bindings
                properties
                Divider()
                removeButton
            }
            .padding(theme.metric(.spacingM))
        }
    }

    // MARK: - Sections

    /// The node in English.
    ///
    /// `AssistantTools.summary` used to be what this drew, and it is the wrong
    /// register: `flavor "balanced", tapping-term-ms 200, quick-tap-ms 175` is
    /// the node's properties transcribed, which the fields below already show,
    /// and it tells someone who does not know what `quick-tap-ms` is exactly
    /// nothing. That summary exists to be read by the model, where terseness is
    /// the point. Here the sentence is the point.
    private var summary: some View {
        Card {
            VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                SectionLabel(text: "Behavior")
                Text("&\(behavior.label)")
                    .font(theme.font(.mono))
                    .foregroundStyle(theme.color(.primaryText))
                    .textSelection(.enabled)
                Caption(BehaviorNarrator.description(of: behavior, glossary: model.glossary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var problems: some View {
        ForEach(BehaviorWriter.problems(with: behavior), id: \.self) { message in
            WarningStrip(text: message, tone: .danger)
        }
    }

    /// What the behavior is *for*, saved into the keymap as a
    /// ``BehaviorNote``.
    ///
    /// The card above says what the node does, derived from the node and always
    /// current. This is the part that cannot be derived from anything — why it
    /// exists, what its timings are tuned against, which hand it serves — so it
    /// is written down once, in the file, and travels with it.
    private var description: some View {
        FieldRow(label: "Description") {
            VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                TextField("What is this behavior for?", text: Binding(
                    get: { behavior.note ?? "" },
                    set: { text in
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.updateBehavior(with { $0.note = trimmed.isEmpty ? nil : text })
                    }
                ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .font(theme.font(.body))

                Caption(
                    "Saved in the keymap as a `/* \(BehaviorNote.marker) … */` comment, and "
                        + "shown wherever `&\(behavior.label)` is bound.",
                    tone: .tertiaryText
                )
                .fixedSize(horizontal: false, vertical: true)

                draft
            }
        }
        // A description is about one behavior and only that one, so a draft
        // does not follow the selection to the next.
        .onChange(of: behavior.id) { _, _ in explain.behavior.clear() }
    }

    /// Claude's draft, and the button that puts it in the field.
    ///
    /// Nothing here writes to the keymap. The draft is copied into the text
    /// field by the user, and saving it takes the same path a typed one does —
    /// which is what keeps "model output reaches the file" a thing the user
    /// does deliberately rather than something that happens.
    @ViewBuilder
    private var draft: some View {
        let subject = ExplainModel.behaviorSubject(behavior.label)
        let answer = explain.behavior.text(for: subject)

        VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
            HStack(spacing: theme.metric(.spacingS)) {
                Button(answer == nil ? "Draft with Claude" : "Again") {
                    explain.describeBehavior(behavior, context: model.context)
                }
                .disabled(explain.behavior.isRunning || !explain.behavior.isConfigured)

                if let answer {
                    Button("Use this") {
                        model.updateBehavior(with { $0.note = answer })
                        explain.behavior.clear()
                    }
                    Button("Discard") { explain.behavior.clear() }
                }
                Spacer(minLength: 0)
            }
            .font(theme.font(.caption))

            if !explain.behavior.isConfigured {
                Caption("Add an API key in Settings to draft one.", tone: .tertiaryText)
            }

            ClaudeAnswer(
                request: explain.behavior,
                subject: subject,
                working: "Reading the keymap…"
            )
        }
    }

    private var kindPicker: some View {
        // The kind's own summary here, not this node's description: the rest of
        // this editor *is* the node's description, field by field.
        FieldRow(
            label: "Kind",
            term: behavior.kind?.glossaryTerm,
            summary: behavior.kind.flatMap { model.glossary.summary(for: $0.glossaryTerm) }
        ) {
            VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                Picker("Kind", selection: Binding(
                    get: { behavior.compatible },
                    set: { compatible in changeKind(to: compatible) }
                )) {
                    ForEach(Self.kinds, id: \.self) { kind in
                        Text(kind.displayName).tag(kind.compatible)
                    }
                    // A `compatible` this editor has no table entry for is still
                    // the file's, and picking a kind is not a reason to lose it.
                    if behavior.kind == nil {
                        Text(behavior.compatible).tag(behavior.compatible)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Caption(behavior.compatible, tone: .tertiaryText)
            }
        }
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingM)) {
            FieldRow(label: "Label") {
                VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                    TextField("hml", text: Binding(
                        get: { behavior.label },
                        set: { label in model.updateBehavior(with { $0.label = label }) }
                    ))
                    .font(theme.font(.mono))
                    .textFieldStyle(.roundedBorder)
                    Caption("What a binding writes: `&\(behavior.label)`.", tone: .tertiaryText)
                }
            }
            FieldRow(label: "Node name") {
                TextField("hold_tap_left", text: Binding(
                    get: { behavior.nodeName },
                    set: { name in model.updateBehavior(with { $0.nodeName = name }) }
                ))
                .font(theme.font(.mono))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Bindings

    @ViewBuilder
    private var bindings: some View {
        let shape = behavior.kind?.bindings ?? .phandleArray(count: nil)
        if case .none = shape {
            FieldRow(label: "Bindings") {
                Caption("A \(kindName) wraps no behaviors; it is configured entirely by its "
                        + "properties.")
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            FieldRow(label: "Bindings") {
                VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                    ForEach(Array(behavior.bindings.enumerated()), id: \.offset) { slot, entry in
                        bindingRow(slot: slot, entry: entry, shape: shape)
                    }
                    // Only a kind whose length is the point — a tap dance — can
                    // grow: every other kind's count is fixed by ZMK and a row
                    // the user can add is a row they can only be told off for.
                    if case .phandleArray(.none) = shape {
                        HStack(spacing: theme.metric(.spacingS)) {
                            Button("Add binding") {
                                model.updateBehavior(with { $0.bindings.append("&kp A") })
                            }
                            Spacer(minLength: 0)
                        }
                        .font(theme.font(.caption))
                    }
                    Caption(hint(for: shape), tone: .tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func bindingRow(slot: Int, entry: String, shape: BehaviorBindings) -> some View {
        HStack(spacing: theme.metric(.spacingS)) {
            Caption(slotLabel(slot), tone: .tertiaryText)
                .frame(width: theme.metric(.numericFieldWidth), alignment: .leading)

            if shape.allowsParameters {
                // A whole binding, parameters included — free text, parsed the
                // same way the file is so `&kp LS(N1)` means here what it means
                // there.
                NormalizingField(
                    placeholder: "&kp A",
                    value: entry,
                    onChange: { text in model.updateBehavior(with { $0.bindings[slot] = text }) }
                )
            } else {
                // A bare reference. A picker, because the set of legal values is
                // exactly the behaviors that exist and a typo here is a build
                // failure a long way from the cause.
                Picker("Binding", selection: Binding(
                    get: { entry },
                    set: { code in model.updateBehavior(with { $0.bindings[slot] = code }) }
                )) {
                    ForEach(model.availableBehaviors) { available in
                        Text(available.code).tag(available.code)
                    }
                    if !model.availableBehaviors.contains(where: { $0.code == entry }) {
                        Text(entry.isEmpty ? "(unset)" : entry).tag(entry)
                    }
                }
                .labelsHidden()
            }

            if case .phandleArray(.none) = shape {
                Button {
                    model.updateBehavior(with { $0.bindings.remove(at: slot) })
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help("Remove this binding")
            }
        }
    }

    /// "Hold" and "Tap" rather than "1" and "2" — a hold-tap's bindings are
    /// ordered and getting them the wrong way round is the mistake this view
    /// exists to prevent.
    private func slotLabel(_ slot: Int) -> String {
        if behavior.kind == .holdTap, behavior.bindings.count == 2 {
            return slot == 0 ? "Hold" : "Tap"
        }
        if behavior.kind == .modMorph, behavior.bindings.count == 2 {
            return slot == 0 ? "Normal" : "Morphed"
        }
        return "\(slot + 1)"
    }

    private func hint(for shape: BehaviorBindings) -> String {
        switch shape {
        case .none:
            ""
        case .phandles(let count):
            "A \(kindName) names \(count) behavior\(count == 1 ? "" : "s") and no parameters — "
                + "the parameters come from whatever binds `&\(behavior.label)`."
        case .phandleArray(let count):
            count.map { "A \(kindName) takes exactly \($0) whole bindings, parameters included." }
                ?? "Whole bindings, parameters included. A \(kindName) takes as many as it needs."
        }
    }

    private var kindName: String {
        behavior.kind?.displayName.lowercased() ?? "behavior"
    }

    // MARK: - Properties

    @ViewBuilder
    private var properties: some View {
        FieldRow(label: "Properties") {
            VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                ForEach(propertyNames, id: \.self) { name in
                    propertyRow(name)
                }
                if propertyNames.isEmpty {
                    Caption("This kind of behavior has no properties to set.")
                }
            }
        }
    }

    /// Every property to offer: the ones the kind names, then anything else the
    /// node already carries, in the order the file wrote it.
    ///
    /// A property the file has and the kind does not name is not a mistake — a
    /// repo pinned to a newer ZMK than this table knows has them — so it is
    /// shown rather than hidden behind an editor that would drop it.
    private var propertyNames: [String] {
        guard let kind = behavior.kind else { return behavior.properties.map(\.name) }
        var names = kind.requiredProperties
        names += kind.optionalProperties.filter { !names.contains($0) }
        names += behavior.properties.map(\.name).filter { !names.contains($0) }
        return names
    }

    @ViewBuilder
    private func propertyRow(_ name: String) -> some View {
        let current = behavior.properties.first { $0.name == name }?.value
        let shape = current.map { BehaviorPropertyShape.shape(of: name, value: $0) }
            ?? BehaviorPropertyShape.shape(of: name)
        let isRequired = behavior.kind?.requiredProperties.contains(name) == true

        HStack(alignment: .firstTextBaseline, spacing: theme.metric(.spacingS)) {
            Toggle(name, isOn: Binding(
                get: { current != nil },
                set: { on in setProperty(name, to: on ? shape.initialValue : nil) }
            ))
            .toggleStyle(.checkbox)
            .font(theme.font(.mono))
            .help(isRequired ? "\(kindName.capitalized) requires this property" : name)

            // The tooltip above used to be the whole story, and for an optional
            // property it was the property's own name — no help at all to
            // someone looking at `retro-tap` for the first time.
            HelpBadge(term: name)

            if let current {
                propertyValue(name, shape: shape, value: current)
            } else if isRequired {
                Caption("required", tone: .danger)
            } else {
                Caption("not set", tone: .tertiaryText)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func propertyValue(
        _ name: String, shape: BehaviorPropertyShape, value: BehaviorValue
    ) -> some View {
        switch shape {
        case .choiceless:
            // The checkbox *is* the value: devicetree writes a flag as a bare
            // `retro-tap;` and has no way to write one as false.
            Caption("written", tone: .secondaryText)

        case .integer:
            IntegerField(
                value: Self.editableText(value),
                onCommit: { text in
                    guard let number = Int(text) else { return }
                    setProperty(name, to: .integer(number))
                }
            )

        case .choice(let options, _):
            // The picker and the gloss for what is picked, stacked. `flavor` is
            // the one property people most often change without being able to
            // find out what the four options mean, and a footnote elsewhere is
            // not where that gets answered.
            VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                Picker(name, selection: Binding(
                    get: { Self.editableText(value) },
                    set: { choice in setProperty(name, to: .string(choice)) }
                )) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                    // A file may already say something this table does not list.
                    if !options.contains(Self.editableText(value)) {
                        Text(Self.editableText(value)).tag(Self.editableText(value))
                    }
                }
                .labelsHidden()

                if let chosen = model.glossary.entry(for: name)?
                    .values?.first(where: { $0.value == Self.editableText(value) }) {
                    Caption(chosen.summary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .tokens(let hint):
            tokenField(name, hint: hint, value: value, asNumbers: false)

        case .numbers:
            tokenField(name, hint: "0 1 2", value: value, asNumbers: true)
        }
    }

    /// The value as it goes into a field the user types in.
    ///
    /// `AssistantTools.text` is for a sentence and quotes a string, which is
    /// right there and wrong in a text field — the quotes are added back on
    /// write, so a field showing them would round trip into `""balanced""`.
    private static func editableText(_ value: BehaviorValue) -> String {
        if case .string(let text) = value { return text }
        return AssistantTools.text(value)
    }

    /// A whitespace-separated cell, typed rather than picked.
    ///
    /// `hold-trigger-key-positions` is numbers and `mods` is a `#define`
    /// expression this editor cannot resolve, and both are one `<…>` of
    /// space-separated fields — so they share a field, and what the fields turn
    /// into is the only difference.
    private func tokenField(
        _ name: String, hint: String, value: BehaviorValue, asNumbers: Bool
    ) -> some View {
        NormalizingField(placeholder: hint, value: Self.editableText(value)) { text in
            let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
            // An emptied field is left alone rather than written as `<>`, which
            // devicetree rejects and `BehaviorWriter.problems` refuses.
            // Unchecking the box is how a property is removed.
            guard !fields.isEmpty else { return }
            let numbers = fields.compactMap(Int.init)
            setProperty(
                name,
                to: asNumbers && numbers.count == fields.count
                    ? .integers(numbers)
                    : .tokens(fields)
            )
        }
    }

    // MARK: - Deleting

    private var removeButton: some View {
        Button(role: .destructive) {
            isConfirmingDelete = true
        } label: {
            Label("Delete behavior", systemImage: "trash")
        }
        .font(theme.font(.caption))
        .confirmationDialog(
            "Delete `&\(behavior.label)`?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.removeBehavior(id: behavior.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            let uses = model.usage(ofLabel: behavior.label)
            Text(uses.isEmpty
                 ? "Nothing this editor can see binds `&\(behavior.label)`."
                 : "`&\(behavior.label)` is still bound by \(uses.joined(separator: ", ")). "
                   + "Those bindings will not resolve.")
        }
    }

    // MARK: - Editing

    /// The kinds offered, minus macros.
    ///
    /// `BehaviorReader` hands `zmk,behavior-macro*` nodes to `MacroReader` and
    /// never reads one back as a behavior, so a node written with that
    /// `compatible` from here would vanish from this editor the moment the file
    /// was reparsed. The macro editor is where a macro is made — the same
    /// exclusion, for the same reason, as `AssistantTools.behaviorKinds`.
    private static let kinds = BehaviorKind.allCases.filter { $0 != .macroBehavior }

    /// Changing the kind carries `#binding-cells` along, because upstream
    /// declares it a `const` on the kind rather than something a node chooses —
    /// leaving the old value behind produces a node ZMK rejects.
    private func changeKind(to compatible: String) {
        guard compatible != behavior.compatible else { return }
        guard let kind = BehaviorKind.kind(forCompatible: compatible) else { return }
        var edited = behavior
        edited.compatible = kind.compatible
        edited.bindingCells = kind.bindingCells
        switch kind.bindings {
        case .none:
            edited.bindings = []
        case .phandles(let count), .phandleArray(.some(let count)):
            edited.bindings = (0..<count).map { slot in
                behavior.bindings.indices.contains(slot) ? behavior.bindings[slot] : "&kp"
            }
            // A hold-tap's entries may not carry parameters; a mod-morph's must
            // be whole bindings. Coming from the other one, what is there is the
            // wrong shape.
            if !kind.bindings.allowsParameters {
                edited.bindings = edited.bindings.map {
                    $0.split(separator: " ").first.map(String.init) ?? $0
                }
            }
        case .phandleArray(.none):
            if edited.bindings.isEmpty { edited.bindings = ["&kp A"] }
        }
        for required in kind.requiredProperties
        where !edited.properties.contains(where: { $0.name == required }) {
            edited.properties.append(
                BehaviorProperty(
                    name: required, value: BehaviorPropertyShape.shape(of: required).initialValue
                )
            )
        }
        model.updateBehavior(edited)
    }

    private func setProperty(_ name: String, to value: BehaviorValue?) {
        model.updateBehavior(with { edited in
            guard let value else {
                edited.properties.removeAll { $0.name == name }
                return
            }
            if let index = edited.properties.firstIndex(where: { $0.name == name }) {
                edited.properties[index].value = value
            } else {
                edited.properties.append(BehaviorProperty(name: name, value: value))
            }
        })
    }

    /// A copy of the behavior with one field changed. Written out as a literal
    /// closure at every call site for the reason `ComboEditorView.with` gives.
    private func with(_ assign: (inout KeymapBehavior) -> Void) -> KeymapBehavior {
        var edited = behavior
        assign(&edited)
        return edited
    }
}
