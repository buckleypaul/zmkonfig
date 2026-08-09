import Foundation

/// The arithmetic of editing one binding: pulling a parameter apart into
/// modifiers and a base keycode, putting it back together, and reshaping a
/// binding when the behavior under it changes.
///
/// None of it is UI. It lived in `BindingFieldsView` and so could not be
/// tested, while it is the part that decides what `&hml LG(A) B` means and what
/// gets written back to the file.
public enum BindingAlgebra {

    /// `LG(LS(A))` → mods `["LG", "LS"]`, base `A`.
    ///
    /// What counts as a modifier is ``ModifierFunction/names``, the structural
    /// table, and never the glyph table.
    public static func decompose(_ param: BindingParam) -> (mods: [String], base: BindingParam) {
        var mods: [String] = []
        var current = param
        while current.params.count == 1, ModifierFunction.isModifier(current.value) {
            mods.append(current.value)
            current = current.params[0]
        }
        return (mods, current)
    }

    public static func compose(mods: [String], base: BindingParam) -> BindingParam {
        mods.reversed().reduce(base) { inner, mod in BindingParam(value: mod, params: [inner]) }
    }

    /// The modifier set with one family switched on or off: on means the
    /// left-hand modifier, off means neither hand's.
    public static func toggling(
        _ family: ModifierFunction.Family, in mods: [String]
    ) -> [String] {
        guard !mods.contains(family.left), !mods.contains(family.right) else {
            return mods.filter { $0 != family.left && $0 != family.right }
        }
        return mods + [family.left]
    }

    /// One slot per parameter the behavior declares.
    ///
    /// A behavior with nothing declared falls back to one keycode slot per
    /// parameter the binding carries. ``BehaviorIndex`` synthesizes an entry for
    /// every behavior a binding names, so the only gap left is a binding with
    /// more parameters than its behavior admits to — a custom behavior whose
    /// `#binding-cells` the parser could not read. Give it a slot each rather
    /// than nothing to edit.
    public static func slotKinds(
        for binding: KeyBinding, declaring behavior: ZMKBehavior?
    ) -> [ParamKind] {
        let declared = behavior?.params ?? []
        guard declared.isEmpty else { return declared }
        return binding.params.map { _ in .code }
    }

    /// Keeps whatever parameters still make sense when the behavior changes and
    /// fills the rest with something valid.
    public static func rebuild(
        _ binding: KeyBinding, as behavior: ZMKBehavior, layers: [KeymapLayer]
    ) -> KeyBinding {
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

    public static func defaultValue(
        for kind: ParamKind, behavior: ZMKBehavior, layers: [KeymapLayer]
    ) -> String {
        switch kind {
        case .layer: String(layers.first?.id ?? 0)
        case .command: behavior.commands?.first?.code ?? ""
        case .mod: "LEFT_SHIFT"
        case .code: "A"
        }
    }

    /// What one slot is called in the editor.
    public static func slotTitle(kind: ParamKind, slot: Int) -> String {
        switch kind {
        case .layer: "Layer"
        case .command: "Command"
        case .mod: "Modifier"
        case .code: slot == 0 ? "Keycode" : "Keycode \(slot + 1)"
        }
    }
}
