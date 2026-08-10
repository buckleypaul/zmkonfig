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

    case keycapFill
    case keycapStroke
    case keycapText
    case keycapSubtext
    case keycapEmptyFill
    case keycapEmptyText
    case keycapSelectedFill
    case keycapSelectedStroke
    case keycapHighlightStroke

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

    case cornerRadiusSmall
    case cornerRadiusMedium

    case borderWidth
    case borderWidthSelected

    case spacingXS
    case spacingS
    case spacingM
    case spacingL


    case sidebarMinWidth
    case sidebarIdealWidth
    case sidebarMaxWidth

    case contentMinWidth
    case contentIdealWidth

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
        light: palette([
            .windowBackground: .hex("#EFF1F5"),
            .sidebarBackground: .hex("#E6E9EF"),
            .panelBackground: .hex("#E6E9EF"),
            .contentBackground: .hex("#EFF1F5"),
            .boardBackground: .hex("#DCE0E8"),

            .border: .hex("#CCD0DA"),
            .separator: .hex("#BCC0CC"),

            .primaryText: .hex("#4C4F69"),
            .secondaryText: .hex("#6C6F85"),
            .tertiaryText: .hex("#8C8FA1"),

            .accent: .hex("#1E66F5"),
            .accentSoft: .hex("#D8E2FD"),

            .keycapFill: .hex("#EFF1F5"),
            .keycapStroke: .hex("#BCC0CC"),
            .keycapText: .hex("#4C4F69"),
            .keycapSubtext: .hex("#8C8FA1"),
            .keycapEmptyFill: .hex("#E6E9EF"),
            .keycapEmptyText: .hex("#9CA0B0"),
            .keycapSelectedFill: .hex("#D8E2FD"),
            .keycapSelectedStroke: .hex("#1E66F5"),
            .keycapHighlightStroke: .hex("#DF8E1D"),

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
        ]),
        // Frappé. base #303446 · mantle #292C3F · crust #232634
        dark: palette([
            .windowBackground: .hex("#303446"),
            .sidebarBackground: .hex("#292C3F"),
            .panelBackground: .hex("#292C3F"),
            .contentBackground: .hex("#303446"),
            .boardBackground: .hex("#232634"),

            .border: .hex("#414559"),
            .separator: .hex("#51576D"),

            .primaryText: .hex("#C6D0F5"),
            .secondaryText: .hex("#A5ADCE"),
            .tertiaryText: .hex("#838BA7"),

            .accent: .hex("#8CAAEE"),
            .accentSoft: .hex("#3B4A6B"),

            .keycapFill: .hex("#414559"),
            .keycapStroke: .hex("#626880"),
            .keycapText: .hex("#C6D0F5"),
            .keycapSubtext: .hex("#838BA7"),
            .keycapEmptyFill: .hex("#292C3F"),
            .keycapEmptyText: .hex("#737994"),
            .keycapSelectedFill: .hex("#3B4A6B"),
            .keycapSelectedStroke: .hex("#8CAAEE"),
            .keycapHighlightStroke: .hex("#E5C890"),

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
        ]),
        metrics: metricTable([
            .keyUnit: 54,
            .keyInset: 3,
            .keyCornerRadius: 7,

            .cornerRadiusSmall: 4,
            .cornerRadiusMedium: 7,

            .borderWidth: 1,
            .borderWidthSelected: 2,

            .spacingXS: 4,
            .spacingS: 8,
            .spacingM: 12,
            .spacingL: 18,


            .sidebarMinWidth: 200,
            .sidebarIdealWidth: 232,
            .sidebarMaxWidth: 320,

            .contentMinWidth: 460,
            .contentIdealWidth: 700,

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
