import AppKit
import Foundation

// MARK: - Models

/// A mounted UF2 bootloader volume — a keyboard half waiting to be flashed.
public struct BootloaderVolume: Sendable, Identifiable, Equatable {
    public var id: String { url.path }
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

public enum KeyboardHalf: String, Sendable, CaseIterable {
    case left
    case right
}

/// A `.uf2` file ready to be copied onto a bootloader volume.
public struct FirmwareImage: Sendable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    /// Inferred from the filename; nil when the name says neither or both.
    public let half: KeyboardHalf?

    public init(url: URL, half: KeyboardHalf?) {
        self.url = url
        self.half = half
    }
}

// MARK: - Errors

public enum FlashError: Error, CustomStringConvertible, Sendable {
    case imageMissing(URL)
    case notAUF2File(URL)
    case volumeUnavailable(BootloaderVolume)
    case volumeNotWritable(BootloaderVolume)
    case copyFailed(image: String, volume: String, detail: String)

    public var description: String {
        switch self {
        case .imageMissing(let url):
            return "Firmware file not found at \(url.path)."
        case .notAUF2File(let url):
            return """
                \(url.lastPathComponent) is not a UF2 file — it is missing the UF2 magic header. \
                Copying it to the keyboard would do nothing.
                """
        case .volumeUnavailable(let volume):
            return "\(volume.name) is no longer mounted. Put the board back into bootloader mode and retry."
        case .volumeNotWritable(let volume):
            return "\(volume.name) is mounted read-only, so the firmware cannot be copied to it."
        case .copyFailed(let image, let volume, let detail):
            return "Could not copy \(image) to \(volume): \(detail)"
        }
    }
}

// MARK: - Flasher

/// Finds UF2 bootloader volumes and copies firmware onto them.
///
/// Stateless and entirely static, like `Shell` — a namespace, not something to
/// instantiate.
public enum Flasher {

    /// Volume names that identify a UF2 bootloader when `INFO_UF2.TXT` cannot
    /// be read — most of the boards ZMK supports.
    private static let knownBootloaderNames: Set<String> = [
        "NICENANO",     // nice!nano v1/v2
        "NRF52BOOT",    // generic Adafruit nRF52 bootloader
        "XIAO-SENSE",   // Seeed XIAO nRF52840
        "ADAFRUIT",     // Adafruit boards, various
        "FTHR840BOOT",  // Feather nRF52840 Express
        "NRFMICRO",     // nrfmicro
        "PUCHI-BOOT",   // Puchi-BLE
        "RPI-RP2",      // RP2040 boards
        "BLUEMICRO",    // BlueMicro840
    ]

    private static let infoFileName = "INFO_UF2.TXT"

    /// First four bytes of every UF2 file: "UF2\n".
    private static let uf2Magic: [UInt8] = [0x55, 0x46, 0x32, 0x0A]

    // MARK: Detection

    /// Every currently mounted UF2 bootloader volume.
    ///
    /// A volume qualifies if it holds an `INFO_UF2.TXT` at its root — the file
    /// every UF2 bootloader publishes. Its name is only a fallback, for the
    /// brief window after mount where the directory is not yet readable.
    public static func mountedBootloaderVolumes() -> [BootloaderVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsRootFileSystemKey,
            .volumeIsBrowsableKey,
        ]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return mounted.compactMap { url -> BootloaderVolume? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Never offer the startup disk as a flash target.
            if values?.volumeIsRootFileSystem == true { return nil }
            if values?.volumeIsBrowsable == false { return nil }

            let name = values?.volumeName ?? url.lastPathComponent
            guard isBootloader(url: url, name: name) else { return nil }
            return BootloaderVolume(name: name, url: url)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func isBootloader(url: URL, name: String) -> Bool {
        // Cheap exact-case check first: FAT bootloaders always spell it this way.
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(infoFileName).path) {
            return true
        }
        // A recognised bootloader name stands on its own, covering the window
        // right after mount where the root directory is not yet readable.
        if matchesKnownName(name) { return true }
        // Unknown name: only accept it if a case-variant INFO_UF2.TXT is there.
        return containsInfoFile(url)
    }

