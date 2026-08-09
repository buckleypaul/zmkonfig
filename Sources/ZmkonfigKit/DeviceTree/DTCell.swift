import Foundation

extension DTCell {
    /// The integer one devicetree cell field holds, or nil when it is not a
    /// number at all — `POS_LH_T1` and every other preprocessor macro.
    ///
    /// Hex is part of the language, so `<0x1e>` is thirty and not nil. Combos,
    /// macros and behaviors each used to carry their own copy of this and two
    /// of them left the `0x` on the front, which read a perfectly ordinary
    /// `timeout-ms = <0x1e>;` as "no timeout".
    public static func integer(_ text: String) -> Int? {
        let field = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = field.hasPrefix("0x") || field.hasPrefix("0X")
        return Int(hex ? String(field.dropFirst(2)) : field, radix: hex ? 16 : 10)
    }
}
