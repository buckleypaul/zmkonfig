import AppKit
import SwiftUI

// MARK: - Tokens

/// Every color the UI is allowed to use. Views never name a literal color;
/// they name a token and the theme decides what it looks like.
public enum ThemeColorToken: String, CaseIterable, Sendable {
    case windowBackground
    case sidebarBackground
    case panelBackground
    case contentBackground
    case boardBackground

    case border
    case separator

    case primaryText
    case secondaryText
    case tertiaryText

    case accent
    case accentSoft

    /// The top face of an alpha cap.
    case keycapFill
    /// The top face of a modifier, navigation or thumb key — the mods kit.
    case keycapModFill
    /// The extruded side wall a cap's top face sits on. Darker than either top
    /// face in both flavours: it is the whole of the cap's edge.
    case keycapSide
    /// The one shadow in the app, cast by a cap onto the plate. Carries its own
    /// alpha, so it is written as an eight-digit hex.
    case keycapShadow
    case keycapStroke
    case keycapText
    case keycapSubtext
    case keycapEmptyFill
    case keycapEmptyText
    case keycapSelectedFill
    /// The halo under the selected cap. Only the board ever lights up.
    case underglow
    /// The halo under a cap the rest of the UI is pointing at — a combo's key
    /// positions, while the combo is being edited.
    case keycapHighlight

    /// Catppuccin's 14-accent rainbow, used only for layer identity: layer `N`
    /// draws in `layerAccent(N % 14)`. Nowhere else in the app assigns meaning
    /// by picking one of these on its own — read them through
    /// ``ResolvedTheme/layerAccent(_:)`` so the index math lives in one place.
    case layerAccent0
    case layerAccent1
    case layerAccent2
    case layerAccent3
    case layerAccent4
    case layerAccent5
    case layerAccent6
    case layerAccent7
    case layerAccent8
    case layerAccent9
    case layerAccent10
    case layerAccent11
    case layerAccent12
    case layerAccent13

    case success
    case warning
    case danger

    case diffAddText
    case diffAddBackground
    case diffRemoveText
    case diffRemoveBackground
    case diffMeta

    case badgeBackground
    case badgeText
}

/// Sizes, spacings and radii. `keyUnit` is the on-screen size of one keyboard
/// unit (1u) before the board is scaled to fit.
public enum ThemeMetricToken: String, CaseIterable, Sendable {
    case keyUnit
    case keyInset
    case keyCornerRadius
    /// How far the top face of a cap is inset from its side wall — the width of
    /// the reveal down the left and right edges.
    case keycapTopInset
    /// How far the top face is lifted above centre. It is what makes the
    /// bottom reveal deeper than the top one, which is what reads as height
    /// rather than as a frame.
    case keycapTopShift
    case keycapShadowRadius
    case keycapShadowYOffset
    /// How far a selected cap's halo bleeds out from under it.
    case underglowBlur

    case cornerRadiusSmall
    case cornerRadiusMedium
    /// The radius of a pane card — the sidebar, the content pane, the
    /// inspector — and of anything else the size of a whole panel.
    case cornerRadiusLarge

    case borderWidth

    case spacingXS
    case spacingS
    case spacingM
    case spacingL

    /// The gap of bare window background left between two pane cards, and
    /// between a card and the window edge. This is what makes the panes read
    /// as separate objects, so it is never zero.
    case paneGutter
    /// The inset from a pane card's edge to its content.
    case panePadding


    case sidebarMinWidth
    case sidebarIdealWidth
    case sidebarMaxWidth

    case contentMinWidth

    case inspectorMinWidth
    case inspectorIdealWidth
    case inspectorMaxWidth

    case dialogWidth
    case sheetWidthSmall
    case sheetWidthMedium
    case sheetWidthLarge
    case sheetHeightSmall
    case sheetHeightLarge

    case keycapLabelSpacing
    case keycapPadding
    case keycapMinScale
    case keycapSecondaryMinScale

    case statusDotSize
    /// The width of the vertical bar that carries a layer's identity color —
    /// beside its sidebar row, beside the board's own eyebrow. Its corner
    /// radius is half this, so the ends round off fully.
    case layerAccentBarWidth
    case numericFieldWidth
    /// Room to leave at the trailing edge of a scrolling list for the overlay
    /// scroller, which AppKit draws on top of the content. A control flush to
    /// that edge — the `+` in a sidebar section header — is otherwise
    /// unclickable for as long as the scroller is showing.
    case scrollerGutter

