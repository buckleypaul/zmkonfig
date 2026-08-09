import Foundation
import Observation
import SwiftUI

/// Which of a theme's two palettes to use.
///
/// `auto` is the absence of a choice, not a third palette: it means whatever
/// macOS is doing, so a view resolves it against the ambient `colorScheme`.
public enum AppearanceMode: String, CaseIterable, Sendable, Identifiable, Codable {
    case light
    case dark
    case auto

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .auto: "Auto"
        }
    }

    /// The scheme to force, or nil to follow the system.
    public var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .auto: nil
        }
    }
}

/// Owns the set of available themes and which one is current.
///
/// One theme ships with the app (`Theme.standard`). Anything else is a JSON
/// file in `~/.config/zmkonfig/themes/`, layered over the built-in so a file
/// only needs to name the tokens it changes:
///
/// ```json
/// { "name": "Warm", "light": { "keycapFill": "#FFFDF7", "accent": "#B4551F" } }
/// ```
@MainActor
@Observable
public final class ThemeEngine {
    public static let shared = ThemeEngine()

    /// Every theme that loaded, built-in first.
    public private(set) var themes: [Theme]
    /// Files that failed to load, so the UI can say so instead of silently
    /// falling back.
    public private(set) var loadErrors: [String] = []

    public var selectedName: String {
        didSet {
            UserDefaults.standard.set(selectedName, forKey: Self.defaultsKey)
            resolvedCache.removeAll()
        }
    }

    /// Light, dark, or follow macOS. Only the palette changes; the metric and
    /// font tables are shared, so there is no cache to drop here.
    public var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    public var theme: Theme {
        themes.first { $0.name == selectedName } ?? .standard
    }

    /// The palette to draw with, given what macOS currently is. Pass the view's
    /// `\.colorScheme`; it is used only when the mode is `auto`.
    public func scheme(system: ColorScheme) -> ColorScheme {
        appearance.colorScheme ?? system
    }

    /// Flattened themes, one per color scheme. Not observed: it is derived
    /// state, and a view that reads it has already observed `themes` and
    /// `selectedName` by way of `theme`.
    @ObservationIgnored private var resolvedCache: [ColorScheme: ResolvedTheme] = [:]

    /// The selected theme flattened for `scheme`, built once per theme change.
    ///
    /// Views call this from a body, and `Theme.resolved(for:)` materializes
    /// every color, metric and font — a cost worth paying when the theme
    /// changes and not on every unrelated re-evaluation of the root view.
    public func resolved(for scheme: ColorScheme) -> ResolvedTheme {
        // Read `theme` even on a hit: that is what registers the observation on
        // `themes` and `selectedName`, so the view still redraws when either
        // changes. Skipping it would leave a cached theme on screen forever.
        let selected = theme
        if let cached = resolvedCache[scheme] { return cached }
        let flattened = selected.resolved(for: scheme)
        resolvedCache[scheme] = flattened
        return flattened
    }

    private static let defaultsKey = "selectedTheme"
    private static let appearanceKey = "appearanceMode"

    public var userThemesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/zmkonfig/themes", isDirectory: true)
    }

    public init() {
        themes = [.standard]
        selectedName = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? Theme.standard.name
        appearance = UserDefaults.standard.string(forKey: Self.appearanceKey)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .auto
        reload()
    }

    /// Rescans the user theme directory. Cheap enough to call from a menu item.
    public func reload() {
        var loaded: [Theme] = [.standard]
        var errors: [String] = []

        let files = (try? FileManager.default.contentsOfDirectory(
            at: userThemesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: file)
                let theme = try JSONDecoder().decode(Theme.self, from: data)
                loaded.append(theme.merged(over: .standard))
            } catch {
                errors.append("\(file.lastPathComponent): \(error)")
            }
        }

        themes = loaded
        loadErrors = errors
        if !themes.contains(where: { $0.name == selectedName }) {
            selectedName = Theme.standard.name
        }
        // A reload can change a theme's contents without changing its name, so
        // drop the cache unconditionally rather than leaning on `selectedName`.
        resolvedCache.removeAll()
    }
}
