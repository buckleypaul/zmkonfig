import Foundation

public enum RepoError: Error, CustomStringConvertible, Equatable {
    case invalidSlug(String)
    case missingConfigDirectory(URL)
    case keymapNotFound(URL)
    case ambiguousKeymap(URL, [String])
    case destinationNotEmpty(URL)

    public var description: String {
        switch self {
        case .invalidSlug(let slug):
            "\"\(slug)\" is not a GitHub repository slug — expected owner/name."
        case .missingConfigDirectory(let root):
            "\(root.lastPathComponent) has no config/ directory; it does not look like a zmk-config repository."
        case .keymapNotFound(let root):
            "No config/*.keymap file in \(root.lastPathComponent)."
        case .ambiguousKeymap(let root, let candidates):
            "\(root.lastPathComponent) has more than one keymap in config/ (\(candidates.joined(separator: ", "))); "
                + "pick one explicitly."
        case .destinationNotEmpty(let url):
            "\(url.path) already exists and is not an empty directory."
        }
    }
}

/// A cloned zmk-config repository on disk.
public struct ZmkRepo: Sendable, Identifiable, Equatable, Hashable {
    public var id: String { slug }
    /// GitHub slug, `owner/name`.
    public let slug: String
    /// Root of the local clone.
    public let localURL: URL
    /// The resolved `config/*.keymap`.
    public let keymapPath: URL

    public init(slug: String, localURL: URL, keymapPath: URL) {
        self.slug = slug
        self.localURL = localURL
        self.keymapPath = keymapPath
    }
}

/// Owns the local clones of the user's zmk-config repositories.
public actor RepoManager {
    public static let shared = RepoManager()

    /// `~/Library/Application Support/Zmkonfig/repos`, holding `<owner>/<name>` clones.
    public nonisolated let supportDirectory: URL

    public init(supportDirectory: URL? = nil) {
        self.supportDirectory = supportDirectory
            ?? URL.applicationSupportDirectory
                .appending(path: "Zmkonfig")
                .appending(path: "repos")
    }

    // MARK: - Opening

    /// Returns the local clone of `slug`, cloning it first if it is not there yet.
    ///
    /// An existing clone is refreshed with `git fetch`, which only updates
    /// remote-tracking refs — uncommitted work in the working tree is never
    /// touched. Nothing about opening the repository depends on it: the keymap
    /// is read from the working tree, and the fetch only sharpens ahead/behind
    /// reporting. So it runs in the background and this returns straight away,
    /// rather than making the first frame wait on a network round trip — or, on
    /// a machine that is offline, on a full connect timeout.
    ///
    /// Await ``fetch(slug:)`` to learn when it landed and to see its failure;
    /// refreshing status afterwards is what shows the result.
    public func open(slug: String) async throws -> ZmkRepo {
        let (owner, name) = try Self.split(slug: slug)
        let root = localURL(owner: owner, name: name)
        guard Self.isClone(root) else { return try await clone(slug: slug) }

        // Detached: this must not inherit the caller's actor, or the shell-out
        // would be scheduled back on whatever opened the repository.
        fetches[slug] = Task.detached { try await Git(root: root).fetch() }
        return try repo(owner: owner, name: name, root: root)
    }

    /// The background `git fetch` the last ``open(slug:)`` started for each
    /// clone. Kept once it finishes so a caller that asks later still learns how
    /// it went; replaced, not cancelled, by a second open — a fetch already
    /// under way is answering the same question.
    private var fetches: [String: Task<Void, any Error>] = [:]

    /// Waits for the background fetch ``open(slug:)`` started, rethrowing its
    /// failure — the one place that fetch's error is visible.
    ///
    /// Returns immediately when there is none: `slug` was cloned rather than
    /// opened, or was never opened in this session.
    public func fetch(slug: String) async throws {
        guard let task = fetches[slug] else { return }
        try await task.value
    }

    /// Clones `slug` over SSH into the support directory.
    public func clone(slug: String) async throws -> ZmkRepo {
        let (owner, name) = try Self.split(slug: slug)
        let root = localURL(owner: owner, name: name)

        // git clone is happy to fill an existing empty directory, but refuses a
        // populated one — catch that here so the error names the real problem.
        if FileManager.default.fileExists(atPath: root.path) {
            let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path)
            guard entries?.isEmpty ?? false else { throw RepoError.destinationNotEmpty(root) }
        }
        try FileManager.default.createDirectory(
            at: root.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try await Git.clone(remote: "git@github.com:\(owner)/\(name).git", into: root)
        return try repo(owner: owner, name: name, root: root)
    }

    /// The repository value for a clone that is known to be on disk.
    private func repo(owner: String, name: String, root: URL) throws -> ZmkRepo {
        ZmkRepo(slug: "\(owner)/\(name)", localURL: root, keymapPath: try findKeymap(in: root))
    }

    public nonisolated func localURL(owner: String, name: String) -> URL {
        // No directoryHint: a trailing slash would make otherwise-identical
        // ZmkRepo values compare unequal.
        supportDirectory
            .appending(path: owner)
            .appending(path: name)
    }

    // MARK: - Keymap resolution

    /// Finds the repository's keymap the way the keymap-editor web app does:
    /// the `*.keymap` file directly under `config/`, matched case-insensitively.
    ///
    /// The web app silently takes the first match; here more than one match is
    /// an error, because writing to the wrong keymap would be worse than asking.
    public nonisolated func findKeymap(in repoRoot: URL) throws -> URL {
        let configDirectory = repoRoot.appending(path: "config")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: configDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RepoError.missingConfigDirectory(repoRoot)
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: configDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let candidates = entries
            .filter { $0.lastPathComponent.lowercased().hasSuffix(".keymap") }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        switch candidates.count {
        case 0:
            throw RepoError.keymapNotFound(repoRoot)
        case 1:
            return candidates[0]
        default:
            throw RepoError.ambiguousKeymap(repoRoot, candidates.map(\.lastPathComponent))
        }
    }

    // MARK: - Helpers

    /// Splits `owner/name`, rejecting anything that could escape the support
    /// directory or confuse the remote URL.
    static func split(slug: String) throws -> (owner: String, name: String) {
        let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw RepoError.invalidSlug(slug) }
        let owner = String(parts[0])
        var name = String(parts[1])
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard PathComponent.isSafe(owner), PathComponent.isSafe(name) else {
            throw RepoError.invalidSlug(slug)
        }
        return (owner, name)
    }

    /// Whether ``open(slug:)`` would accept this slug, for a UI that wants to
    /// say so before the user commits to it. The rule lives here rather than
    /// being approximated at the call site: a `contains("/")` check lets
    /// `owner/name/extra`, `/name` and `owner/..` through to fail later as an
    /// alert.
    public static func isValidSlug(_ slug: String) -> Bool {
        (try? split(slug: slug)) != nil
    }

    private static func isClone(_ root: URL) -> Bool {
        // A worktree or submodule uses a .git file rather than a directory, so
        // test for existence of either.
        FileManager.default.fileExists(atPath: root.appending(path: ".git").path)
    }
}
