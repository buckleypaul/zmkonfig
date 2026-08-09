import Foundation

public enum LayoutCatalogError: Error, CustomStringConvertible {
    case invalidKeyboardID(String)
    /// Upstream returned 404 and nothing is cached.
    case notFound(resource: String)
    /// The fetch failed and there is no cached copy to fall back on.
    case unavailable(resource: String, reason: String)
    case malformedJSON(resource: String, reason: String)

    public var description: String {
        switch self {
        case .invalidKeyboardID(let id):
            "\"\(id)\" is not a valid keyboard id."
        case .notFound(let resource):
            "\(resource) does not exist in keymap-editor-contrib."
        case .unavailable(let resource, let reason):
            "Could not load \(resource) and no cached copy is available: \(reason)"
        case .malformedJSON(let resource, let reason):
            "\(resource) is not valid keyboard layout JSON: \(reason)"
        }
    }
}

/// Physical keyboard layouts from `nickcoutsos/keymap-editor-contrib`.
///
/// Everything fetched is mirrored under `~/Library/Caches/Zmkonfig/layouts`, so
/// the app keeps working offline once a keyboard has been seen. Fresh cache
/// entries are served without touching the network at all.
public actor LayoutCatalog {
    public static let shared = LayoutCatalog()

    private static let remoteBase = URL(
        string: "https://raw.githubusercontent.com/nickcoutsos/keymap-editor-contrib/HEAD/"
    )!
    private static let catalogResource = "keyboard-catalog.json"

    /// `~/Library/Caches/Zmkonfig/layouts`.
    public nonisolated let cacheDirectory: URL

    private let session: URLSession
    /// How long a cached file is used without revalidating.
    private let freshness: TimeInterval

    private var catalogMemo: [CatalogEntry]?
    private var definitionMemo: [String: KeyboardDefinition] = [:]

    public init(
        cacheDirectory: URL? = nil,
        session: URLSession? = nil,
        freshness: TimeInterval = 24 * 60 * 60
    ) {
        self.cacheDirectory = cacheDirectory
            ?? URL.cachesDirectory
                .appending(path: "Zmkonfig")
                .appending(path: "layouts")
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
        self.freshness = freshness
    }

    // MARK: - Catalog

    /// Every keyboard in the contrib catalog, sorted by display name.
    public func catalog(forceRefresh: Bool = false) async throws -> [CatalogEntry] {
        if !forceRefresh, let catalogMemo { return catalogMemo }

        let data = try await load(
            resource: Self.catalogResource,
            cacheName: Self.catalogResource,
            forceRefresh: forceRefresh
        )
        // The catalog is an object keyed by id; the values repeat the id.
        let raw: [String: CatalogValue] = try Self.decode(data, resource: Self.catalogResource)
        let entries = raw
            .map { key, value in CatalogEntry(id: value.id ?? key, name: value.name ?? key) }
            .sorted { left, right in
                switch left.name.localizedStandardCompare(right.name) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: left.id < right.id
                }
            }

        catalogMemo = entries
        return entries
    }

    /// The keyboard definition for a catalog id, e.g. `cradio`.
    public func definition(id: String, forceRefresh: Bool = false) async throws -> KeyboardDefinition {
        // The id becomes both a URL path component and a cache filename.
        guard PathComponent.isSafe(id) else { throw LayoutCatalogError.invalidKeyboardID(id) }
        if !forceRefresh, let cached = definitionMemo[id] { return cached }

        let resource = "keyboard-data/\(id).json"
        let data = try await load(resource: resource, cacheName: "\(id).json", forceRefresh: forceRefresh)
        let definition = try Self.decodeDefinition(data, resource: resource)

        definitionMemo[id] = definition
        return definition
    }

    /// A repository's own `config/info.json`, when it ships one.
    ///
    /// Returns nil when the file is absent so the caller can fall back to the
    /// remote catalog; a file that is present but unreadable is an error.
    public func definitionForRepo(_ repoRoot: URL) async throws -> KeyboardDefinition? {
        let infoURL = repoRoot
            .appending(path: "config")
            .appending(path: "info.json")
        guard FileManager.default.fileExists(atPath: infoURL.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: infoURL)
        } catch {
            throw LayoutCatalogError.unavailable(resource: infoURL.path, reason: String(describing: error))
        }
        return try Self.decodeDefinition(data, resource: infoURL.path)
    }

    // MARK: - Fetch and cache

    private func load(resource: String, cacheName: String, forceRefresh: Bool) async throws -> Data {
        let cacheURL = cacheDirectory.appending(path: cacheName)

        if !forceRefresh, let fresh = cachedData(at: cacheURL, newerThan: freshness) {
            return fresh
        }

        do {
            let data = try await fetch(resource: resource)
            write(data, to: cacheURL)
            return data
        } catch let error as LayoutCatalogError {
            // A stale mirror beats no layout at all.
            if let stale = try? Data(contentsOf: cacheURL) { return stale }
            throw error
        } catch {
            if let stale = try? Data(contentsOf: cacheURL) { return stale }
            throw LayoutCatalogError.unavailable(resource: resource, reason: String(describing: error))
        }
    }

    private func fetch(resource: String) async throws -> Data {
        let url = Self.remoteBase.appending(path: resource)
        let (data, response) = try await session.data(from: url)

        guard let http = response as? HTTPURLResponse else {
            throw LayoutCatalogError.unavailable(resource: resource, reason: "unexpected response")
        }
        if http.statusCode == 404 {
            throw LayoutCatalogError.notFound(resource: resource)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LayoutCatalogError.unavailable(resource: resource, reason: "HTTP \(http.statusCode)")
        }
        return data
    }

    private func cachedData(at url: URL, newerThan maxAge: TimeInterval) -> Data? {
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(modified) < maxAge else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// Best-effort mirror write. The data is already in hand, so a full cache
    /// disk or a sandbox denial should degrade to "no offline copy", not fail
    /// the load the caller is waiting on.
    private func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Decoding

    /// Catalog values in practice always carry both fields; the id falls back to
    /// the object key so one sloppy entry cannot fail the whole catalog.
    private struct CatalogValue: Decodable {
        var id: String?
        var name: String?
    }

    /// Decodes a keyboard definition, normalising the two shapes that appear in
    /// the wild: `layouts` as an object keyed by transform name (most boards),
    /// and `layouts` as an array of named variants (`kyria_rev3`,
    /// `splitkb_aurora_sofle`). `KeyboardDefinition` only models the former.
    nonisolated static func decodeDefinition(_ data: Data, resource: String) throws -> KeyboardDefinition {
        let raw: RawDefinition = try decode(data, resource: resource)
        return raw.normalized()
    }

    private nonisolated static func decode<T: Decodable>(_ data: Data, resource: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LayoutCatalogError.malformedJSON(resource: resource, reason: String(describing: error))
        }
    }

    private struct RawDefinition: Decodable {
        var id: String?
        var name: String?
        var layouts: Layouts

        enum Layouts: Decodable {
            case keyed([String: LayoutVariant])
            case list([LayoutVariant])

            init(from decoder: any Decoder) throws {
                // Probing for an unkeyed container tells us the JSON shape
                // without swallowing errors from inside the variants.
                if (try? decoder.unkeyedContainer()) != nil {
                    self = .list(try decoder.singleValueContainer().decode([LayoutVariant].self))
                } else {
                    self = .keyed(try decoder.singleValueContainer().decode([String: LayoutVariant].self))
                }
            }
        }

        func normalized() -> KeyboardDefinition {
            switch layouts {
            case .keyed(let keyed):
                return KeyboardDefinition(id: id, name: name, layouts: keyed)
            case .list(let list):
                var keyed: [String: LayoutVariant] = [:]
                for (offset, variant) in list.enumerated() {
                    var key = variant.name ?? "layout_\(offset)"
                    if keyed[key] != nil { key = "\(key)_\(offset)" }
                    keyed[key] = variant
                }
                return KeyboardDefinition(id: id, name: name, layouts: keyed)
            }
        }
    }
}