    case boardMinScale
    case boardMaxScale
    /// The floor for `BoardDensity.thumbnail` — effectively none, so a board
    /// always fits the cell it is given.
    case boardThumbnailMinScale

    case menuBarPanelWidth
    case menuBarPanelHeight
    case menuBarThumbnailWidth
    case menuBarThumbnailHeight
    case menuBarComboListHeight

    case glossaryWindowWidth
    case glossaryWindowHeight
    case glossaryTermListWidth
    /// How wide a help popover is allowed to get. Narrow on purpose: an
    /// explanation set in a long line is measurably harder to read, and the
    /// popover is the short form — the glossary window is where the prose has
    /// room to breathe.
    case helpPopoverWidth
}

public enum ThemeFontToken: String, CaseIterable, Sendable {
    case title
    case heading
    case sectionLabel
    case body
    case caption
    case mono
    case monoSmall
    case keycapPrimary
    case keycapSecondary
}

// MARK: - Color values

/// A themeable color: either a literal hex value or a macOS semantic color that
/// already adapts to light/dark and the user's accent choice.
public enum ThemeColor: Equatable, Sendable, Codable {
    case hex(String)
    case system(SystemColor)

    public enum SystemColor: String, Equatable, Sendable, Codable, CaseIterable {
        case windowBackground
        case underPageBackground
        case controlBackground
        case textBackground
        case separator
        case grid
        case label
        case secondaryLabel
        case tertiaryLabel
        case quaternaryLabel
        case accent
        case selectedContentBackground
        case unemphasizedSelectedContentBackground

        var nsColor: NSColor {
            switch self {
            case .windowBackground: .windowBackgroundColor
            case .underPageBackground: .underPageBackgroundColor
            case .controlBackground: .controlBackgroundColor
            case .textBackground: .textBackgroundColor
            case .separator: .separatorColor
            case .grid: .gridColor
            case .label: .labelColor
            case .secondaryLabel: .secondaryLabelColor
            case .tertiaryLabel: .tertiaryLabelColor
            case .quaternaryLabel: .quaternaryLabelColor
            case .accent: .controlAccentColor
            case .selectedContentBackground: .selectedContentBackgroundColor
            case .unemphasizedSelectedContentBackground: .unemphasizedSelectedContentBackgroundColor
            }
        }
    }

    /// The SwiftUI color. Unparseable hex resolves to magenta so a broken theme
    /// is loud rather than invisible.
    public var color: Color {
        switch self {
        case .system(let system):
            Color(nsColor: system.nsColor)
        case .hex(let string):
            Self.parseHex(string) ?? Color(red: 1, green: 0, blue: 1)
        }
    }

    static func parseHex(_ string: String) -> Color? {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    // Encoded as a plain string: "#1f2328" or "system:label".
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw.hasPrefix("system:"), let system = SystemColor(rawValue: String(raw.dropFirst(7))) {
            self = .system(system)
        } else {
            self = .hex(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .hex(let value): try container.encode(value)
        case .system(let value): try container.encode("system:\(value.rawValue)")
        }
    }
}

// MARK: - Font values

public struct ThemeFontSpec: Equatable, Sendable, Codable {
    public var size: Double
    public var weight: Weight
    public var design: Design
    public var monospacedDigits: Bool

    public init(size: Double, weight: Weight = .regular, design: Design = .default, monospacedDigits: Bool = false) {
        self.size = size
        self.weight = weight
        self.design = design
        self.monospacedDigits = monospacedDigits
    }

    public enum Weight: String, Equatable, Sendable, Codable {
        case light, regular, medium, semibold, bold

