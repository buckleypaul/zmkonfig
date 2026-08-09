import Foundation

// MARK: - Models

/// A single GitHub Actions workflow run.
public struct WorkflowRun: Sendable, Identifiable {
    public let id: Int
    /// `queued`, `in_progress`, `completed`, and the rarer states GitHub adds
    /// (`waiting`, `requested`, `pending`). Treated as opaque apart from `completed`.
    public let status: String
    /// `success`, `failure`, `cancelled`, … — nil until the run completes.
    public let conclusion: String?
    public let htmlURL: String
    public let createdAt: Date
    public let displayTitle: String
    public let headSHA: String

    /// The abbreviated form shown in the UI.
    public var shortSHA: String { headSHA.abbreviatedSHA }

    public var isComplete: Bool { status == "completed" }
    public var succeeded: Bool { isComplete && conclusion == "success" }

    public init(
        id: Int,
        status: String,
        conclusion: String?,
        htmlURL: String,
        createdAt: Date,
        displayTitle: String,
        headSHA: String
    ) {
        self.id = id
        self.status = status
        self.conclusion = conclusion
        self.htmlURL = htmlURL
        self.createdAt = createdAt
        self.displayTitle = displayTitle
        self.headSHA = headSHA
    }
}

/// A downloaded, unzipped build artifact.
public struct BuildArtifact: Sendable {
    public let name: String
    /// The unzipped `.uf2` files, already classified by half and sorted
    /// left-then-right-then-unknown.
    public let files: [FirmwareImage]

    public init(name: String, files: [FirmwareImage]) {
        self.name = name
        self.files = files
    }
}

// MARK: - Errors

public enum GitHubError: Error, CustomStringConvertible, Sendable {
    /// `gh` is not installed, or not in any location we know to look.
    case ghNotFound
    case notAuthenticated(detail: String)
    case commandFailed(command: String, detail: String)
    case malformedResponse(command: String, detail: String)
    /// No run ever appeared for this commit within the timeout.
    case runNeverStarted(headSHA: String, waited: Duration)
    /// A run was found but had not finished when the timeout expired.
    case runTimedOut(run: WorkflowRun, waited: Duration)
    case noArtifacts(runID: Int)
    /// Every artifact on the run is past its retention window.
    case artifactsExpired(runID: Int, name: String)
    /// The artifact downloaded, but contained no `.uf2` firmware.
    case noFirmwareInArtifact(name: String, found: [String])

    public var description: String {
        switch self {
        case .ghNotFound:
            return """
                The GitHub CLI (`gh`) could not be found. Install it with `brew install gh`, \
                or set the ZMKONFIG_GH_PATH environment variable to its full path.
                """
        case .notAuthenticated(let detail):
            return "GitHub CLI is not authenticated — run `gh auth login`. (\(detail))"
        case .commandFailed(let command, let detail):
            return "`\(command)` failed: \(detail)"
        case .malformedResponse(let command, let detail):
            return "Could not read the response from `\(command)`: \(detail)"
        case .runNeverStarted(let sha, let waited):
            return """
                No workflow run appeared for commit \(sha.abbreviatedSHA) after \(waited.humanReadable). \
                The push may not have triggered a build.
                """
        case .runTimedOut(let run, let waited):
            return """
                Build \(run.id) was still \(run.status.replacingOccurrences(of: "_", with: " ")) \
                after \(waited.humanReadable). It may still finish — see \(run.htmlURL)
                """
        case .noArtifacts(let runID):
            return "Build \(runID) produced no artifacts. The build most likely failed."
        case .artifactsExpired(let runID, let name):
            return "The `\(name)` artifact from build \(runID) has expired. Run a new build."
        case .noFirmwareInArtifact(let name, let found):
            let contents = found.isEmpty ? "it was empty" : "it contained: \(found.joined(separator: ", "))"
            return "The `\(name)` artifact has no .uf2 firmware — \(contents)."
        }
    }
}

// MARK: - Client

