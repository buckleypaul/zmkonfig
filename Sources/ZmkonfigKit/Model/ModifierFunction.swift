import Foundation

/// The modifier functions that wrap another keycode — `LG(LS(A))`.
///
/// Two tables, deliberately. ``names`` is the *structural* one: it decides what
/// counts as a modifier wrapper, and so what ``BindingAlgebra/decompose(_:)``
/// peels off and what ``BindingAlgebra/compose(mods:base:)`` puts back. ``glyph(for:)``
/// is the *display* one and is only ever read to draw something.
///
/// They used to be one dictionary, which meant adding a glyph silently changed
/// how bindings parse and how they are recomposed on save — a display change
/// rewriting the file. A token may gain a glyph without becoming a wrapper, and
/// a wrapper with no glyph falls back to its own spelling rather than being
/// treated as an ordinary keycode.
public enum ModifierFunction {

    /// Every spelling ZMK accepts for a modifier function, short and long.
    public static let names: Set<String> = [
        "LG", "LGUI", "RG", "RGUI",
        "LS", "LSHFT", "RS", "RSHFT",
        "LA", "LALT", "RA", "RALT",
        "LC", "LCTL", "RC", "RCTL",
    ]

    public static func isModifier(_ token: String) -> Bool {
        names.contains(token)
    }

    /// What to draw for a modifier function. A wrapper with no glyph of its own
    /// shows its spelling, which is still true and still readable.
    public static func glyph(for token: String) -> String {
        glyphs[token] ?? token
    }

    private static let glyphs: [String: String] = [
        "LG": "⌘", "LGUI": "⌘", "RG": "⌘", "RGUI": "⌘",
        "LS": "⇧", "LSHFT": "⇧", "RS": "⇧", "RSHFT": "⇧",
        "LA": "⌥", "LALT": "⌥", "RA": "⌥", "RALT": "⌥",
        "LC": "⌃", "LCTL": "⌃", "RC": "⌃", "RCTL": "⌃",
    ]

    /// One row of modifier buttons: the left-hand function, its right-hand
    /// twin, and how to label the pair. Toggling adds the left one, which is
    /// what a keyboard's home-row mods almost always mean.
    public struct Family: Sendable, Equatable, Identifiable {
        public let left: String
        public let right: String
        public let symbol: String
        public let name: String

        public var id: String { left }
    }

    public static let families: [Family] = [
        Family(left: "LC", right: "RC", symbol: "⌃", name: "Control"),
        Family(left: "LA", right: "RA", symbol: "⌥", name: "Option"),
        Family(left: "LS", right: "RS", symbol: "⇧", name: "Shift"),
        Family(left: "LG", right: "RG", symbol: "⌘", name: "Command"),
    ]
}
