import Foundation

/// Says a `KeyBinding` out loud: `&mt LSHFT A` becomes "Hold for Left Shift,
/// tap for A."
///
/// The sibling of ``BindingLabel``, and deliberately separate from it. A keycap
/// has room for a glyph and a tooltip has room for a sentence, so `⇧A` and
/// "Hold for Left Shift, tap for A" are two different renderings of the same
/// binding rather than one of them being a truncation of the other.
///
/// Wholly deterministic and offline: this is the explanation a user with no
/// Anthropic key still gets, which is why the phrasing lives in the vendored
/// glossary rather than in a prompt.
public enum BindingNarrator {

    /// A plain-English sentence for a binding, or nil when the glossary has
    /// nothing to say about the behavior.
    ///
    /// Nil rather than a generated fallback, because the callers are all
    /// deciding whether to show a sentence at all — a keymap's own `&hml` has
    /// no narration to give, and "hml LEFT_GUI A" dressed up as prose would be
    /// worse than the binding text it replaced.
    public static func sentence(
        for binding: KeyBinding,
        behavior: ZMKBehavior?,
        layers: [KeymapLayer],
        glossary: Glossary
    ) -> String? {
        guard let template = glossary.entry(for: binding.behavior)?.narration else { return nil }
        let kinds = BindingAlgebra.slotKinds(for: binding, declaring: behavior)
        let rendered = binding.params.enumerated().map { slot, param in
            spoken(param, kind: slot < kinds.count ? kinds[slot] : .code, behavior: behavior, layers: layers)
        }
        return fill(template, with: rendered)
    }

    /// The same sentence for a binding on a specific key, prefixed with what
    /// the key is — what a hover over a keycap wants.
    public static func keyDescription(
        for binding: KeyBinding,
        behavior: ZMKBehavior?,
        layers: [KeymapLayer],
        glossary: Glossary
    ) -> String {
        guard let sentence = sentence(for: binding, behavior: behavior, layers: layers, glossary: glossary)
        else { return binding.text }
        // The binding text stays on a second line: the sentence is for reading
        // and the text is what the user needs when they go looking in the file.
        return "\(sentence)\n\(binding.text)"
    }

    // MARK: - Template filling

    /// Substitutes `{0}`, `{1}` … for the rendered parameters.
    ///
    /// A placeholder with no parameter behind it is dropped rather than left as
    /// itself: a half-written `&mt` with one slot filled should read as an
    /// unfinished sentence, not leak `{1}` into the UI.
    private static func fill(_ template: String, with values: [String]) -> String {
        var result = template
        // Descending, so `{10}` is not eaten by the replacement for `{1}`.
        for index in stride(from: max(values.count, placeholderCeiling) - 1, through: 0, by: -1) {
            let value = index < values.count ? values[index] : ""
            result = result.replacingOccurrences(of: "{\(index)}", with: value)
        }
        return result
    }

    /// No behavior in ZMK takes more parameters than this, so a template can
    /// never reference a placeholder above it. Filling up to this bound is what
    /// clears the placeholders that have no parameter behind them.
    private static let placeholderCeiling = 4

    // MARK: - Parameter rendering

    private static func spoken(
        _ param: BindingParam,
        kind: ParamKind,
        behavior: ZMKBehavior?,
        layers: [KeymapLayer]
    ) -> String {
        switch kind {
        case .layer:
            return BindingLabel.layerLabel(param, layers: layers)
        case .command:
            return spokenCommand(param, behavior: behavior)
        case .code, .mod:
            return spokenKeycode(param)
        }
    }

    /// A command said as its own documentation says it, `BT_CLR` as "Clear bond
    /// information …".
    ///
    /// Only the first sentence: the vendored descriptions run to two or three,
    /// and the tail is usually a caveat about arguments that the inspector's
    /// own caption already shows in full.
    private static func spokenCommand(_ param: BindingParam, behavior: ZMKBehavior?) -> String {
        guard let description = behavior?.commands?.first(where: { $0.code == param.value })?.description
        else { return BindingLabel.commandLabel(param) }
        return firstSentence(of: description)
    }

    private static func firstSentence(of text: String) -> String {
        guard let stop = text.firstIndex(of: ".") else { return text }
        return String(text[..<text.index(after: stop)])
    }

    /// `LEFT_SHIFT` as "Left Shift", `LG(LS(A))` as "Command + Shift + A".
    ///
    /// Words, not the glyphs ``BindingLabel`` draws. Someone reading this
    /// sentence is the person who did not recognise ⇧ on the keycap.
    public static func spokenKeycode(_ param: BindingParam) -> String {
        if param.params.count == 1, ModifierFunction.isModifier(param.value) {
            return "\(modifierName(param.value)) + \(spokenKeycode(param.params[0]))"
        }
        if !param.params.isEmpty {
            let inner = param.params.map { spokenKeycode($0) }.joined(separator: ", ")
            return "\(name(of: param.value))(\(inner))"
        }
        return name(of: param.value)
    }