/// Talks to the GitHub Actions API for one repository by driving the `gh` CLI.
///
/// `gh` is used rather than raw URLSession so that authentication is entirely
/// the CLI's problem — it reads the user's keychain token and refreshes it.
public actor GitHubClient {
    /// `owner/repo`.
    public let slug: String

    public init(slug: String) {
        self.slug = slug
    }

    // MARK: Public API

    /// Fires the workflow via `workflow_dispatch`.
    ///
    /// The build also runs on push, so a caller that has just pushed usually
    /// wants ``waitForRun(headSHA:timeout:onUpdate:)`` alone — dispatching as
    /// well would queue a second, redundant run.
    ///
    /// - Parameters:
    ///   - ref: Branch or tag to build.
    ///   - workflow: Workflow file name or numeric ID.
    public func dispatchBuild(ref: String = "main", workflow: String = "build.yml") async throws {
        _ = try await gh([
            "api", "--method", "POST",
            "repos/\(slug)/actions/workflows/\(workflow)/dispatches",
            "-f", "ref=\(ref)",
        ])
    }

    /// Most recent runs, newest first.
    public func recentRuns(limit: Int = 20) async throws -> [WorkflowRun] {
        let clamped = max(1, min(limit, 100))
        let result = try await gh(["api", "repos/\(slug)/actions/runs?per_page=\(clamped)"])
        return try decodeRunList(result.stdout, command: "gh api actions/runs")
    }

    public func run(id: Int) async throws -> WorkflowRun {
        let result = try await gh(["api", "repos/\(slug)/actions/runs/\(id)"])
        let dto: RunDTO = try decode(result.stdout, command: "gh api actions/runs/\(id)")
        return dto.model
    }

    /// Polls until the run for `headSHA` finishes, reporting every state change.
    ///
    /// Handles the race after a push, where the run does not exist yet: it first
    /// polls for a run on that commit to appear, then polls that run to
    /// completion. `onUpdate` fires when the run is first seen and on every
    /// subsequent status or conclusion change — never twice for the same state.
    ///
    /// A completed run is returned whatever its conclusion; check
    /// ``WorkflowRun/succeeded``. Only never appearing, never finishing, or an
    /// API failure throws.
    ///
    /// - Note: `push` and `pull_request` can both produce a run for one commit.
    ///   The newest is followed.
    @discardableResult
    public func waitForRun(
        headSHA: String,
        timeout: Duration = .seconds(600),
        onUpdate: @Sendable (WorkflowRun) -> Void = { _ in }
    ) async throws -> WorkflowRun {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: timeout)

        var current: WorkflowRun?
        var lastReported: (status: String, conclusion: String?)?

        while true {
            try Task.checkCancellation()

            let latest: WorkflowRun?
            if let found = current {
                latest = try await run(id: found.id)
            } else {
                latest = try await newestRun(headSHA: headSHA)
            }

            if let latest {
                current = latest
                if lastReported?.status != latest.status || lastReported?.conclusion != latest.conclusion {
                    lastReported = (latest.status, latest.conclusion)
                    onUpdate(latest)
                }
                if latest.isComplete { return latest }
            }

            guard clock.now < deadline else {
                let waited = started.duration(to: clock.now)
                if let current {
                    throw GitHubError.runTimedOut(run: current, waited: waited)
                }
                throw GitHubError.runNeverStarted(headSHA: headSHA, waited: waited)
            }

            // Poll faster while waiting for the run to show up — it usually
            // appears within a couple of seconds of the push.
            try await Task.sleep(for: current == nil ? .seconds(3) : .seconds(5))
        }
    }

    /// Downloads and unzips the run's artifact into `directory`, which is
    /// emptied first and so must be a directory the caller owns outright.
    ///
    /// `gh run download` unzips for us, writing the archive's files flat into
    /// the target directory. When a run carries several artifacts the one whose
    /// name mentions "firmware" wins, then the newest.
    @discardableResult
    public func downloadArtifacts(runID: Int, to directory: URL) async throws -> BuildArtifact {
        let artifacts = try await artifacts(runID: runID)
        guard !artifacts.isEmpty else { throw GitHubError.noArtifacts(runID: runID) }

        let live = artifacts.filter { !$0.expired }
        guard !live.isEmpty else {
            throw GitHubError.artifactsExpired(runID: runID, name: artifacts[0].name)
        }

        let chosen = live.sorted { lhs, rhs in
            let lFirmware = lhs.name.localizedCaseInsensitiveContains("firmware")
            let rFirmware = rhs.name.localizedCaseInsensitiveContains("firmware")
            if lFirmware != rFirmware { return lFirmware }
            return lhs.createdAt > rhs.createdAt
        }[0]

        // `gh run download` refuses to overwrite a file it already extracted,
        // so downloading the same run twice fails with "file exists". The
        // directory is ours to own for the duration of the download: empty it
        // and start clean. A missing directory is the normal case, not an error.
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await gh([
            "run", "download", String(runID),
            "-R", slug,
            "-n", chosen.name,
            "-D", directory.path,
        ])

        let unpacked = filesRecursively(in: directory)
        let firmware = unpacked.filter { $0.pathExtension.lowercased() == "uf2" }
        guard !firmware.isEmpty else {
            throw GitHubError.noFirmwareInArtifact(
                name: chosen.name,
                found: unpacked.map(\.lastPathComponent).sorted()
            )
        }

        return BuildArtifact(name: chosen.name, files: Flasher.classify(firmware))
    }

    // MARK: Internals

    private func newestRun(headSHA: String) async throws -> WorkflowRun? {
        let result = try await gh(["api", "repos/\(slug)/actions/runs?head_sha=\(headSHA)&per_page=20"])
        let runs = try decodeRunList(result.stdout, command: "gh api actions/runs?head_sha=")
        return runs.max { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    private func artifacts(runID: Int) async throws -> [ArtifactDTO] {
        let result = try await gh(["api", "repos/\(slug)/actions/runs/\(runID)/artifacts?per_page=100"])
        let list: ArtifactListDTO = try decode(result.stdout, command: "gh api actions/runs/\(runID)/artifacts")
        return list.artifacts
    }

    private func filesRecursively(in directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return walker.compactMap { entry in
            guard let url = entry as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return nil }
            return url
        }
    }

    // MARK: Process plumbing

    /// Runs `gh`, mapping its failure modes onto ``GitHubError``.
    private func gh(_ arguments: [String]) async throws -> ShellResult {
        let result = try await Shell.run(
            Self.executable, arguments, environment: ["PATH": Self.searchPath]
        )
        guard result.ok else {
            let detail = result.failureDetail
            let command = "gh " + arguments.joined(separator: " ")

            if result.status == 127 { throw GitHubError.ghNotFound }
            if detail.localizedCaseInsensitiveContains("gh auth login")
                || detail.localizedCaseInsensitiveContains("authentication required")
                || detail.localizedCaseInsensitiveContains("requires authentication") {
                throw GitHubError.notAuthenticated(detail: detail)
            }
            throw GitHubError.commandFailed(command: command, detail: detail)
        }
        return result
    }

    /// Locations to look for `gh`, in order.
    ///
    /// A `.app` launched from Finder inherits only `/usr/bin:/bin:/usr/sbin:/sbin`,
    /// so a bare `gh` lookup finds nothing on a normal Homebrew install.
    private static let candidatePaths = [
        "/opt/homebrew/bin/gh",     // Homebrew, Apple silicon
        "/usr/local/bin/gh",        // Homebrew, Intel
        "/opt/local/bin/gh",        // MacPorts
        "/run/current-system/sw/bin/gh",  // Nix
        "/usr/bin/gh",
    ]

    /// PATH handed to `gh` so its own helpers (`git`, credential tools) resolve.
    private static let searchPath = (
        ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        + [ProcessInfo.processInfo.environment["PATH"] ?? ""]
    ).filter { !$0.isEmpty }.joined(separator: ":")

    /// Where `gh` is, resolved once for the whole process.
    ///
    /// Process-wide rather than per-instance because callers construct a fresh
    /// client per operation; an instance cache would re-`stat` the candidates on
    /// every call and never be read twice. Nothing it depends on — the installed
    /// binary, the override in the environment — changes while the app runs.
    /// `static let` is initialised lazily and exactly once, so this stays a
    /// first-use cost.
    private static let executable: String = {
        let manager = FileManager.default
        var candidates = candidatePaths
        if let override = ProcessInfo.processInfo.environment["ZMKONFIG_GH_PATH"], !override.isEmpty {
            candidates.insert(override, at: 0)
        }

        // Last resort: `Shell.run` execs through /usr/bin/env, so a bare name
        // still resolves against the ambient PATH — which may know, if the app
        // was launched from a shell with gh somewhere unusual.
        return candidates.first(where: { manager.isExecutableFile(atPath: $0) }) ?? "gh"
    }()

    // MARK: Decoding

    private func decodeRunList(_ json: String, command: String) throws -> [WorkflowRun] {
        let list: RunListDTO = try decode(json, command: command)
        return list.workflowRuns.map(\.model)
    }

    private func decode<T: Decodable>(_ json: String, command: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw GitHubError.malformedResponse(command: command, detail: "response was not UTF-8")
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw GitHubError.malformedResponse(command: command, detail: "\(error)")
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // ISO8601FormatStyle is a Sendable value type, unlike the older
        // ISO8601DateFormatter, and parses every shape the API returns:
        // trailing Z or a numeric offset, with or without fractional seconds.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = try? Date(text, strategy: .iso8601) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "expected an ISO-8601 timestamp, got \"\(text)\""
                ))
            }
            return date
        }
        return decoder
    }()
}

// MARK: - Wire types

private struct RunListDTO: Decodable {
    let workflowRuns: [RunDTO]
}

private struct RunDTO: Decodable {
    let id: Int
    let status: String?
    let conclusion: String?
    let htmlUrl: String
    let createdAt: Date
    let displayTitle: String?
    let headSha: String

    var model: WorkflowRun {
        WorkflowRun(
            id: id,
            status: status ?? "queued",
            conclusion: conclusion,
            htmlURL: htmlUrl,
            createdAt: createdAt,
            displayTitle: displayTitle ?? "",
            headSHA: headSha
        )
    }
}

private struct ArtifactListDTO: Decodable {
    let artifacts: [ArtifactDTO]
}

private struct ArtifactDTO: Decodable {
    let name: String
    let expired: Bool
    let createdAt: Date
}

// MARK: - Helpers

private extension Duration {
    /// "45s" / "2m 30s" — for error text.
    var humanReadable: String {
        let total = components.seconds
        guard total >= 60 else { return "\(total)s" }
        let minutes = total / 60
        let seconds = total % 60
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }
}
