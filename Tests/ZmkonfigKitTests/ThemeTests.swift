import SwiftUI
import Testing

@testable import ZmkonfigKit

/// `ResolvedTheme.layerAccent(_:)` is the one place the "layer N gets accent
/// N % 14" rule is allowed to live — every view that colors something by
/// layer goes through it rather than doing its own modulo.
@Suite("Theme — layer accents")
struct ThemeTests {
    private var resolved: ResolvedTheme { Theme.standard.resolved(for: .light) }

    @Test("A layer's accent wraps at 14, forwards and backwards")
    func layerAccentWraps() {
        let theme = resolved
        #expect(theme.layerAccent(0) == theme.layerAccent(14))
        #expect(theme.layerAccent(1) == theme.layerAccent(15))
        #expect(theme.layerAccent(13) == theme.layerAccent(27))
        // A negative index cannot occur from a real layer id today, but the
        // helper still has to fold it into range rather than crash.
        #expect(theme.layerAccent(-1) == theme.layerAccent(13))
    }

    @Test("Adjacent layers get different accents")
    func adjacentLayersDiffer() {
        let theme = resolved
        for index in 0..<14 {
            #expect(theme.layerAccent(index) != theme.layerAccent(index + 1))
        }
    }

    @Test("Both flavours define all 14 accents by their published Catppuccin hex")
    func exactPublishedHexValues() {
        let latte: [ThemeColorToken: String] = [
            .layerAccent0: "#7287FD", .layerAccent1: "#FE640B", .layerAccent2: "#179299",
            .layerAccent3: "#8839EF", .layerAccent4: "#40A02B", .layerAccent5: "#04A5E5",
            .layerAccent6: "#EA76CB", .layerAccent7: "#DF8E1D", .layerAccent8: "#209FB5",
            .layerAccent9: "#E64553", .layerAccent10: "#D20F39", .layerAccent11: "#1E66F5",
            .layerAccent12: "#DD7878", .layerAccent13: "#DC8A78",
        ]
        let frappe: [ThemeColorToken: String] = [
            .layerAccent0: "#BABBF1", .layerAccent1: "#EF9F76", .layerAccent2: "#81C8BE",
            .layerAccent3: "#CA9EE6", .layerAccent4: "#A6D189", .layerAccent5: "#99D1DB",
            .layerAccent6: "#F4B8E4", .layerAccent7: "#E5C890", .layerAccent8: "#85C1DC",
            .layerAccent9: "#EA999C", .layerAccent10: "#E78284", .layerAccent11: "#8CAAEE",
            .layerAccent12: "#EEBEBE", .layerAccent13: "#F2D5CF",
        ]
        for (token, hex) in latte {
            #expect(Theme.standard.color(token, scheme: .light) == .hex(hex), "\(token)")
        }
        for (token, hex) in frappe {
            #expect(Theme.standard.color(token, scheme: .dark) == .hex(hex), "\(token)")
        }
    }
}
