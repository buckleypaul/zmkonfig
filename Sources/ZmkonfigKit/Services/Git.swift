import Foundation

extension String {
    /// A commit SHA cut to the length this app displays. One definition,
    /// because the 7 is a presentation choice repeated across three targets.
    public var abbreviatedSHA: String { String(prefix(7)) }
}

/// A snapshot of `git status` for the repository working tree.
public struct GitStatus: Sendable, Equatable {
    /// Branch name, or `(detached)` when HEAD is not on a branch.
    public let branch: String
    /// True when there is anything to commit — staged, unstaged, or untracked.
    public let isDirty: Bool
    /// Paths relative to the repository root, in git's order. A directory whose
    /// contents are all untracked collapses to one `dir/` entry, exactly as
    /// `git status` reports it.
    public let changedFiles: [String]
    /// The subset of ``changedFiles`` git has never been told about. Kept
    /// apart because ``Git/discardLocalChanges()`` restores tracked files and
    /// leaves these alone, and a dialog that says "this is thrown away" has to
    /// list the files that actually are.
    public let untrackedFiles: [String]
    /// Commits on this branch that the upstream does not have. Zero when there is no upstream.
    public let ahead: Int
    /// Commits on the upstream that this branch does not have. Zero when there is no upstream.
    public let behind: Int

    /// Tracked files with uncommitted changes: what a hard reset would undo.
    public var trackedChangedFiles: [String] {
        let untracked = Set(untrackedFiles)
        return changedFiles.filter { !untracked.contains($0) }
    }

    public init(
        branch: String,
        isDirty: Bool,
        changedFiles: [String],
        untrackedFiles: [String] = [],
        ahead: Int,
        behind: Int = 0
    ) {
        self.branch = branch
        self.isDirty = isDirty
        self.changedFiles = changedFiles
        self.untrackedFiles = untrackedFiles
        self.ahead = ahead
        self.behind = behind
    }
}

public enum GitError: Error, CustomStringConvertible, Equatable {
    case notARepository(URL)
    case nothingToCommit
    case emptyCommitMessage
    case detachedHead
    /// `pull` would need a merge or rebase, which we refuse to do behind the user's back.
    case divergedFromUpstream(branch: String)
    /// `pull` would overwrite local edits.
    case uncommittedChanges
    /// A rebase stopped on a conflict and was rolled back; the tree is untouched.
    case rebaseConflicted(branch: String)
    /// An operation that needs a HEAD to work from, in a repository with no commits.
    case noCommits
    case malformedStatus(String)

    public var description: String {
        switch self {
        case .notARepository(let url):
            "\(url.path) is not a git repository."
        case .nothingToCommit:
            "There is nothing to commit — the working tree is clean."
        case .emptyCommitMessage:
            "A commit message is required."
        case .detachedHead:
            "HEAD is detached; check out a branch before pushing."
        case .divergedFromUpstream(let branch):
            "`\(branch)` has diverged from its upstream. Reconcile the histories manually, then try again."
        case .uncommittedChanges:
            "Local changes would be overwritten by the pull. Commit or stash them first."
        case .rebaseConflicted(let branch):
            "Replaying `\(branch)` onto its upstream hit a conflict, so the rebase was rolled "
                + "back and nothing changed. Resolve it in a terminal, or discard the local "
                + "commits and pull again."
        case .noCommits:
            "The repository has no commits yet, so there is nothing to restore the working tree to."
        case .malformedStatus(let record):
            "Could not parse git status record: \(record)"
        }
    }
}