    private static func matchesKnownName(_ name: String) -> Bool {
        // Trim the " 1" macOS appends when a second board of the same name mounts.
        let base = name
            .split(separator: " ")
            .first
            .map(String.init) ?? name
        let upper = base.uppercased()
        if knownBootloaderNames.contains(upper) { return true }
        return upper.hasSuffix("BOOT") || upper.contains("UF2")
    }

    private static func containsInfoFile(_ url: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return entries.contains { $0.uppercased() == infoFileName }
    }

    // MARK: Classification

    /// Turns a set of downloaded files into firmware images, dropping anything
    /// that is not a `.uf2`, and ordering them left, right, then unknown.
    public static func classify(_ files: [URL]) -> [FirmwareImage] {
        files
            .filter { $0.pathExtension.lowercased() == "uf2" }
            .map { FirmwareImage(url: $0, half: half(forFilename: $0.lastPathComponent)) }
            .sorted { lhs, rhs in
                let lRank = rank(lhs.half)
                let rRank = rank(rhs.half)
                if lRank != rRank { return lRank < rRank }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
                    == .orderedAscending
            }
    }

    private static func rank(_ half: KeyboardHalf?) -> Int {
        switch half {
        case .left: return 0
        case .right: return 1
        case nil: return 2
        }
    }

    /// nil when the name mentions neither half, or mentions both.
    private static func half(forFilename filename: String) -> KeyboardHalf? {
        let lowered = filename.lowercased()
        let isLeft = lowered.contains("left")
        let isRight = lowered.contains("right")
        // "right" does not contain "left", so both matching means a genuinely
        // ambiguous name rather than a substring accident.
        guard isLeft != isRight else { return nil }
        return isLeft ? .left : .right
    }

    // MARK: Flashing

    /// Copies `image` onto `volume`.
    ///
    /// The board reboots the instant it has taken the whole image, which
    /// unmounts the volume out from under the copy. A write, flush, or close
    /// that fails *after* the volume has gone is therefore the success case,
    /// not an error — the only true failures are ones where the volume is still
    /// sitting there mounted.
    public static func flash(_ image: FirmwareImage, to volume: BootloaderVolume) async throws {
        let manager = FileManager.default

        guard manager.isReadableFile(atPath: image.url.path) else {
            throw FlashError.imageMissing(image.url)
        }
        let payload = try readValidatedUF2(at: image.url)

        guard manager.fileExists(atPath: volume.url.path) else {
            throw FlashError.volumeUnavailable(volume)
        }
        guard manager.isWritableFile(atPath: volume.url.path) else {
            throw FlashError.volumeNotWritable(volume)
        }

        let destination = volume.url.appendingPathComponent(image.url.lastPathComponent)

        guard manager.createFile(atPath: destination.path, contents: nil) else {
            // Creating the file can fail because the board vanished between the
            // check above and now — unlikely this early, but possible.
            if await volumeHasGone(volume) { return }
            throw FlashError.copyFailed(
                image: image.url.lastPathComponent,
                volume: volume.name,
                detail: "could not create the destination file"
            )
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            if await volumeHasGone(volume) { return }
            throw FlashError.copyFailed(
                image: image.url.lastPathComponent,
                volume: volume.name,
                detail: error.localizedDescription
            )
        }

        // 64 KiB keeps the mass-storage writes flowing without loading the
        // whole transfer into one syscall.
        let chunkSize = 64 * 1024
        var offset = 0
        do {
            while offset < payload.count {
                try Task.checkCancellation()
                let end = min(offset + chunkSize, payload.count)
                try handle.write(contentsOf: payload[offset..<end])
                offset = end
            }
            try handle.synchronize()
            try handle.close()
        } catch is CancellationError {
            try? handle.close()
            throw CancellationError()
        } catch {
            try? handle.close()
            // The expected ending: the board took the image and rebooted.
            if await volumeHasGone(volume) { return }
            throw FlashError.copyFailed(
                image: image.url.lastPathComponent,
                volume: volume.name,
                detail: error.localizedDescription
            )
        }
    }