        var fontWeight: Font.Weight {
            switch self {
            case .light: .light
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    public enum Design: String, Equatable, Sendable, Codable {
        case `default`, monospaced, rounded

        var fontDesign: Font.Design {
            switch self {
            case .default: .default
            case .monospaced: .monospaced
            case .rounded: .rounded
            }
        }
    }

    public var font: Font {
        let base = Font.system(size: size, weight: weight.fontWeight, design: design.fontDesign)
        return monospacedDigits ? base.monospacedDigit() : base
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = try container.decode(Double.self, forKey: .size)
        weight = try container.decodeIfPresent(Weight.self, forKey: .weight) ?? .regular
        design = try container.decodeIfPresent(Design.self, forKey: .design) ?? .default
        monospacedDigits = try container.decodeIfPresent(Bool.self, forKey: .monospacedDigits) ?? false
    }
}

// MARK: - Theme

/// A theme is plain data: two color palettes, a metric table and a font table,
/// all keyed by token raw value. Swapping the look of the app is a matter of
/// supplying a different `Theme`, never of editing a view.
public struct Theme: Equatable, Sendable, Codable, Identifiable {
    public var name: String
    public var light: [String: ThemeColor]
    public var dark: [String: ThemeColor]
    public var metrics: [String: Double]
    public var fonts: [String: ThemeFontSpec]

    public var id: String { name }

    public init(
        name: String,
        light: [String: ThemeColor] = [:],
        dark: [String: ThemeColor] = [:],
        metrics: [String: Double] = [:],
        fonts: [String: ThemeFontSpec] = [:]
    ) {
        self.name = name
        self.light = light
        self.dark = dark
        self.metrics = metrics
        self.fonts = fonts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        light = try container.decodeIfPresent([String: ThemeColor].self, forKey: .light) ?? [:]
        dark = try container.decodeIfPresent([String: ThemeColor].self, forKey: .dark) ?? [:]
        metrics = try container.decodeIfPresent([String: Double].self, forKey: .metrics) ?? [:]
        fonts = try container.decodeIfPresent([String: ThemeFontSpec].self, forKey: .fonts) ?? [:]
    }

    /// This theme's values laid over `base`, so a user theme only has to name
    /// the tokens it wants to change.
    public func merged(over base: Theme) -> Theme {
        Theme(
            name: name,
            light: base.light.merging(light) { _, new in new },
            dark: base.dark.merging(dark) { _, new in new },
            metrics: base.metrics.merging(metrics) { _, new in new },
            fonts: base.fonts.merging(fonts) { _, new in new }
        )
    }

    public func color(_ token: ThemeColorToken, scheme: ColorScheme) -> ThemeColor {
        let palette = scheme == .dark ? dark : light
        if let value = palette[token.rawValue] { return value }
        let fallback = scheme == .dark ? Theme.standard.dark : Theme.standard.light
        return fallback[token.rawValue] ?? .system(.label)
    }

    public func metric(_ token: ThemeMetricToken) -> Double {
        metrics[token.rawValue] ?? Theme.standard.metrics[token.rawValue] ?? 0
    }

    public func font(_ token: ThemeFontToken) -> ThemeFontSpec {
        fonts[token.rawValue] ?? Theme.standard.fonts[token.rawValue] ?? ThemeFontSpec(size: 13)
    }

    /// Flattens the theme for one color scheme so views do a dictionary lookup
    /// of already-built `Color`/`Font` values instead of re-resolving per read.
    ///
    /// This builds every color, metric and font in one go, so it is not cheap
    /// enough to call from a view body — go through `ThemeEngine.resolved(for:)`,
    /// which memoizes the result.
    public func resolved(for scheme: ColorScheme) -> ResolvedTheme {
        var colors: [ThemeColorToken: Color] = [:]
        for token in ThemeColorToken.allCases {
            colors[token] = color(token, scheme: scheme).color
        }
        var metricValues: [ThemeMetricToken: CGFloat] = [:]
        for token in ThemeMetricToken.allCases {
            metricValues[token] = CGFloat(metric(token))
        }
        var fontValues: [ThemeFontToken: Font] = [:]
        for token in ThemeFontToken.allCases {
            fontValues[token] = font(token).font
        }
        return ResolvedTheme(colors: colors, metrics: metricValues, fonts: fontValues)
    }
}

/// A theme flattened for one color scheme. This is what views read.
///
/// Keyed by the token enums rather than their raw values: nothing outside this
/// file looks inside, and no `Codable` conformance has to agree with the keys.
public struct ResolvedTheme: Equatable, Sendable {
    private let colors: [ThemeColorToken: Color]
    private let metrics: [ThemeMetricToken: CGFloat]
    private let fonts: [ThemeFontToken: Font]

    init(colors: [ThemeColorToken: Color], metrics: [ThemeMetricToken: CGFloat], fonts: [ThemeFontToken: Font]) {
        self.colors = colors
        self.metrics = metrics
        self.fonts = fonts
    }

    public func color(_ token: ThemeColorToken) -> Color { colors[token] ?? .primary }
    public func metric(_ token: ThemeMetricToken) -> CGFloat { metrics[token] ?? 0 }
    public func font(_ token: ThemeFontToken) -> Font { fonts[token] ?? .body }

    /// A layer's identity color, fixed by `index % 14` — layer 0 and layer 14
    /// draw the same accent. Reordering layers changes what color a given
    /// layer gets; that is accepted, because the accent names a position in
    /// the rainbow, not the layer itself.
    public func layerAccent(_ index: Int) -> Color {
        color(Self.layerAccentTokens[Self.wrappedLayerIndex(index)])
    }

    /// The same accent pulled down to a low-opacity wash — meant for a
    /// background behind other content, never for text or a mark on its own,
    /// so it can never read as a full-surface fill. The opacity is fixed here
    /// rather than passed in: it is what makes that true, and a caller free to
    /// raise it is a caller free to make a row unreadable.
    public func layerAccentSoft(_ index: Int) -> Color {
        layerAccent(index).opacity(Self.softWashOpacity)
    }

    /// The accent at underglow strength — for a selected layer-switch key's
    /// own halo, which stands in for ``ThemeColorToken/underglow`` rather than
    /// sitting beside it, so it wants the same rough intensity, not the soft
    /// wash a background wants.
    ///
    /// A blurred halo shows mostly at its edge, where the blur has already
    /// diluted it — so a hue that is dark to begin with (red, mauve) has less
    /// margin than a light one (yellow, sky) before it reads as no glow at
    /// all rather than a dim one. 0.8 is the blanket opacity that keeps the
    /// darkest accents legible without the lighter ones turning glaring — one
    /// value for every hue, which is why it is not a parameter.
    public func layerAccentGlow(_ index: Int) -> Color {
        layerAccent(index).opacity(Self.glowOpacity)
    }

    private static let softWashOpacity = 0.16
    private static let glowOpacity = 0.8

    /// `%` on a negative index returns a negative remainder in Swift, and a
    /// layer id is not guaranteed positive by anything at this layer — so this
    /// folds it back into the accent table's own range instead of trusting the
    /// caller.
    private static func wrappedLayerIndex(_ index: Int) -> Int {
        let remainder = index % layerAccentTokens.count
        return remainder < 0 ? remainder + layerAccentTokens.count : remainder
    }

    private static let layerAccentTokens: [ThemeColorToken] = [
        .layerAccent0, .layerAccent1, .layerAccent2, .layerAccent3, .layerAccent4,
        .layerAccent5, .layerAccent6, .layerAccent7, .layerAccent8, .layerAccent9,
        .layerAccent10, .layerAccent11, .layerAccent12, .layerAccent13,
    ]
}

// MARK: - Environment

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: ResolvedTheme = Theme.standard.resolved(for: .light)
}

extension EnvironmentValues {
    public var theme: ResolvedTheme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}

// MARK: - The one built-in theme

/// `Theme` stores its tables keyed by raw value because user theme JSON decodes
/// straight into them. These write the built-in tables token-keyed instead, so
/// the compiler checks the names — a typo in a raw-value string would compile
/// and silently fall through to the runtime default.
private func palette(_ entries: [ThemeColorToken: ThemeColor]) -> [String: ThemeColor] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) })
}

