import SwiftUI
import ZmkonfigKit

/// Watch a GitHub Actions build, pull the firmware down, and copy it onto a
/// bootloader volume — with the left/right choice made explicit every time.
struct BuildPanelView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @Bindable var build: BuildModel

    /// firmware image id → bootloader volume id
    @State private var targets: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metric(.spacingM)) {
                if model.repo == nil {
                    Hint(text: "Open a repository first.")
                } else {
                    runCard
                    recentRunsCard
                    firmwareCard
                    volumesCard
                    logCard
                }
            }
            .padding(theme.metric(.spacingM))
        }
        .task { build.startMonitoringVolumes() }
        .alert(
            flashTitle,
            isPresented: Binding(
                get: { build.pendingFlash != nil },
                set: { if !$0 { build.pendingFlash = nil } }
            ),
            presenting: build.pendingFlash
        ) { request in
            Button("Cancel", role: .cancel) { build.pendingFlash = nil }
            Button("Flash \(halfName(request.image))", role: .destructive) {
                let pending = request
                build.pendingFlash = nil
                Task { await build.performFlash(pending) }
            }
        } message: { request in
            Text("""
            Copy \(request.image.url.lastPathComponent) onto "\(request.volume.name)" \
            (\(request.volume.url.path)).

            This is the \(halfName(request.image).uppercased()) firmware. Make sure the half \
            currently in bootloader mode is the \(halfName(request.image)) one — flashing the \
            wrong half leaves it unusable until you reflash it.
            """)
        }
    }

    // MARK: - Build status

    private var runCard: some View {
        Card {
            VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                SectionLabel(text: "Build")

                HStack(spacing: theme.metric(.spacingS)) {
                    if build.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        StatusDot(color: statusColor)
                    }
                    Caption(build.statusLine)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let run = build.run {
                    HStack(spacing: theme.metric(.spacingS)) {
                        Badge(text: run.conclusion ?? run.status, tint: runTint(run))
                        Text(run.shortSHA)
                            .font(theme.font(.monoSmall))
                            .foregroundStyle(theme.color(.tertiaryText))
                        if let url = URL(string: run.htmlURL) {
                            Link("View on GitHub", destination: url)
                                .font(theme.font(.caption))
                        }
                    }
                }

                HStack(spacing: theme.metric(.spacingS)) {
                    Button("Watch HEAD") {
                        Task {
                            guard let slug = model.repo?.slug, let sha = await model.headSHA() else { return }
                            build.watch(slug: slug, headSHA: sha)
                        }
                    }
                    .disabled(build.isBusy)

                    Button("Dispatch") {
                        Task {
                            guard let slug = model.repo?.slug,
                                  let branch = await model.currentBranch() else { return }
                            await build.dispatch(slug: slug, ref: branch)
                        }
                    }
                    .disabled(build.isBusy)
                    .help("Trigger \(BuildModel.defaultWorkflow) on the current branch")

                    if build.isBusy {
                        Button("Stop") { build.cancelWatching() }
                    }
                }
                .font(theme.font(.caption))
            }
        }
    }

    private var statusColor: Color {
        switch build.phase {
        case .ready: theme.color(.success)
        case .failed: theme.color(.danger)
        default: theme.color(.tertiaryText)
        }
    }

    private func runTint(_ run: WorkflowRun) -> Color {
        guard run.isComplete else { return theme.color(.warning) }
        return run.succeeded ? theme.color(.success) : theme.color(.danger)
    }

    // MARK: - Recent runs

    @ViewBuilder
    private var recentRunsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                HStack {
                    SectionLabel(text: "Recent runs")
                    Spacer()
                    Button("Refresh") {
                        Task {
                            guard let slug = model.repo?.slug else { return }
                            await build.loadRecentRuns(slug: slug)
                        }
                    }
                    .font(theme.font(.caption))
                }

                if build.recentRuns.isEmpty {
                    Caption("None loaded.", tone: .tertiaryText)
                } else {
                    ForEach(build.recentRuns) { run in
                        Button {
                            Task {
                                guard let slug = model.repo?.slug else { return }
                                await build.useRun(run, slug: slug)
                            }
                        } label: {
                            HStack(spacing: theme.metric(.spacingS)) {
                                StatusDot(color: runTint(run))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(run.displayTitle)
                                        .font(theme.font(.caption))
                                        .foregroundStyle(theme.color(.primaryText))
                                        .lineLimit(1)
                                    Caption("\(run.shortSHA) · \(run.createdAt.formatted(date: .abbreviated, time: .shortened))", tone: .tertiaryText)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Download this run's artifacts")
                    }
                }
            }
        }
    }

    // MARK: - Firmware

    private var firmwareCard: some View {
        Card {
            VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                SectionLabel(text: "Firmware")
                if let name = build.artifactName {
                    Text(name)
                        .font(theme.font(.monoSmall))
                        .foregroundStyle(theme.color(.secondaryText))
                }
                if build.images.isEmpty {
                    Caption("No firmware downloaded yet.", tone: .tertiaryText)
                } else {
                    ForEach(build.images) { image in
                        firmwareRow(image)
                    }
                }
            }
        }
    }

    private func firmwareRow(_ image: FirmwareImage) -> some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
            HStack(spacing: theme.metric(.spacingS)) {
                Badge(text: halfName(image).uppercased(), tint: halfTint(image))
                Text(image.url.lastPathComponent)
                    .font(theme.font(.monoSmall))
                    .foregroundStyle(theme.color(.primaryText))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: theme.metric(.spacingS)) {
                Picker("Volume", selection: volumeBinding(for: image)) {
                    Text("Choose a volume…").tag("")
                    ForEach(build.volumes) { volume in
                        Text(volume.name).tag(volume.id)
                    }
                }
                .labelsHidden()
                .disabled(build.volumes.isEmpty)

                Button("Flash…") {
                    guard let volume = selectedVolume(for: image) else { return }
                    build.requestFlash(image: image, volume: volume)
                }
                .disabled(selectedVolume(for: image) == nil || build.flashingImageID != nil)

                if build.flashingImageID == image.id {
                    ProgressView().controlSize(.small)
                }
            }
            .font(theme.font(.caption))

            if image.half == nil {
                Text("This file's half could not be determined from its name — check it before flashing.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.color(.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, theme.metric(.spacingXS))
    }

    /// The volume this image is aimed at: whatever was picked, or the only
    /// mounted one when there is exactly one. Empty when nothing is chosen.
    ///
    /// The picker and the Flash button both read this. Written out twice they
    /// disagreed about that default, so the picker could show a volume the
    /// button treated as no selection at all.
    private func targetID(for image: FirmwareImage) -> String {
        targets[image.id] ?? (build.volumes.count == 1 ? build.volumes[0].id : "")
    }

    private func volumeBinding(for image: FirmwareImage) -> Binding<String> {
        Binding(
            get: { targetID(for: image) },
            set: { targets[image.id] = $0 }
        )
    }

    private func selectedVolume(for image: FirmwareImage) -> BootloaderVolume? {
        let id = targetID(for: image)
        return build.volumes.first { $0.id == id }
    }

    private func halfName(_ image: FirmwareImage) -> String {
        image.half?.rawValue ?? "unknown half"
    }

    private func halfTint(_ image: FirmwareImage) -> Color {
        switch image.half {
        case .left: theme.color(.accent)
        case .right: theme.color(.success)
        case nil: theme.color(.warning)
        }
    }

    private var flashTitle: String {
        guard let pending = build.pendingFlash else { return "Flash firmware?" }
        return "Flash the \(halfName(pending.image)) half?"
    }

    // MARK: - Volumes and log

    private var volumesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                SectionLabel(text: "Bootloader volumes")
                if build.volumes.isEmpty {
                    Caption("None mounted. Double-tap the reset button on one half to put it into bootloader mode.", tone: .tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(build.volumes) { volume in
                        HStack(spacing: theme.metric(.spacingS)) {
                            StatusDot(color: theme.color(.success))
                            Text(volume.name)
                                .font(theme.font(.body))
                                .foregroundStyle(theme.color(.primaryText))
                            Caption(volume.url.path, tone: .tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var logCard: some View {
        if !build.flashLog.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                    SectionLabel(text: "Flash log")
                    ForEach(Array(build.flashLog.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(theme.font(.monoSmall))
                            .foregroundStyle(entry.hasPrefix("FAILED")
                                             ? theme.color(.danger)
                                             : theme.color(.secondaryText))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