    /// The left hand is unqualified — "Command", not "Left Command" — because a
    /// modifier function almost always wraps the left one and saying so every
    /// time is noise. The right one is worth calling out precisely because it
    /// is the unusual choice.
    private static func modifierName(_ token: String) -> String {
        guard let (family, isRight) = ModifierFunction.family(for: token) else { return token }
        return isRight ? "Right \(family.name)" : family.name
    }

    /// Falls back to ``BindingLabel/prettyKeycode(_:)``, which already turns
    /// `N1` into `1` and `LEFT_ARROW` into an arrow. Only the tokens whose
    /// pretty form is a symbol rather than a word need saying differently here.
    private static func name(of raw: String) -> String {
        spokenNames[raw] ?? BindingLabel.prettyKeycode(raw)
    }

    /// The keycodes whose glyph is not a word. Anything not here reads well
    /// enough as ``BindingLabel/prettyKeycode(_:)`` renders it.
    static let spokenNames: [String: String] = [
        "LEFT_GUI": "Left Command", "LGUI": "Left Command", "LCMD": "Left Command",
        "LWIN": "Left Windows",
        "RIGHT_GUI": "Right Command", "RGUI": "Right Command", "RCMD": "Right Command",
        "RWIN": "Right Windows",
        "LEFT_SHIFT": "Left Shift", "LSHFT": "Left Shift", "LSHIFT": "Left Shift",
        "RIGHT_SHIFT": "Right Shift", "RSHFT": "Right Shift", "RSHIFT": "Right Shift",
        "LEFT_ALT": "Left Option", "LALT": "Left Option",
        "RIGHT_ALT": "Right Option", "RALT": "Right Option",
        "LEFT_CONTROL": "Left Control", "LCTRL": "Left Control", "LCTL": "Left Control",
        "RIGHT_CONTROL": "Right Control", "RCTRL": "Right Control", "RCTL": "Right Control",

        "SPACE": "Space", "TAB": "Tab",
        "RET": "Enter", "RETURN": "Enter", "ENTER": "Enter",
        "ESC": "Escape", "ESCAPE": "Escape",
        "BSPC": "Backspace", "BACKSPACE": "Backspace",
        "DEL": "Delete", "DELETE": "Delete",
        "CAPS": "Caps Lock", "CAPSLOCK": "Caps Lock", "CAPS_WORD": "Caps Word",

        "LEFT": "Left", "LEFT_ARROW": "Left", "RIGHT": "Right", "RIGHT_ARROW": "Right",
        "UP": "Up", "UP_ARROW": "Up", "DOWN": "Down", "DOWN_ARROW": "Down",
        "HOME": "Home", "END": "End",
        "PG_UP": "Page Up", "PAGE_UP": "Page Up", "PG_DN": "Page Down", "PAGE_DOWN": "Page Down",

        "MINUS": "minus", "EQUAL": "equals", "PLUS": "plus",
        "UNDER": "underscore", "UNDERSCORE": "underscore",
        "LBKT": "[", "RBKT": "]", "LBRC": "{", "RBRC": "}",
        "LPAR": "(", "RPAR": ")",
        "BSLH": "backslash", "BACKSLASH": "backslash", "PIPE": "pipe",
        "FSLH": "slash", "SLASH": "slash",
        "SEMI": "semicolon", "SEMICOLON": "semicolon", "COLON": "colon",
        "SQT": "apostrophe", "APOS": "apostrophe", "SINGLE_QUOTE": "apostrophe",
        "DQT": "double quote", "DOUBLE_QUOTES": "double quote",
        "GRAVE": "backtick", "TILDE": "tilde",
        "COMMA": "comma", "DOT": "full stop", "PERIOD": "full stop",

        "C_MUTE": "Mute", "C_VOL_UP": "Volume Up", "C_VOLUME_UP": "Volume Up",
        "C_VOL_DN": "Volume Down", "C_VOLUME_DOWN": "Volume Down",
        "C_PP": "Play/Pause", "C_PLAY_PAUSE": "Play/Pause",
        "C_NEXT": "Next Track", "C_PREV": "Previous Track",
        "C_BRI_UP": "Brightness Up", "C_BRI_DN": "Brightness Down",
        "PSCRN": "Print Screen", "PRINTSCREEN": "Print Screen",
    ]
}