private func metricTable(_ entries: [ThemeMetricToken: Double]) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) })
}

private func fontTable(_ entries: [ThemeFontToken: ThemeFontSpec]) -> [String: ThemeFontSpec] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) })
}

extension Theme {
    /// Catppuccin: Latte by day, Frappé by night. The only theme shipped with
    /// the app; everything else is a user file that layers over it.
    ///
    /// The palettes are the published Catppuccin ramps and nothing else — no
    /// macOS semantic colors, because a system label or window background would
    /// pull its own greys into an otherwise closed palette and read as a
    /// mismatch. The two exceptions the flavours do not define are the soft
    /// accent wash and the two diff backgrounds, which are the flavour's own
    /// blue/green/red pulled down towards its `base`.
    public static let standard = Theme(
        name: "Catppuccin",
        // Latte. base #EFF1F5 · mantle #E6E9EF · crust #DCE0E8
        //
        // Three levels, and every surface in the app is one of them: the window
        // is `crust` — the desk the panes lie on and the only one nothing sits
        // behind; a pane card is `base` or `mantle`; a well set into a card is
        // one step back down the ramp.
        light: palette([
            .windowBackground: .hex("#DCE0E8"),
            .sidebarBackground: .hex("#E6E9EF"),
            .panelBackground: .hex("#E6E9EF"),
            .contentBackground: .hex("#EFF1F5"),
            .boardBackground: .hex("#E6E9EF"),

            .border: .hex("#CCD0DA"),
            .separator: .hex("#BCC0CC"),

            .primaryText: .hex("#4C4F69"),
            .secondaryText: .hex("#6C6F85"),
            .tertiaryText: .hex("#8C8FA1"),

            .accent: .hex("#1E66F5"),
            .accentSoft: .hex("#D8E2FD"),

            // The keyset, light to dark: an alpha's top face is `base`, a mod's
            // is `crust`, and both stand on a `surface0` wall. The plate they
            // are mounted in is `mantle`, between the two top faces — so an
            // alpha reads as raised off it and a mod as sunk into it, and
            // neither needs an outline to be found.
            .keycapFill: .hex("#EFF1F5"),
            .keycapModFill: .hex("#DCE0E8"),
            // One rung darker than `surface0`: Latte's ramp is compressed near
            // its light end, so a wall in `surface0` reads flush against the
            // `mantle` well beneath it — `surface1`, the same shade
            // `keycapStroke` already outlines a flat cap in, gives the
            // extrusion an edge that actually separates cap from plate.
            .keycapSide: .hex("#BCC0CC"),
            .keycapShadow: .hex("#4C4F6940"),
            .keycapStroke: .hex("#BCC0CC"),
            .keycapText: .hex("#4C4F69"),
            .keycapSubtext: .hex("#8C8FA1"),
            .keycapEmptyFill: .hex("#E6E9EF"),
            .keycapEmptyText: .hex("#9CA0B0"),
            .keycapSelectedFill: .hex("#D8E2FD"),
            .underglow: .hex("#1E66F5B3"),
            .keycapHighlight: .hex("#DF8E1DB3"),

            .success: .hex("#40A02B"),
            .warning: .hex("#DF8E1D"),
            .danger: .hex("#D20F39"),

            .diffAddText: .hex("#40A02B"),
            .diffAddBackground: .hex("#DFECDA"),
            .diffRemoveText: .hex("#D20F39"),
            .diffRemoveBackground: .hex("#F5DDE2"),
            .diffMeta: .hex("#6C6F85"),

            .badgeBackground: .hex("#CCD0DA"),
            .badgeText: .hex("#5C5F77"),

            // The 14 Catppuccin accents, in the canonical layer order — chosen
            // upstream for adjacent-hue separation, not alphabetically and not
            // in the order Catppuccin itself lists them.
            .layerAccent0: .hex("#7287FD"), // lavender
            .layerAccent1: .hex("#FE640B"), // peach
            .layerAccent2: .hex("#179299"), // teal
            .layerAccent3: .hex("#8839EF"), // mauve
            .layerAccent4: .hex("#40A02B"), // green
            .layerAccent5: .hex("#04A5E5"), // sky
            .layerAccent6: .hex("#EA76CB"), // pink
            .layerAccent7: .hex("#DF8E1D"), // yellow
            .layerAccent8: .hex("#209FB5"), // sapphire
            .layerAccent9: .hex("#E64553"), // maroon
            .layerAccent10: .hex("#D20F39"), // red
            .layerAccent11: .hex("#1E66F5"), // blue
            .layerAccent12: .hex("#DD7878"), // flamingo
            .layerAccent13: .hex("#DC8A78"), // rosewater
        ]),
        // Frappé. base #303446 · mantle #292C3F · crust #232634
        dark: palette([
            .windowBackground: .hex("#232634"),
            .sidebarBackground: .hex("#292C3F"),
            .panelBackground: .hex("#292C3F"),
            .contentBackground: .hex("#303446"),
            .boardBackground: .hex("#292C3F"),

            .border: .hex("#414559"),
            .separator: .hex("#51576D"),

            .primaryText: .hex("#C6D0F5"),
            .secondaryText: .hex("#A5ADCE"),
            .tertiaryText: .hex("#838BA7"),

            .accent: .hex("#8CAAEE"),
            .accentSoft: .hex("#3B4A6B"),

            // Same keyset one flavour down: `surface0` alphas, `base` mods, a
            // `crust` wall — darker than the `mantle` plate, so the silhouette
            // of every cap is a step down into shadow.
            .keycapFill: .hex("#414559"),
            .keycapModFill: .hex("#303446"),
            .keycapSide: .hex("#232634"),
            .keycapShadow: .hex("#2326348C"),
            .keycapStroke: .hex("#626880"),
            .keycapText: .hex("#C6D0F5"),
            .keycapSubtext: .hex("#838BA7"),
            .keycapEmptyFill: .hex("#292C3F"),
            .keycapEmptyText: .hex("#737994"),
            .keycapSelectedFill: .hex("#3B4A6B"),
            .underglow: .hex("#8CAAEECC"),
            .keycapHighlight: .hex("#E5C890CC"),

            .success: .hex("#A6D189"),
            .warning: .hex("#E5C890"),
            .danger: .hex("#E78284"),

            .diffAddText: .hex("#A6D189"),
            .diffAddBackground: .hex("#333F3D"),
            .diffRemoveText: .hex("#E78284"),
            .diffRemoveBackground: .hex("#43333F"),
            .diffMeta: .hex("#A5ADCE"),

            .badgeBackground: .hex("#51576D"),
            .badgeText: .hex("#B5BFE2"),

            // Same 14, one flavour down — Frappé's own published values, not
            // Latte's dimmed.
            .layerAccent0: .hex("#BABBF1"), // lavender
            .layerAccent1: .hex("#EF9F76"), // peach
            .layerAccent2: .hex("#81C8BE"), // teal
            .layerAccent3: .hex("#CA9EE6"), // mauve
            .layerAccent4: .hex("#A6D189"), // green
            .layerAccent5: .hex("#99D1DB"), // sky
            .layerAccent6: .hex("#F4B8E4"), // pink
            .layerAccent7: .hex("#E5C890"), // yellow
            .layerAccent8: .hex("#85C1DC"), // sapphire
            .layerAccent9: .hex("#EA999C"), // maroon
            .layerAccent10: .hex("#E78284"), // red
            .layerAccent11: .hex("#8CAAEE"), // blue
            .layerAccent12: .hex("#EEBEBE"), // flamingo
            .layerAccent13: .hex("#F2D5CF"), // rosewater
        ]),
        metrics: metricTable([
            .keyUnit: 54,
            .keyInset: 3,
            .keyCornerRadius: 9,
            .keycapTopInset: 2,
            .keycapTopShift: 1.5,
            .keycapShadowRadius: 4,
            .keycapShadowYOffset: 2,
            .underglowBlur: 7,

            .cornerRadiusSmall: 6,
            .cornerRadiusMedium: 10,
            .cornerRadiusLarge: 14,

            .borderWidth: 1,

            .spacingXS: 4,
            .spacingS: 8,
            .spacingM: 12,
            .spacingL: 18,

            .paneGutter: 10,
            .panePadding: 14,


            .sidebarMinWidth: 200,
            .sidebarIdealWidth: 232,
            .sidebarMaxWidth: 320,

            .contentMinWidth: 460,

            .inspectorMinWidth: 300,
            .inspectorIdealWidth: 340,
            .inspectorMaxWidth: 480,

            .dialogWidth: 460,
            .sheetWidthSmall: 420,
            .sheetWidthMedium: 480,
            .sheetWidthLarge: 780,
            .sheetHeightSmall: 520,
            .sheetHeightLarge: 560,

            .keycapLabelSpacing: 1,
            .keycapPadding: 3,
            .keycapMinScale: 0.45,
            .keycapSecondaryMinScale: 0.6,

            .statusDotSize: 7,
            .layerAccentBarWidth: 3,
            .numericFieldWidth: 120,
            .scrollerGutter: 12,

            .boardMinScale: 0.4,
            .boardMaxScale: 1.6,
            .boardThumbnailMinScale: 0.05,

            .menuBarPanelWidth: 720,
            .menuBarPanelHeight: 760,
            .menuBarThumbnailWidth: 310,
            .menuBarThumbnailHeight: 132,
            .menuBarComboListHeight: 190,

            .glossaryWindowWidth: 760,
            .glossaryWindowHeight: 560,
            .glossaryTermListWidth: 230,
            .helpPopoverWidth: 320,
        ]),
        fonts: fontTable([
            .title: ThemeFontSpec(size: 15, weight: .semibold),
            .heading: ThemeFontSpec(size: 13, weight: .semibold),
            .sectionLabel: ThemeFontSpec(size: 10, weight: .semibold),
            .body: ThemeFontSpec(size: 13),
            .caption: ThemeFontSpec(size: 11),
            .mono: ThemeFontSpec(size: 12, design: .monospaced),
            .monoSmall: ThemeFontSpec(size: 11, design: .monospaced),
            .keycapPrimary: ThemeFontSpec(size: 15, weight: .semibold),
            .keycapSecondary: ThemeFontSpec(size: 9, weight: .medium),
        ])
    )
}