    private static func readValidatedUF2(at url: URL) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw FlashError.imageMissing(url)
        }
        guard data.count >= uf2Magic.count, Array(data.prefix(uf2Magic.count)) == uf2Magic else {
            throw FlashError.notAUF2File(url)
        }
        return data
    }

    /// Whether the volume has unmounted, allowing a moment for the kernel to
    /// finish tearing the mount down — it lags the I/O error by a beat.
    private static func volumeHasGone(_ volume: BootloaderVolume) async -> Bool {
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(400)) }
            let stillListed = FileManager.default
                .mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])?
                .contains { $0.path == volume.url.path } ?? false
            if !stillListed { return true }
            if !FileManager.default.fileExists(atPath: volume.url.path) { return true }
        }
        return false
    }

    // MARK: Volume monitoring

    /// Emits the bootloader-volume set on every mount and unmount.
    ///
    /// The current set arrives immediately, then a new one each time it
    /// actually changes — mounts of unrelated disks are filtered out rather
    /// than passed through as redundant updates.
    ///
    /// No scan runs on the main thread. Each one `stat`s every mounted volume
    /// and lists the directory of any it does not recognise, so a stale network
    /// mount can block it for as long as the kernel takes to give up; on main
    /// that is a frozen window. The observers deliver onto a background queue
    /// and the first scan is detached, so only the consumer's assignment
    /// re-enters the main actor.
    public static func volumeStream() -> AsyncStream<[BootloaderVolume]> {
        AsyncStream { continuation in
            let state = StreamState()
            let center = NSWorkspace.shared.notificationCenter

            let scans = OperationQueue()
            scans.name = "com.buckleypaul.zmkonfig.volume-scan"
            // Serial: two scans racing would emit in whichever order they
            // finished, and the change filter would then see the older set as a
            // change back.
            scans.maxConcurrentOperationCount = 1

            @Sendable func emit() {
                let volumes = mountedBootloaderVolumes()
                if state.shouldEmit(volumes) { continuation.yield(volumes) }
            }

            let handler: @Sendable (Notification) -> Void = { note in
                emit()
                // A volume's root directory can still be unreadable the instant
                // it mounts, which hides INFO_UF2.TXT from the scan above. Look
                // again shortly after; the change filter drops the duplicate
                // when the first scan already saw everything.
                if note.name == NSWorkspace.didMountNotification {
                    state.scheduleRecheck(after: .milliseconds(750), emit)
                }
            }

            state.tokens = [
                center.addObserver(
                    forName: NSWorkspace.didMountNotification,
                    object: nil,
                    queue: scans,
                    using: handler
                ),
                center.addObserver(
                    forName: NSWorkspace.didUnmountNotification,
                    object: nil,
                    queue: scans,
                    using: handler
                ),
            ]

            continuation.onTermination = { _ in
                for token in state.tokens { center.removeObserver(token) }
                state.tokens = []
                state.cancelRecheck()
            }

            // Detached so the first scan does not inherit the main actor from
            // whoever started the stream. The consumer still sees it first:
            // an AsyncStream buffers, so nothing is lost by it arriving a
            // moment later than the call.
            Task.detached {
                let initial = mountedBootloaderVolumes()
                if state.shouldEmit(initial) { continuation.yield(initial) }
            }
        }
    }

    /// Holds the observer tokens and the last emitted set so the stream can
    /// suppress no-op updates. Locked because the initial emission happens on
    /// the caller's thread and later ones on the main queue.
    private final class StreamState: @unchecked Sendable {
        private let lock = NSLock()
        private var lastEmitted: [BootloaderVolume]?
        private var storedTokens: [NSObjectProtocol] = []
        private var recheck: Task<Void, Never>?

        var tokens: [NSObjectProtocol] {
            get { lock.withLock { storedTokens } }
            set { lock.withLock { storedTokens = newValue } }
        }

        func shouldEmit(_ volumes: [BootloaderVolume]) -> Bool {
            lock.withLock {
                guard lastEmitted != volumes else { return false }
                lastEmitted = volumes
                return true
            }
        }

        func scheduleRecheck(after delay: Duration, _ body: @escaping @Sendable () -> Void) {
            let task = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                body()
            }
            lock.withLock {
                recheck?.cancel()
                recheck = task
            }
        }

        func cancelRecheck() {
            lock.withLock {
                recheck?.cancel()
                recheck = nil
            }
        }
    }
}
