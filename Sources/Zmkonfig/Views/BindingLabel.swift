import Foundation
import ZmkonfigKit

/// Turns a `KeyBinding` into the one or two short strings a keycap can show.
///
/// The tap value is the big label; the hold value (a mod, a layer, the behavior
/// itself) is the small one above it — the same convention the web editor uses.
enum BindingLabel {
    struct Label: Equatable {
        var tap: String
        var hold: String?
        var kind: Kind

        enum Kind: Equatable { case normal, transparent, unbound }
    }

    static func make(_ binding: KeyBinding, behavior: ZMKBehavior?, layers: [KeymapLayer]) -> Label {
        switch binding.behavior {
        case "&trans": return Label(tap: "▽", hold: nil, kind: .transparent)
        case "&none": return Label(tap: "✕", hold: nil, kind: .unbound)
        default: break
        }

        let name = behaviorName(binding.behavior)
        let values = binding.params
        guard !values.isEmpty else {
            return Label(tap: name, hold: nil, kind: .normal)
        }

        let kinds = behavior?.params ?? []

        if kinds.count == values.count {
            if values.count == 2 {
                return Label(
                    tap: render(kinds[1], values[1], layers: layers),
                    hold: render(kinds[0], values[0], layers: layers),
                    kind: .normal
                )
            }
            if values.count == 1 {
                // For a plain key press the behavior name is noise; for
                // anything else it is the whole meaning of the key.
                return Label(
                    tap: render(kinds[0], values[0], layers: layers),
                    hold: binding.behavior == "&kp" ? nil : name,
                    kind: .normal
                )
            }
        }

        // Unknown arity (custom hold-taps, `&bt BT_SEL 0`, …). Two params reads
        // as hold/tap, which is what every custom hold-tap actually is.
        if kinds.isEmpty, values.count == 2 {
            return Label(
                tap: render(.code, values[1], layers: layers),
                hold: render(.code, values[0], layers: layers),
                kind: .normal
            )
        }

        let head = render(kinds.first ?? .code, values[0], layers: layers)
        let rest = values.dropFirst().map { render(.code, $0, layers: layers) }
        return Label(tap: ([head] + rest).joined(separator: " "), hold: name, kind: .normal)
    }

    // MARK: - Parameter rendering

    private static func render(_ kind: ParamKind, _ param: BindingParam, layers: [KeymapLayer]) -> String {
        switch kind {
        case .layer: layerLabel(param, layers: layers)
        case .command: commandLabel(param)
        case .code, .mod: keycodeLabel(param)
        }
    }

    /// Drops the first of `prefixes` the token starts with, and only the first.
    ///
    /// The three call sites below used to spell this out themselves and had
    /// already drifted apart — one looped on, one broke out, and one hardcoded
    /// the lengths beside the literals it was meant to match.
    private static func stripping(_ prefixes: [String], from token: String) -> String {
        guard let prefix = prefixes.first(where: token.hasPrefix) else { return token }
        return String(token.dropFirst(prefix.count))
    }