/// Git operations on one working copy, shelling out to the `git` CLI.
///
/// Network operations rely on whatever credentials the user's git and ssh
/// already have; nothing here prompts, and nothing here stores secrets.
public struct Git: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: - Subprocess plumbing

    /// Environment applied to every `git` invocation.
    ///
    /// Verified under a bundled app's environment (PATH reduced to
    /// `/usr/bin:/bin:/usr/sbin:/sbin`): `git` and `ssh` both resolve from
    /// /usr/bin, and SSH auth succeeds via the launchd ssh-agent.
    ///
    /// A prompt would not actually deadlock us — with no controlling terminal
    /// ssh cannot open /dev/tty and errors out instead. These are set so the
    /// failure is deterministic rather than dependent on the user's setup:
    /// BatchMode also forecloses the SSH_ASKPASS path, which *can* put a GUI
    /// dialog in front of a headless subprocess.
    public static var environment: [String: String] {
        var environment = [
            "GIT_TERMINAL_PROMPT": "0",
            // Let `status` run without taking the index lock, so a concurrent
            // commit or an editor's own git usage cannot make it fail.
            "GIT_OPTIONAL_LOCKS": "0",
        ]
        if ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] == nil {
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        }
        return environment
    }

    /// Runs git in `root`, returning the result whatever the exit status.
    private func run(_ arguments: [String]) async throws -> ShellResult {
        try await Shell.run("git", ["--no-pager"] + arguments, cwd: root, environment: Self.environment)
    }

    /// Runs git in `root`, throwing `ShellError` on a non-zero exit.
    @discardableResult
    private func checked(_ arguments: [String]) async throws -> ShellResult {
        try await Shell.checked("git", ["--no-pager"] + arguments, cwd: root, environment: Self.environment)
    }

    // MARK: - Queries

    public func isRepository() async throws -> Bool {
        try await run(["rev-parse", "--is-inside-work-tree"]).trimmed == "true"
    }

    public func currentBranch() async throws -> String {
        try await checked(["rev-parse", "--abbrev-ref", "HEAD"]).trimmed
    }

    public func headSHA() async throws -> String {
        try await checked(["rev-parse", "HEAD"]).trimmed
    }

    /// The configured upstream ref (`origin/main`), or nil when the branch has none.
    public func upstream() async throws -> String? {
        let result = try await run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        return result.ok ? result.trimmed : nil
    }

    /// False for a freshly initialised repository with no commits yet.
    public func hasCommits() async throws -> Bool {
        try await run(["rev-parse", "--verify", "--quiet", "HEAD"]).ok
    }

    public func status() async throws -> GitStatus {
        let result = try await run(["status", "--porcelain=v2", "--branch", "--untracked-files=normal", "-z"])
        guard result.ok else {
            guard try await isRepository() else { throw GitError.notARepository(root) }
            throw ShellError(command: "git status", result: result)
        }
        return try Self.parseStatus(result.stdout)
    }

    /// Unified diff of the working tree against HEAD, covering staged and
    /// unstaged edits alike — which is what `commitAll` would capture.
    ///
    /// Untracked files do not appear; `status().changedFiles` lists those.
    ///
    /// - Parameter hasCommits: Pass it when already known, to save the extra
    ///   `rev-parse` this would otherwise run to decide whether HEAD exists.
    public func diff(path: String? = nil, hasCommits: Bool? = nil) async throws -> String {
        var arguments = ["diff", "--no-color"]
        let headExists: Bool
        if let hasCommits {
            headExists = hasCommits
        } else {
            headExists = try await self.hasCommits()
        }
        if headExists { arguments.append("HEAD") }
        if let path { arguments += ["--", path] }
        return try await checked(arguments).stdout
    }

    // MARK: - Mutations

    /// Stages every change in the repository and commits it.
    public func commitAll(message: String) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitError.emptyCommitMessage
        }
        try await checked(["add", "--all"])

        // Everything is staged by now, so "is there anything to commit" is
        // exactly what `diff --cached --quiet` answers in its exit status: 0 for
        // an empty index diff, 1 when there are staged changes. Cheaper than
        // walking a full porcelain status just to read one bool, and it is
        // correct on an unborn branch too, where the comparison is against the
        // empty tree.
        let staged = try await run(["diff", "--cached", "--quiet"])
        switch staged.status {
        case 0: throw GitError.nothingToCommit
        case 1: break
        default: throw ShellError(command: "git diff --cached --quiet", result: staged)
        }

        try await checked(["commit", "--message", message])
    }

    /// Pushes the current branch, creating the upstream on first push.
    public func push() async throws {
        // Two independent `rev-parse` calls; spawn them together.
        async let branchName = currentBranch()
        async let upstreamRef = upstream()
        let (branch, upstream) = try await (branchName, upstreamRef)

        guard branch != "HEAD" else { throw GitError.detachedHead }
        if upstream != nil {
            try await checked(["push"])
        } else {
            try await checked(["push", "--set-upstream", "origin", branch])
        }
    }

    /// Fast-forwards the current branch. Never merges, rebases, or discards
    /// local work: anything that is not a clean fast-forward is an error the
    /// user has to resolve.
    public func pull() async throws {
        let result = try await run(["pull", "--ff-only"])
        guard !result.ok else { return }

        // Why it failed is asked of the repository, not of git's prose: that
        // wording is localized and gets rewritten between versions, so matching
        // on it turns into a raw ShellError the day it changes. `--porcelain=v2`
        // is format-stable and already says both things worth knowing.
        //
        // A status that cannot be read is not swallowed — it just leaves the
        // pull's own error, below, as the thing to report.
        if let status = try? await status() {
            // Commits on both sides: a fast-forward is impossible, and merging
            // or rebasing behind the user's back is not ours to do.
            if status.ahead > 0 && status.behind > 0 {
                throw GitError.divergedFromUpstream(branch: status.branch)
            }
            // Not diverged, so what the incoming commits collided with is the
            // working tree.
            if status.isDirty { throw GitError.uncommittedChanges }
        }
        throw ShellError(command: "git pull --ff-only", result: result)
    }

    /// Replays the branch's local commits on top of its upstream: `pull --rebase`,
    /// for the diverged case a fast-forward cannot reach.
    ///
    /// Two things are refused rather than attempted. A dirty working tree,
    /// because rebasing over uncommitted edits is how they get lost — the
    /// caller is told to discard or commit first. And a conflict: the app has
    /// no conflict-resolution UI, so a working copy parked mid-rebase is a trap
    /// the user would need a terminal to escape. It is rolled back instead, and
    /// the branch ends where it started.
    public func pullRebase() async throws {
        let before = try await status()
        if before.isDirty { throw GitError.uncommittedChanges }

        let result = try await run(["pull", "--rebase"])
        guard !result.ok else { return }

        // `rebase --abort` only succeeds when a rebase is actually in progress,
        // so its exit status is also how a conflict is told apart from a
        // failure that never started one — no upstream, no network, a host key
        // the agent would not vouch for. Those keep git's own message.
        guard try await run(["rebase", "--abort"]).ok else {
            throw ShellError(command: "git pull --rebase", result: result)
        }
        throw GitError.rebaseConflicted(branch: before.branch)
    }

    /// Puts tracked files back to HEAD, throwing away every uncommitted change
    /// to them. Unrecoverable, and meant to be: it is the way out of a working
    /// copy whose local edits are blocking a pull.
    ///
    /// Untracked files are deliberately left where they are. A ZMK checkout
    /// carries a west workspace and firmware artifacts beside the config, and
    /// "undo my edits" is not a licence to delete a hundred megabytes of Zephyr.
    public func discardLocalChanges() async throws {
        guard try await hasCommits() else { throw GitError.noCommits }
        try await checked(["reset", "--hard", "HEAD"])
    }

    /// Updates remote-tracking refs. Does not touch the working tree, so it is
    /// always safe to call over uncommitted edits.
    public func fetch() async throws {
        try await checked(["fetch", "--prune"])
    }

    /// Clones `remote` into `destination`, which must not already exist.
    @discardableResult
    public static func clone(remote: String, into destination: URL) async throws -> Git {
        try await Shell.checked(
            "git",
            ["clone", "--", remote, destination.path],
            environment: environment
        )
        return Git(root: destination)
    }

    // MARK: - Porcelain v2 parsing

    /// Parses NUL-separated `git status --porcelain=v2 --branch -z` output.
    ///
    /// See gitformat-status(5). Field counts below are the tokens preceding the
    /// path in each entry type; `-z` keeps paths verbatim rather than C-quoting
    /// them, at the cost of rename entries spilling their original path into the
    /// following record.
    static func parseStatus(_ output: String) throws -> GitStatus {
        let records = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)

        var branch = "(unknown)"
        var ahead = 0
        var behind = 0
        var changedFiles: [String] = []
        var untrackedFiles: [String] = []

        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            if record.isEmpty { continue }

            if record.hasPrefix("# ") {
                let parts = record.dropFirst(2).split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.head":
                    branch = String(parts[1])
                case "branch.ab":
                    for token in parts[1].split(separator: " ") {
                        guard let value = Int(token.dropFirst()) else { continue }
                        if token.hasPrefix("+") { ahead = value }
                        if token.hasPrefix("-") { behind = value }
                    }
                default:
                    break
                }
                continue
            }

            switch record.first {
            case "1":
                changedFiles.append(try Self.path(in: record, after: 8))
            case "2":
                changedFiles.append(try Self.path(in: record, after: 9))
                index += 1  // the rename/copy source path is its own record
            case "u":
                changedFiles.append(try Self.path(in: record, after: 10))
            case "?":
                let path = String(record.dropFirst(2))
                changedFiles.append(path)
                untrackedFiles.append(path)
            case "!":
                break  // ignored file; not a change
            default:
                throw GitError.malformedStatus(record)
            }
        }

        return GitStatus(
            branch: branch,
            isDirty: !changedFiles.isEmpty,
            changedFiles: changedFiles,
            untrackedFiles: untrackedFiles,
            ahead: ahead,
            behind: behind
        )
    }

    private static func path(in record: String, after fields: Int) throws -> String {
        let parts = record.split(separator: " ", maxSplits: fields, omittingEmptySubsequences: false)
        guard parts.count == fields + 1, !parts[fields].isEmpty else {
            throw GitError.malformedStatus(record)
        }
        return String(parts[fields])
    }
}
