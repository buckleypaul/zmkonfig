import Foundation

/// Every behavior this keymap can bind: the stock ZMK behaviors, the ones the
/// keymap defines for itself, and the ones nothing defines but something binds.
///
/// Built in one place from the parsed model, so the picker's list, the
/// keycap labels and the assistant's `list_behaviors` all answer from the same
/// table. `byCode` is what a drawn key looks a binding up in and `all` is what
/// the picker iterates, and both are stored because both are read on every
/// render.
public struct BehaviorIndex: Sendable {
    /// Keyed by bind token, `&kp`.
    public let byCode: [String: ZMKBehavior]
    /// The same behaviors, sorted by code, for a list the user reads.
    public let all: [ZMKBehavior]
    /// The codes that came from the vendored metadata rather than from this
    /// keymap. See ``isDocumented(_:)``.
    private let documented: Set<String>

    public static let empty = BehaviorIndex(stock: [], keymap: nil)

    /// - Parameters:
    ///   - stock: the vendored ZMK metadata.
    ///   - keymap: the open keymap, or nil before one is parsed.
    public init(stock: [ZMKBehavior], keymap: KeymapFile?) {
        var known = Dictionary(stock.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })

        // The keymap's own behaviors and macros, which metadata knows nothing
        // about. Stock wins a collision: a keymap that labels a node `kp` has
        // not redefined what `&kp` takes.
        for behavior in keymap?.definedBehaviors(stock: known) ?? [] where known[behavior.code] == nil {
            known[behavior.code] = behavior
        }

        // A binding may still reference something with no definition to find —
        // one declared in an include, or in a node the editor could not model.
        // Infer its shape from how it is used.
        let bound = (keymap?.layers.flatMap(\.bindings) ?? []) + (keymap?.combos.map(\.binding) ?? [])
        for binding in bound where known[binding.behavior] == nil {
            known[binding.behavior] = ZMKBehavior(
                code: binding.behavior,
                name: String(binding.behavior.drop(while: { $0 == "&" })),
                params: binding.params.map { _ in .code }
            )
        }

        byCode = known
        all = known.values
            .sorted { $0.code.localizedCaseInsensitiveCompare($1.code) == .orderedAscending }
        documented = Set(stock.map(\.code))
    }

    public func behavior(for code: String) -> ZMKBehavior? {
        byCode[code]
    }

    /// False for behaviors the keymap defines itself, whose parameter kinds we
    /// can only guess at.
    public func isDocumented(_ code: String) -> Bool {
        documented.contains(code)
    }
}
