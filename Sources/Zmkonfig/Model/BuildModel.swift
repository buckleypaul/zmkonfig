import Foundation
import Observation
import ZmkonfigKit

/// The build + flash side of the app: watching a GitHub Actions run, pulling
/// its artifacts down, and copying firmware onto a mounted bootloader volume.
@MainActor
@Observable
final class BuildModel {
    enum Phase: Equatable {
        case idle
        case dispatching
        case watching
        case downloading
        case ready
        case failed
    }

    struct FlashRequest: Identifiable {
        let id = UUID()
        let image: FirmwareImage
        let volume: BootloaderVolume
    }

    static let defaultWorkflow = "build.yml"
    /// GitHub-hosted ZMK builds take a few minutes; allow for a queue.
    static let runTimeout: Duration = .seconds(30 * 60)

    private(set) var phase: Phase = .idle
    private(set) var statusLine = "No build has been watched yet."
    private(set) var run: WorkflowRun?
    private(set) var recentRuns: [WorkflowRun] = []
    private(set) var artifactName: String?
    private(set) var images: [FirmwareImage] = []
    private(set) var volumes: [BootloaderVolume] = []
    private(set) var flashingImageID: FirmwareImage.ID?
    private(set) var flashLog: [String] = []

    var pendingFlash: FlashRequest?
    var error: AppError?

    private var watchTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?

    var isBusy: Bool {
        phase == .dispatching || phase == .watching || phase == .downloading
    }

    // MARK: - Bootloader volumes

    func startMonitoringVolumes() {
        guard volumeTask == nil else { return }
        // No eager scan: `volumeStream` yields the currently mounted set as its
        // first element, and scanning here as well walked every mounted volume
        // twice on the main thread.
        volumeTask = Task { [weak self] in
            for await mounted in Flasher.volumeStream() {
                guard let self else { return }
                self.volumes = mounted
            }
        }
    }

    // MARK: - Runs

    func dispatch(slug: String, ref: String, workflow: String = BuildModel.defaultWorkflow) async {
        phase = .dispatching
        statusLine = "Dispatching \(workflow) on \(ref)…"
        do {
            try await GitHubClient(slug: slug).dispatchBuild(ref: ref, workflow: workflow)
            statusLine = "Dispatched \(workflow) on \(ref)."
            phase = .idle
            await loadRecentRuns(slug: slug)
        } catch {
            fail("Could not dispatch the build", error)
        }
    }

    func loadRecentRuns(slug: String, limit: Int = 10) async {
        do {
            recentRuns = try await GitHubClient(slug: slug).recentRuns(limit: limit)
        } catch {
            fail("Could not list workflow runs", error)
        }
    }

    /// Watches for the run belonging to `headSHA`, then downloads its artifacts
    /// if it succeeded.
    func watch(slug: String, headSHA: String) {
        watchTask?.cancel()
        phase = .watching
        run = nil
        images = []
        artifactName = nil
        statusLine = "Waiting for a workflow run for \(headSHA.abbreviatedSHA)…"

        let client = GitHubClient(slug: slug)
        watchTask = Task { [weak self] in
            do {
                let finished = try await client.waitForRun(headSHA: headSHA, timeout: Self.runTimeout) { update in
                    Task { @MainActor in self?.observe(update) }
                }
                guard let self, !Task.isCancelled else { return }
                self.observe(finished)
                if finished.succeeded {
                    await self.download(run: finished, client: client)
                } else {
                    self.phase = .failed
                    self.statusLine = "Build \(finished.conclusion ?? finished.status). Nothing was downloaded."
                }
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.fail("Waiting for the build failed", error)
            }
        }
    }

    func cancelWatching() {
        watchTask?.cancel()
        watchTask = nil
        if phase == .watching || phase == .downloading {
            phase = .idle
            statusLine = "Stopped watching. The build itself is still running on GitHub."
        }
    }

    private func observe(_ update: WorkflowRun) {
        run = update
        if update.isComplete {
            statusLine = "\(update.displayTitle) — \(update.conclusion ?? "complete")"
        } else {
            statusLine = "\(update.displayTitle) — \(update.status)…"
        }
    }

    private func download(run finished: WorkflowRun, client: GitHubClient) async {
        phase = .downloading
        statusLine = "Downloading artifacts for run \(finished.id)…"
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("zmkonfig/artifacts/\(finished.id)", isDirectory: true)
            let artifact = try await client.downloadArtifacts(runID: finished.id, to: directory)
            artifactName = artifact.name
            // Already classified by `downloadArtifacts`, which throws rather
            // than return an artifact with no firmware in it.
            images = artifact.files
            phase = .ready
            statusLine = "\(images.count) firmware image(s) from \"\(artifact.name)\"."
        } catch {
            fail("Could not download build artifacts", error)
        }
    }

    /// Loads artifacts for a run the user picked from the recent list.
    func useRun(_ finished: WorkflowRun, slug: String) async {
        run = finished
        guard finished.succeeded else {
            phase = .failed
            statusLine = "Run \(finished.id) \(finished.conclusion ?? finished.status) — no artifacts to download."
            return
        }
        await download(run: finished, client: GitHubClient(slug: slug))
    }

    // MARK: - Flashing

    func requestFlash(image: FirmwareImage, volume: BootloaderVolume) {
        pendingFlash = FlashRequest(image: image, volume: volume)
    }

    func performFlash(_ request: FlashRequest) async {
        flashingImageID = request.image.id
        defer { flashingImageID = nil }
        let name = request.image.url.lastPathComponent
        do {
            try await Flasher.flash(request.image, to: request.volume)
            flashLog.append("Flashed \(name) → \(request.volume.name)")
        } catch {
            flashLog.append("FAILED \(name) → \(request.volume.name): \(AppError.describe(error))")
            fail("Flashing \(name) failed", error)
        }
    }

    // MARK: - Helpers

    private func fail(_ title: String, _ error: any Error) {
        phase = .failed
        statusLine = "\(title): \(AppError.describe(error))"
        self.error = AppError(title: title, error: error)
    }

}
