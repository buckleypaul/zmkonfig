import Foundation

/// What kind of control a behavior property wants, and what to put in it when
/// the node does not have it yet.
///
/// ``BehaviorKind/requiredProperties`` and ``BehaviorKind/optionalProperties``
/// say *which* properties a kind may set; they do not say what a value of one
/// looks like. An editor offering `retro-tap` has to know it is a bare flag and
/// not a number before there is a value to read the shape off, so the knowledge
/// has to be written down somewhere — and it is ZMK's, not a view's.
///
/// A property already in the file is read from its ``BehaviorValue`` instead
/// wherever the two could disagree; see ``shape(of:value:)``. The table only
/// decides what an unset property is offered as.
public enum BehaviorPropertyShape: Sendable, Equatable {
    /// `tapping-term-ms = <200>;`. The associated value is what to write when
    /// the property is first switched on — ZMK's own default where upstream
    /// states one, so turning it on and off again is a no-op in the diff.
    case integer(initial: Int)
    /// A bare `retro-tap;`. Devicetree has no `= false`: the property is either
    /// written or absent, which is why this is a checkbox and not a toggle over
    /// two values.
    case choiceless
    /// `flavor = "balanced";` — one of a fixed set of strings.
    case choice(options: [String], initial: String)
    /// A cell of preprocessor tokens, `mods = <(MOD_LSFT|MOD_RSFT)>`. Kept as
    /// text because the editor cannot resolve `MOD_LSFT` and must not pretend
    /// to: see ``BehaviorValue/tokens(_:)``.
    ///
    /// `hint` is both the placeholder and the value the property starts at, so
    /// switching `continue-list` on gives a caps-word that already works rather
    /// than one the user has to be told is wrong.
    case tokens(hint: String)
    /// A cell of plain numbers, `hold-trigger-key-positions = <0 1 2>`.
    case numbers

    /// The shape for a property that is not on the node yet.
    ///
    /// Unknown names fall back to ``tokens(hint:)`` rather than to a number: a
    /// free text cell can express every value the other cases can, so guessing
    /// wrong there costs the user a retype rather than a value they cannot
    /// enter at all.
    public static func shape(of name: String) -> BehaviorPropertyShape {
        if let known = table[name] { return known }
        // Every duration ZMK defines is spelled this way, including the ones
        // added after this table was written.
        if name.hasSuffix("-ms") { return .integer(initial: 100) }
        return .tokens(hint: "0")
    }

    /// The shape for a property the node already has.
    ///
    /// The value wins over the table wherever the two disagree, because the
    /// value is what the file actually says. A keymap that writes
    /// `tapping-term-ms = <TAPPING_TERM>` — a `#define` — parsed as
    /// ``BehaviorValue/tokens(_:)``, and offering it as a number field would
    /// mean the only way to keep the macro is not to touch the field.
    public static func shape(of name: String, value: BehaviorValue) -> BehaviorPropertyShape {
        switch value {
        case .flag:
            return .choiceless
        case .integer(let number):
            // `flavor` is never an integer, so a table entry that says `choice`
            // cannot be right about a value that is one.
            if case .integer = shape(of: name) { return shape(of: name) }
            return .integer(initial: number)
        case .string:
            if case .choice = shape(of: name) { return shape(of: name) }
            return .tokens(hint: "text")
        case .integers:
            return .numbers
        case .tokens, .references:
            let hint = if case .tokens(let known) = shape(of: name) { known } else { "0" }
            return .tokens(hint: hint)
        }
    }

    /// The value to write when a property is first switched on.
    public var initialValue: BehaviorValue {
        switch self {
        case .integer(let initial): .integer(initial)
        case .choiceless: .flag
        case .choice(_, let initial): .string(initial)
        // Never `.tokens([])` or `.integers([])`: both render as `<>`, which
        // devicetree rejects and ``BehaviorWriter/problems(with:)`` refuses, so
        // a property switched on would be unwritable the moment it was added.
        case .tokens(let hint): .tokens(Self.fields(of: hint))
        case .numbers: .integers([0])
        }
    }

    private static func fields(of hint: String) -> [String] {
        let fields = hint.split(whereSeparator: \.isWhitespace).map(String.init)
        return fields.isEmpty ? ["0"] : fields
    }

    /// ZMK's flavors, in the order the documentation lists them.
    public static let flavors = ["tap-preferred", "balanced", "hold-preferred", "tap-unless-interrupted"]

    /// The properties ``BehaviorKind`` offers, with the defaults ZMK documents.
    ///
    /// Only properties one of the kinds actually names are here; anything else
    /// a file happens to carry is read off its own value.
    private static let table: [String: BehaviorPropertyShape] = [
        "tapping-term-ms": .integer(initial: 200),
        "quick-tap-ms": .integer(initial: 175),
        "require-prior-idle-ms": .integer(initial: 125),
        "release-after-ms": .integer(initial: 1000),
        "hold-while-undecided-linger": .choiceless,
        "hold-while-undecided": .choiceless,
        "hold-trigger-on-release": .choiceless,
        "retro-tap": .choiceless,
        "quick-release": .choiceless,
        "lazy": .choiceless,
        "ignore-modifiers": .choiceless,
        "flavor": .choice(options: flavors, initial: "balanced"),
        "hold-trigger-key-positions": .numbers,
        "mods": .tokens(hint: "(MOD_LSFT|MOD_RSFT)"),
        "keep-mods": .tokens(hint: "(MOD_LSFT|MOD_RSFT)"),
        "continue-list": .tokens(hint: "UNDERSCORE BACKSPACE"),
        "usage-pages": .tokens(hint: "HID_USAGE_KEY"),
    ]
}
