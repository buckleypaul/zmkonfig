import Foundation
import Testing

@testable import ZmkonfigKit

/// The two ways out of a working copy a fast-forward cannot move: throw the
/// local edits away, or replay the local commits on top.
///
/// These drive the real `git` binary against real repositories in a temporary
/// directory. Nothing here touches the network — "origin" is a bare repo a few
/// directories over — and nothing touches the user's checkouts.
@Suite("Git working-copy recovery")
struct GitTests {

    // MARK: - Harness

    /// A bare origin, a `seed` clone that stands in for someone else pushing,
    /// and the `work` clone under test.
    private struct Sandbox {
        let root: URL
        let seed: URL
        let git: Git

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL) async throws -> ShellResult {
        try await Shell.checked("git", arguments, cwd: directory, environment: Git.environment)
    }

    /// An author, so `commit` has one. A test process inherits whatever the
    /// machine's global config says, which on a fresh CI box is nothing.
    private static func identify(_ repository: URL) async throws {
        try await git(["config", "user.email", "test@zmkonfig.invalid"], in: repository)
        try await git(["config", "user.name", "Zmkonfig Tests"], in: repository)
        try await git(["config", "commit.gpgsign", "false"], in: repository)
    }

    private static func write(_ text: String, to file: URL) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func read(_ file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    private static func makeSandbox() async throws -> Sandbox {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("zmkonfig-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let origin = root.appendingPathComponent("origin.git", isDirectory: true)
        try await git(["init", "--bare", "--initial-branch=main", origin.path], in: root)

        // A bare repo has no working tree to make the first commit from, so the
        // history starts in a clone and is pushed back.
        let seed = root.appendingPathComponent("seed", isDirectory: true)
        try await Git.clone(remote: origin.path, into: seed)
        try await identify(seed)
        try write("one\n", to: seed.appendingPathComponent("file.txt"))
        try await git(["add", "--all"], in: seed)
        try await git(["commit", "--message", "Seed"], in: seed)
        try await git(["push", "--set-upstream", "origin", "main"], in: seed)

        let work = root.appendingPathComponent("work", isDirectory: true)
        let git = try await Git.clone(remote: origin.path, into: work)
        try await identify(work)
        return Sandbox(root: root, seed: seed, git: git)
    }

    /// Commits `text` into `file.txt` on the origin, as another author would.
    private static func pushFromSeed(_ sandbox: Sandbox, file: String, text: String, message: String) async throws {
        try write(text, to: sandbox.seed.appendingPathComponent(file))
        try await git(["add", "--all"], in: sandbox.seed)
        try await git(["commit", "--message", message], in: sandbox.seed)
        try await git(["push"], in: sandbox.seed)
    }

    /// True while a rebase is stopped part-way through — the state the app must
    /// never leave a working copy in.
    private static func isRebasing(_ git: Git) async throws -> Bool {
        for directory in ["rebase-merge", "rebase-apply"] {
            let path = try await Shell.checked(
                "git", ["rev-parse", "--git-path", directory],
                cwd: git.root, environment: Git.environment
            ).trimmed
            let resolved = path.hasPrefix("/") ? path : git.root.appendingPathComponent(path).path
            if FileManager.default.fileExists(atPath: resolved) { return true }
        }
        return false
    }

    // MARK: - Status

    @Test("Untracked files are reported apart from tracked changes")
    func untrackedSplit() async throws {
        let sandbox = try await Self.makeSandbox()
        defer { sandbox.remove() }

        try Self.write("edited\n", to: sandbox.git.root.appendingPathComponent("file.txt"))
        try Self.write("junk\n", to: sandbox.git.root.appendingPathComponent("build.log"))

        let status = try await sandbox.git.status()
        #expect(status.isDirty)
        #expect(status.changedFiles.sorted() == ["build.log", "file.txt"])
        #expect(status.untrackedFiles == ["build.log"])
        #expect(status.trackedChangedFiles == ["file.txt"])
    }

    // MARK: - Discarding

    @Test("Discarding restores tracked files and leaves untracked ones alone")
    func discardRestoresTrackedOnly() async throws {
        let sandbox = try await Self.makeSandbox()
        defer { sandbox.remove() }
        let tracked = sandbox.git.root.appendingPathComponent("file.txt")
        let untracked = sandbox.git.root.appendingPathComponent("zephyr-build.log")

        try Self.write("edited\n", to: tracked)
        try Self.write("keep me\n", to: untracked)

        try await sandbox.git.discardLocalChanges()

        #expect(try Self.read(tracked) == "one\n")
        // A west workspace lives beside the config; a discard is not licence to
        // delete it.
        #expect(try Self.read(untracked) == "keep me\n")
        #expect(try await sandbox.git.status().trackedChangedFiles.isEmpty)
    }

    @Test("Discarding unstages a staged change too")
    func discardUnstages() async throws {
        let sandbox = try await Self.makeSandbox()
        defer { sandbox.remove() }
        let tracked = sandbox.git.root.appendingPathComponent("file.txt")

        try Self.write("staged\n", to: tracked)
        try await Self.git(["add", "--all"], in: sandbox.git.root)
        #expect(try await sandbox.git.status().isDirty)

        try await sandbox.git.discardLocalChanges()

        #expect(try Self.read(tracked) == "one\n")
        #expect(try await sandbox.git.status().isDirty == false)
    }

    @Test("Discarding in a repository with no commits says so")
    func discardWithoutHEAD() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("zmkonfig-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.git(["init", "--initial-branch=main", "."], in: root)

        await #expect(throws: GitError.noCommits) {
            try await Git(root: root).discardLocalChanges()
        }
    }

    // MARK: - Rebasing

    @Test("Rebase replays local commits on top of the upstream")
    func rebaseReplaysLocalCommits() async throws {
        let sandbox = try await Self.makeSandbox()
        defer { sandbox.remove() }

        try await Self.pushFromSeed(sandbox, file: "other.txt", text: "theirs\n", message: "Theirs")
        try Self.write("mine\n", to: sandbox.git.root.appendingPathComponent("file.txt"))
        try await sandbox.git.commitAll(message: "Mine")

        try await sandbox.git.pullRebase()

        // Both sides' work is present, and the local commit sits on top.
        #expect(try Self.read(sandbox.git.root.appendingPathComponent("file.txt")) == "mine\n")
        #expect(try Self.read(sandbox.git.root.appendingPathComponent("other.txt")) == "theirs\n")
        let status = try await sandbox.git.status()
        #expect(status.ahead == 1)
        #expect(status.behind == 0)
        #expect(status.isDirty == false)
    }

    @Test("A conflicting rebase is rolled back, not left half-applied")
    func rebaseConflictRollsBack() async throws {
        let sandbox = try await Self.makeSandbox()
        defer { sandbox.remove() }
        let file = sandbox.git.root.appendingPathComponent("file.txt")

        // Both sides rewrite the same line.
        try await Self.pushFromSeed(sandbox, file: "file.txt", text: "theirs\n", message: "Theirs")
        try Self.write("mine\n", to: file)
        try await sandbox.git.commitAll(message: "Mine")
        let before = try await sandbox.git.headSHA()

        await #expect(throws: GitError.rebaseConflicted(branch: "main")) {
            try await sandbox.git.pullRebase()
        }

        #expect(try await sandbox.git.headSHA() == before)
        #expect(try Self.read(file) == "mine\n")
        #expect(try await sandbox.git.status().isDirty == false)
        #expect(try await Self.isRebasing(sandbox.git) == false)
    }

    @Test("Rebase refuses to run over uncommitted changes")
    func rebaseRefusesDirtyTree() async throws {
        let sandbox = try await Self.makeSandbox()
        defer { sandbox.remove() }

        try await Self.pushFromSeed(sandbox, file: "other.txt", text: "theirs\n", message: "Theirs")
        try Self.write("uncommitted\n", to: sandbox.git.root.appendingPathComponent("file.txt"))

        await #expect(throws: GitError.uncommittedChanges) {
            try await sandbox.git.pullRebase()
        }
        // Refused before anything ran: the edit is still there to be discarded
        // or committed, which is what the error tells the user to do.
        #expect(try Self.read(sandbox.git.root.appendingPathComponent("file.txt")) == "uncommitted\n")
    }
}