    static func layerLabel(_ param: BindingParam, layers: [KeymapLayer]) -> String {
        if let index = Int(param.value), let layer = layers.first(where: { $0.id == index }) {
            return layer.displayName
        }
        if let index = Int(param.value) { return "L\(index)" }
        // A `#define LAYER_NAV 1` style token.
        let token = stripping(["LAYER_", "L_"], from: param.value)
        return token.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func commandLabel(_ param: BindingParam) -> String {
        let token = stripping(["BT_", "OUT_", "RGB_", "EP_", "EXT_POWER_"], from: param.value)
        let inner = param.params.map { commandLabel($0) }.joined(separator: " ")
        let head = token.replacingOccurrences(of: "_", with: " ")
        return inner.isEmpty ? head : "\(head) \(inner)"
    }

    /// `LG(LS(SPACE))` → `⌘⇧␣`, `N1` → `1`, `LEFT_ARROW` → `←`.
    static func keycodeLabel(_ param: BindingParam) -> String {
        if param.params.count == 1, let symbol = modifierSymbols[param.value] {
            return symbol + keycodeLabel(param.params[0])
        }
        if !param.params.isEmpty {
            let inner = param.params.map { keycodeLabel($0) }.joined(separator: ",")
            return "\(prettyKeycode(param.value))(\(inner))"
        }
        return prettyKeycode(param.value)
    }

    static func prettyKeycode(_ raw: String) -> String {
        if let known = keycodeSymbols[raw] { return known }
        if raw.count == 1 { return raw }
        // N1…N0 and NUMBER_1… are just digits.
        if raw.count == 2, raw.hasPrefix("N"), let digit = raw.last, digit.isNumber {
            return String(digit)
        }
        if raw.hasPrefix("NUMBER_") { return String(raw.dropFirst("NUMBER_".count)) }
        if raw.hasPrefix("KP_") {
            return "KP " + stripping(["KP_"], from: raw).replacingOccurrences(of: "_", with: " ")
        }
        return stripping(["C_", "K_"], from: raw).replacingOccurrences(of: "_", with: " ")
    }

    private static func behaviorName(_ code: String) -> String {
        (code.hasPrefix("&") ? String(code.dropFirst()) : code).uppercased()
    }

    /// Modifier functions that wrap another keycode, and the glyph to show.
    static let modifierSymbols: [String: String] = [
        "LG": "⌘", "LGUI": "⌘", "RG": "⌘", "RGUI": "⌘",
        "LS": "⇧", "LSHFT": "⇧", "RS": "⇧", "RSHFT": "⇧",
        "LA": "⌥", "LALT": "⌥", "RA": "⌥", "RALT": "⌥",
        "LC": "⌃", "LCTL": "⌃", "RC": "⌃", "RCTL": "⌃",
    ]

    static let keycodeSymbols: [String: String] = [
        // Modifiers as standalone keys
        "LEFT_GUI": "⌘", "LGUI": "⌘", "LCMD": "⌘", "LWIN": "⌘",
        "RIGHT_GUI": "⌘", "RGUI": "⌘", "RCMD": "⌘", "RWIN": "⌘",
        "LEFT_SHIFT": "⇧", "LSHFT": "⇧", "LSHIFT": "⇧",
        "RIGHT_SHIFT": "⇧", "RSHFT": "⇧", "RSHIFT": "⇧",
        "LEFT_ALT": "⌥", "LALT": "⌥", "RIGHT_ALT": "⌥", "RALT": "⌥",
        "LEFT_CONTROL": "⌃", "LCTRL": "⌃", "LCTL": "⌃",
        "RIGHT_CONTROL": "⌃", "RCTRL": "⌃", "RCTL": "⌃",

        // Whitespace and editing
        "SPACE": "␣", "TAB": "⇥", "RET": "⏎", "RETURN": "⏎", "ENTER": "⏎",
        "ESC": "⎋", "ESCAPE": "⎋",
        "BSPC": "⌫", "BACKSPACE": "⌫", "DEL": "⌦", "DELETE": "⌦",
        "CAPS": "⇪", "CAPSLOCK": "⇪", "CAPS_WORD": "⇪W",

        // Navigation
        "LEFT": "←", "LEFT_ARROW": "←", "RIGHT": "→", "RIGHT_ARROW": "→",
        "UP": "↑", "UP_ARROW": "↑", "DOWN": "↓", "DOWN_ARROW": "↓",
        "HOME": "↖", "END": "↘", "PG_UP": "⇞", "PAGE_UP": "⇞",
        "PG_DN": "⇟", "PAGE_DOWN": "⇟", "INS": "INS", "INSERT": "INS",

        // Punctuation, both the short and long ZMK spellings
        "MINUS": "-", "EQUAL": "=", "PLUS": "+", "UNDER": "_", "UNDERSCORE": "_",
        "LBKT": "[", "LEFT_BRACKET": "[", "RBKT": "]", "RIGHT_BRACKET": "]",
        "LBRC": "{", "LEFT_BRACE": "{", "RBRC": "}", "RIGHT_BRACE": "}",
        "LPAR": "(", "LEFT_PARENTHESIS": "(", "RPAR": ")", "RIGHT_PARENTHESIS": ")",
        "LT": "<", "LESS_THAN": "<", "GT": ">", "GREATER_THAN": ">",
        "BSLH": "\\", "BACKSLASH": "\\", "PIPE": "|", "PIPE2": "|",
        "FSLH": "/", "SLASH": "/", "QMARK": "?", "QUESTION": "?",
        "SEMI": ";", "SEMICOLON": ";", "COLON": ":",
        "SQT": "'", "APOS": "'", "SINGLE_QUOTE": "'", "APOSTROPHE": "'",
        "DQT": "\"", "DOUBLE_QUOTES": "\"",
        "GRAVE": "`", "TILDE": "~", "TILDE2": "~",
        "COMMA": ",", "DOT": ".", "PERIOD": ".",
        "EXCL": "!", "EXCLAMATION": "!", "AT": "@", "AT_SIGN": "@",
        "HASH": "#", "POUND": "#", "DLLR": "$", "DOLLAR": "$",
        "PRCNT": "%", "PERCENT": "%", "CARET": "^",
        "AMPS": "&", "AMPERSAND": "&",
        "STAR": "*", "ASTRK": "*", "ASTERISK": "*",

        // Media
        "C_MUTE": "🔇", "C_VOL_UP": "🔊+", "C_VOLUME_UP": "🔊+",
        "C_VOL_DN": "🔊-", "C_VOLUME_DOWN": "🔊-",
        "C_PP": "⏯", "C_PLAY_PAUSE": "⏯", "C_NEXT": "⏭", "C_PREV": "⏮",
        "C_BRI_UP": "☀+", "C_BRI_DN": "☀-",
        "PSCRN": "PRTSC", "PRINTSCREEN": "PRTSC",
    ]
}
