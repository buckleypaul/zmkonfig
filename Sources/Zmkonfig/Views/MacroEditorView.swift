import SwiftUI
import ZmkonfigKit

/// Edits one `zmk,behavior-macro` node: the sequence it plays back, and the
/// timing and parameter count around it.
///
/// A step is typed rather than picked. A macro's sequence mixes real bindings
/// with ZMK's own control behaviors — `&macro_tap`, `&macro_wait_time 40`,
/// `&macro_param_1to1` — and every one of them is ordinary binding text, so it
/// goes through `BindingParser` exactly as the file does and means here what it
/// means there. The Insert menu is a shortcut for the control ones, not a
/// different way of writing them.
struct MacroEditorView: View {
    @Environment(\.theme) private var theme
    let model: AppModel
    let macro: KeymapMacro

    @State private var isConfirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metric(.spacingL)) {
                summary
                problems
                names
                parameters
                sequence
                timing
                Divider()
                removeButton
            }
            .padding(theme.metric(.spacingM))
        }
    }

    // MARK: - Sections

    private var summary: some View {
        Card {
            VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                SectionLabel(text: "Macro", term: "macro")
                Text("&\(macro.label)")
                    .font(theme.font(.mono))
                    .foregroundStyle(theme.color(.primaryText))
                    .textSelection(.enabled)
                Caption(AssistantTools.summary(of: macro, sequenceLimit: 8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var problems: some View {
        ForEach(MacroWriter.problems(with: macro), id: \.self) { message in
            WarningStrip(text: message, tone: .danger)
        }
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingM)) {
            FieldRow(label: "Label") {
                VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                    TextField("email", text: Binding(
                        get: { macro.label },
                        set: { label in model.updateMacro(with { $0.label = label }) }
                    ))
                    .font(theme.font(.mono))
                    .textFieldStyle(.roundedBorder)
                    Caption("What a binding writes: `&\(macro.label)`.", tone: .tertiaryText)
                }
            }
            FieldRow(label: "Node name") {
                TextField("email_macro", text: Binding(
                    get: { macro.nodeName },
                    set: { name in model.updateMacro(with { $0.nodeName = name }) }
                ))
                .font(theme.font(.mono))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    /// The parameter count picks the `compatible` rather than sitting beside it.
    /// They are the same fact told twice and `MacroWriter.problems` refuses a
    /// node where the two disagree, so there is nothing to gain from letting a
    /// user set them apart.
    private var parameters: some View {
        FieldRow(label: "Parameters") {
            VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                Picker("Parameters", selection: Binding(
                    get: { macro.kind ?? .plain },
                    set: { kind in
                        model.updateMacro(with {
                            $0.compatible = kind.compatible
                            $0.bindingCells = kind.bindingCells
                        })
                    }
                )) {
                    ForEach(MacroKind.allCases, id: \.self) { kind in
                        Text("\(kind.bindingCells)").tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Caption(macro.bindingCells == 0
                        ? "A binding of `&\(macro.label)` takes no parameters."
                        : "A binding of `&\(macro.label)` takes \(macro.bindingCells), passed into "
                          + "the sequence with `&macro_param_1to1` and friends.",
                        tone: .tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - The sequence

    private var sequence: some View {
        FieldRow(label: "Sequence") {
            VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                if macro.bindings.isEmpty {
                    Caption("This macro has no steps, so invoking it would do nothing.")
                }
                ForEach(Array(macro.bindings.enumerated()), id: \.offset) { step, binding in
                    stepRow(step: step, binding: binding)
                }
                HStack(spacing: theme.metric(.spacingS)) {
                    Button("Add step") {
                        model.updateMacro(with {
                            $0.bindings.append(KeyBinding(behavior: "&kp", params: [BindingParam(value: "A")]))
                        })
                    }
                    Menu("Insert control step") {
                        ForEach(Self.controlSteps, id: \.text) { step in
                            Button(step.text) { append(step.text) }
                                .help(step.explanation)
                        }
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                .font(theme.font(.caption))
            }
        }
    }

    private func stepRow(step: Int, binding: KeyBinding) -> some View {
        HStack(spacing: theme.metric(.spacingS)) {
            Caption("\(step + 1)", tone: .tertiaryText)
                .frame(minWidth: theme.metric(.statusDotSize) * 2, alignment: .trailing)

            NormalizingField(
                placeholder: "&kp A",
                value: binding.text,
                onChange: { text in setStep(step, to: text) }
            )

            Button {
                model.updateMacro(with { $0.bindings.swapAt(step, step - 1) })
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(step == 0)
            .help("Move this step earlier")

            Button {
                model.updateMacro(with { $0.bindings.swapAt(step, step + 1) })
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(step == macro.bindings.count - 1)
            .help("Move this step later")

            Button {
                model.updateMacro(with { $0.bindings.remove(at: step) })
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("Remove this step")
        }
    }

    private var timing: some View {
        FieldRow(label: "Timing") {
            VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                OptionalIntegerField(
                    label: "Wait between steps (ms)",
                    placeholder: 30,
                    value: macro.waitMs,
                    onChange: { ms in model.updateMacro(with { $0.waitMs = ms }) }
                )
                OptionalIntegerField(
                    label: "Tap duration (ms)",
                    placeholder: 30,
                    value: macro.tapMs,
                    onChange: { ms in model.updateMacro(with { $0.tapMs = ms }) }
                )
            }
        }
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            isConfirmingDelete = true
        } label: {
            Label("Delete macro", systemImage: "trash")
        }
        .font(theme.font(.caption))
        .confirmationDialog(
            "Delete `&\(macro.label)`?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.removeMacro(id: macro.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            let uses = model.usage(ofLabel: macro.label)
            Text(uses.isEmpty
                 ? "Nothing this editor can see binds `&\(macro.label)`."
                 : "`&\(macro.label)` is still bound by \(uses.joined(separator: ", ")). "
                   + "Those bindings will not resolve.")
        }
    }

    // MARK: - Editing

    /// ZMK's own macro control behaviors, with what each is for.
    ///
    /// Not every macro binding — a step can be any behavior at all — only the
    /// ones that exist solely inside a macro and so appear in no behavior
    /// picker anywhere else in the app.
    private static let controlSteps: [(text: String, explanation: String)] = [
        ("&macro_tap", "Following steps are tapped: pressed and released."),
        ("&macro_press", "Following steps are pressed and held."),
        ("&macro_release", "Following steps are released."),
        ("&macro_wait_time 40", "Change the pause between the steps that follow."),
        ("&macro_tap_time 40", "Change how long the taps that follow are held."),
        ("&macro_pause_for_release", "Wait here until the key invoking the macro is let go."),
        ("&macro_param_1to1", "Pass the macro's first parameter into the next step."),
        ("&macro_param_2to1", "Pass the macro's second parameter into the next step."),
    ]

    private func append(_ text: String) {
        let parsed = BindingParser.parse(text)
        guard !parsed.isEmpty else { return }
        model.updateMacro(with { $0.bindings += parsed })
    }

    /// Replaces one step with what the user typed.
    ///
    /// Text that is not yet a binding is dropped rather than stored: a step is a
    /// `KeyBinding` and there is nowhere to keep a half-typed one. That is why
    /// the field is bound to `binding.text` — mid-edit it shows what was last
    /// parseable, and `MacroWriter.problems` is what says the sequence is wrong.
    private func setStep(_ step: Int, to text: String) {
        let parsed = BindingParser.parse(text)
        guard let binding = parsed.first, parsed.count == 1 else { return }
        model.updateMacro(with { $0.bindings[step] = binding })
    }

    /// A copy of the macro with one field changed. Written out as a literal
    /// closure at every call site for the reason `ComboEditorView.with` gives.
    private func with(_ assign: (inout KeymapMacro) -> Void) -> KeymapMacro {
        var edited = macro
        assign(&edited)
        return edited
    }
}
