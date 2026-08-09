import Foundation

extension KeymapFile {

    /// The behaviors this keymap defines for itself, as the editor's behavior
    /// metadata: `&hml`, `&qt`, `&email`.
    ///
    /// Read off ``behaviors`` and ``macros`` — the nodes `KeymapFile.init`
    /// already walked the tree for — rather than by walking it a second time
    /// with a second `compatible` predicate. The two answers used to be derived
    /// independently and could disagree about the same node.
    ///
    /// `stock` is the vendored metadata, keyed by code. It is what says that the
    /// `&mo` a hold-tap wraps takes a layer number: a wrapped behavior's first
    /// parameter kind is the kind of the slot that feeds it.
    public func definedBehaviors(stock: [String: ZMKBehavior]) -> [ZMKBehavior] {
        behaviors.map { behavior in
            ZMKBehavior(
                code: "&\(behavior.label)",
                name: displayName(of: behavior.nodeName),
                params: parameterKinds(of: behavior, stock: stock)
            )
        }
        + macros.map { macro in
            // A macro is not a behavior the behavior editor can configure —
            // `BehaviorReader` hands `zmk,behavior-macro*` nodes to
            // `MacroReader` and never reads one back as a behavior — so the
            // picker says which it is offering rather than listing the two side
            // by side as if they were the same thing.
            ZMKBehavior(
                code: "&\(macro.label)",
                name: "\(displayName(of: macro.nodeName)) (macro)",
                params: Array(repeating: ParamKind.code, count: macro.bindingCells)
            )
        }
    }

    private func displayName(of nodeName: String) -> String {
        nodeName.replacingOccurrences(of: "_", with: " ")
    }

    /// A hold-tap declares its arity as `#binding-cells` and what each slot
    /// means through the behaviors it wraps: `bindings = <&mo>, <&tog>` is two
    /// layer slots, `<&kp>, <&kp>` is two keycodes.
    private func parameterKinds(
        of behavior: KeymapBehavior, stock: [String: ZMKBehavior]
    ) -> [ParamKind] {
        var kinds = behavior.bindings.map { entry -> ParamKind in
            let code = entry.split(separator: " ").first.map(String.init) ?? entry
            return stock[code]?.params?.first ?? .code
        }
        kinds = Array(kinds.prefix(behavior.bindingCells))
        kinds.append(
            contentsOf: Array(repeating: .code, count: max(0, behavior.bindingCells - kinds.count))
        )
        return kinds
    }
}
