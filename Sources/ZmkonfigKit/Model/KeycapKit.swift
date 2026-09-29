import Foundation

/// Which of the two keycap "kits" a binding belongs to.
///
/// A keyset ships its alphas in one colour and its modifiers, navigation
/// cluster, editing and thumb keys in another — the mods kit. The board draws
/// the same distinction, so it has to be decided from what a binding *is* and
/// never from where it sits: one layout is drawn for every layer, and the
/// position holding `Q` on the base layer holds `←` on the next one.
///
/// The rule is deliberately one-sided. What counts as an alpha can be written
/// down in full — the letters, the digits and the printable punctuation a plain
/// `&kp` types — so everything else is a mod: every non-`&kp` behavior (`&mo`,
/// `&lt`, `&mt`, `&tog`, a keymap-defined hold-tap), every modifier keycode,
/// the navigation cluster, the editing keys, the function row, the keypad,
/// media, and any keycode this app has never heard of. Guessing wrong about an
/// unknown token that way costs a shade of grey; guessing the other way would
/// put half a nav layer in the alpha colour.
public enum KeycapKit: Sendable {
    case alpha
    case mods

    public static func of(_ binding: KeyBinding) -> KeycapKit {
        // Anything other than a plain key press is a layer tap, a hold-tap, a
        // toggle, a bluetooth command — never an alpha.
        guard binding.behavior == "&kp", binding.params.count == 1 else { return .mods }
        let param = binding.params[0]
        // `LC(C)` is a shortcut you reach for with two hands, not a letter.
        guard param.params.isEmpty else { return .mods }
        return of(keycode: param.value)
    }

    /// The keycode half of the rule, kept separate so the test can name the
    /// tokens rather than wrap each one in a `&kp`.
    static func of(keycode token: String) -> KeycapKit {
        if token.count == 1, token.first?.isLetter == true || token.first?.isNumber == true {
            return .alpha
        }
        // `N1`…`N0` and `NUMBER_1`… are digits with a prefix on.
        if token.count == 2, token.hasPrefix("N"), token.last?.isNumber == true { return .alpha }
        if token.hasPrefix("NUMBER_"), token.dropFirst("NUMBER_".count).count == 1,
           token.last?.isNumber == true {
            return .alpha
        }
        return alphaPunctuation.contains(token) ? .alpha : .mods
    }

    /// Every ZMK spelling of a character that prints, in both the short and the
    /// long form. Written out rather than derived from
    /// ``BindingLabel/keycodeSymbols``: that table is what a keycap *says*, and
    /// letting a display table decide structure is the exact drift
    /// ``ModifierFunction`` was split in two to prevent.
    static let alphaPunctuation: Set<String> = [
        "MINUS", "EQUAL", "PLUS", "UNDER", "UNDERSCORE",
        "LBKT", "LEFT_BRACKET", "RBKT", "RIGHT_BRACKET",
        "LBRC", "LEFT_BRACE", "RBRC", "RIGHT_BRACE",
        "LPAR", "LEFT_PARENTHESIS", "RPAR", "RIGHT_PARENTHESIS",
        "LT", "LESS_THAN", "GT", "GREATER_THAN",
        "BSLH", "BACKSLASH", "PIPE", "PIPE2",
        "FSLH", "SLASH", "QMARK", "QUESTION",
        "SEMI", "SEMICOLON", "COLON",
        "SQT", "APOS", "SINGLE_QUOTE", "APOSTROPHE",
        "DQT", "DOUBLE_QUOTES",
        "GRAVE", "TILDE", "TILDE2",
        "COMMA", "DOT", "PERIOD",
        "EXCL", "EXCLAMATION", "AT", "AT_SIGN",
        "HASH", "POUND", "DLLR", "DOLLAR",
        "PRCNT", "PERCENT", "CARET",
        "AMPS", "AMPERSAND",
        "STAR", "ASTRK", "ASTERISK",
    ]

    /// Behaviors whose first parameter names a layer to switch to: momentary,
    /// layer-tap, toggle, sticky layer and "go to layer".
    ///
    /// This is the single source for that list, and ``layerTarget(of:)`` the
    /// single way to read the number off one — the board colors a key by it and
    /// ``KeymapFile`` warns about the bindings a renumbering would break by it,
    /// so a behavior missing from one and present in the other would mean the
    /// two disagreed about what a layer switch is.
    ///
    /// Fixed by code rather than read off `ZMKBehavior.params` /
    /// `ParamKind.layer`: the vendored `zmk-behaviors.json` does not carry
    /// `&to` today, so a lookup through it would silently drop that one
    /// behavior rather than color it. This list is what stays true regardless
    /// of that gap.
    private static let layerSwitchingBehaviors: Set<String> = ["&mo", "&lt", "&tog", "&sl", "&to"]

    /// Whether this binding switches the board to a different layer.
    static func isLayerSwitch(_ binding: KeyBinding) -> Bool {
        layerSwitchingBehaviors.contains(binding.behavior)
    }

    /// The layer id this binding switches to — every layer-switching
    /// behavior's first parameter — or nil when the binding does not target a
    /// layer at all, or that parameter is not a literal number (a `#define`d
    /// layer name this editor cannot resolve).
    ///
    /// A layer number never carries parameters of its own, so `&mo FOO(1)` is
    /// something this editor does not understand rather than a switch to layer
    /// 1 — and reporting it as one would put a renumbering warning against a
    /// binding nothing here can renumber.
    public static func layerTarget(of binding: KeyBinding) -> Int? {
        guard isLayerSwitch(binding), let first = binding.params.first, first.params.isEmpty
        else { return nil }
        return Int(first.value)
    }
}
