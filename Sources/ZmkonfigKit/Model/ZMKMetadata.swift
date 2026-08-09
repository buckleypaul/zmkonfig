import Foundation

/// What one parameter slot of a behavior holds.
///
/// The vendored `zmk-behaviors.json` uses exactly these four across all 15
/// behaviors, so every switch over a slot kind can be exhaustive. An unknown
/// string fails to decode rather than defaulting to a keycode: the file is
/// vendored and version-controlled, so a fifth kind only ever appears when
/// someone re-vendors it, and a loud "could not load ZMK metadata" at that
/// point is far easier to act on than a slot quietly editing the wrong thing.
public enum ParamKind: String, Codable, Sendable {
    case code, layer, mod, command
}

/// A ZMK behavior definition from `zmk-behaviors.json`.
public struct ZMKBehavior: Codable, Equatable, Sendable, Identifiable {
    /// The bind token including the ampersand, e.g. `&kp`.
    public var code: String
    public var name: String
    /// Parameter kinds in order. Behaviors that take no parameters carry an
    /// empty array rather than null.
    public var params: [ParamKind]?
    /// `#include` lines this behavior needs in the keymap.
    public var includes: [String]?
    public var commands: [ZMKCommand]?

    public var id: String { code }

    public init(code: String, name: String, params: [ParamKind]? = nil, includes: [String]? = nil, commands: [ZMKCommand]? = nil) {
        self.code = code
        self.name = name
        self.params = params
        self.includes = includes
        self.commands = commands
    }
}

public struct ZMKCommand: Codable, Equatable, Sendable, Identifiable {
    public var code: String
    public var description: String?
    public var additionalParams: [ZMKAdditionalParam]?

    public var id: String { code }
}

public struct ZMKAdditionalParam: Codable, Equatable, Sendable {
    public var name: String?
    public var type: String?
}

/// A keycode from `zmk-keycodes.json`.
public struct ZMKKeycode: Codable, Equatable, Sendable, Identifiable {
    /// Aliases, most canonical first, e.g. `["LEFT_CONTROL", "LCTRL"]`.
    public var names: [String]
    public var description: String?
    /// Grouping used by the picker, e.g. `"Keyboard"`, `"Media"`, `"Bluetooth"`.
    public var context: String?
    public var os: OSSupport?

    public var id: String { names.first ?? description ?? UUID().uuidString }
    public var primaryName: String { names.first ?? "" }

    /// True when this keycode's names, description or context contain the
    /// query. `foldedQuery` must already be lowercased and trimmed — the caller
    /// folds it once instead of once per keycode.
    ///
    /// Everything here is ASCII, so the fold is a plain `lowercased()` rather
    /// than `localizedCaseInsensitiveContains`, which went through ICU for
    /// every name of every keycode on every keystroke and was most of the cost
    /// of typing into the picker.
    public func matches(_ foldedQuery: String) -> Bool {
        guard !foldedQuery.isEmpty else { return true }
        if names.contains(where: { $0.lowercased().contains(foldedQuery) }) { return true }
        if description?.lowercased().contains(foldedQuery) == true { return true }
        return context?.lowercased().contains(foldedQuery) == true
    }

    public struct OSSupport: Codable, Equatable, Sendable {
        public var windows: Bool?
        public var linux: Bool?
        public var android: Bool?
        public var macos: Bool?
        public var ios: Bool?
    }
}

/// Loads the vendored ZMK metadata shipped in the package bundle.
public enum ZMKMetadata {
    /// The package's own resource bundle, used when nothing overrides it.
    ///
    /// Exposed as an accessor because `Bundle.module` is internal and so cannot
    /// appear in a public function's default argument. Callers inside a
    /// packaged `.app` should pass an explicit bundle instead — see
    /// `AppResources` in the app target, which locates the copy that
    /// `make bundle` places in `Contents/Resources`.
    public static var resourceBundle: Bundle { .module }

    public static func loadBehaviors(bundle: Bundle = ZMKMetadata.resourceBundle) throws -> [ZMKBehavior] {
        try load("zmk-behaviors", as: [ZMKBehavior].self, bundle: bundle)
    }

    public static func loadKeycodes(bundle: Bundle = ZMKMetadata.resourceBundle) throws -> [ZMKKeycode] {
        try load("zmk-keycodes", as: [ZMKKeycode].self, bundle: bundle)
    }

    private static func load<T: Decodable>(_ name: String, as type: T.Type, bundle: Bundle) throws -> T {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw MetadataError.missingResource(name)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    public enum MetadataError: Error, CustomStringConvertible {
        case missingResource(String)

        public var description: String {
            switch self {
            case .missingResource(let name): "bundled resource \(name).json is missing"
            }
        }
    }
}
