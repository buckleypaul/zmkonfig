import Foundation

/// Everything a read-only feature needs to know about the open keymap, as one
/// value.
///
/// The assistant's tools used to take `AppModel` itself, which is why 1,700
/// lines of validation and prose sat in the app target and could not be tested.
/// They use nine read-only things from it, all of them `Sendable`, so the
/// snapshot is what they take instead: the app builds one per tool call, and
/// nothing here can reach the editor, the file on disk, or the main actor.
public struct KeymapContext: Sendable {
    /// The parsed keymap, or nil when no repository is open.
    public let keymap: KeymapFile?
    /// The vendored keycode table, for `find_keycodes`.
    public let keycodes: [ZMKKeycode]
    /// The physical key positions of the selected layout. Empty when no layout
    /// has loaded, which several tools have to allow for rather than assume.
    public let layout: [KeyPosition]
    public let behaviors: BehaviorIndex
    /// Whether the editor holds edits the `.keymap` on disk does not, which is
    /// what `read_keymap_source` warns about.
    public let hasUnsavedEdits: Bool
    /// The keymap's path relative to the repo root, for naming the file in an
    /// answer.
    public let keymapRelativePath: String?

    public init(
        keymap: KeymapFile? = nil,
        keycodes: [ZMKKeycode] = [],
        layout: [KeyPosition] = [],
        behaviors: BehaviorIndex = .empty,
        hasUnsavedEdits: Bool = false,
        keymapRelativePath: String? = nil
    ) {
        self.keymap = keymap
        self.keycodes = keycodes
        self.layout = layout
        self.behaviors = behaviors
        self.hasUnsavedEdits = hasUnsavedEdits
        self.keymapRelativePath = keymapRelativePath
    }

    public var layers: [KeymapLayer] { keymap?.layers ?? [] }

    public var combos: [KeymapCombo] { keymap?.combos ?? [] }

    public var availableBehaviors: [ZMKBehavior] { behaviors.all }

    public func isDocumentedBehavior(_ code: String) -> Bool {
        behaviors.isDocumented(code)
    }
}
