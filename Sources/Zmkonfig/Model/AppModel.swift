import Foundation
import Observation
import ZmkonfigKit

/// What the sidebar has selected: one layer to draw, or one combo to edit.
enum SidebarSelection: Hashable {
    case layer(Int)
    case combo(KeymapCombo.ID)
}

/// Everything the editor side of the app needs: the open repo, its keymap, the
/// keyboard layout it is drawn with, and the current selection.
@MainActor
@Observable
final class AppModel {
    /// The slug opened last, reopened on the next launch. There is no built-in
    /// default repo — the first launch opens nothing and waits for the sheet.
    static let lastSlugKey = "lastRepoSlug"
    /// Used when the repo ships no `config/info.json` of its own.
    static let fallbackKeyboardID = "cradio"

    // Repo
    private(set) var repo: ZmkRepo?
    private(set) var git: Git?
    private(set) var gitStatus: GitStatus?

    // Keymap + layout
    private(set) var keymap: KeymapFile?
    private(set) var keyboard: KeyboardDefinition?
    var layoutKey: String? {
        didSet { if layoutKey != oldValue { refreshComboProblems() } }
    }
    private(set) var hasUnsavedEdits = false

    // Metadata
    private(set) var behaviors: [ZMKBehavior] = []
    private(set) var keycodes: [ZMKKeycode] = []
    /// The behavior index: the stock ZMK behaviors plus the ones this keymap
    /// defines for itself, rebuilt when either changes.
    ///
    /// The dictionary is the one thing assigned; the sorted list follows from
    /// it. They used to be two properties written in lockstep, with nothing
    /// stopping a third writer setting one and forgetting the other. Both are
    /// stored because both are read on every render — the picker's `ForEach`
    /// wants the list and every drawn key looks a code up — and neither wants
    /// re-deriving per read.
    private(set) var behaviorsByCode: [String: ZMKBehavior] = [:] {
        didSet {
            availableBehaviors = behaviorsByCode.values
                .sorted { $0.code.localizedCaseInsensitiveCompare($1.code) == .orderedAscending }
        }
    }
    private(set) var availableBehaviors: [ZMKBehavior] = []
    private(set) var catalog: [CatalogEntry] = []
    private(set) var isLoadingCatalog = false

    // Selection
    /// What the sidebar has picked. A combo stays selected while the board goes
    /// on showing a layer, because picking a combo's key positions means
    /// clicking keys on a layer.
    var sidebarSelection: SidebarSelection? {
        didSet {
            guard sidebarSelection != oldValue else { return }
            selectedKeyIndex = nil
            if case .layer(let id) = sidebarSelection { selectedLayerID = id }
        }
    }
    private(set) var selectedLayerID: Int?
    var selectedKeyIndex: Int?

    /// The board highlights the selected combo's chord, and nothing otherwise.
    /// Derived rather than stored: six sites used to keep a stored copy in step
    /// with the selection, and a missed one showed a stale chord.
    var highlightedPositions: Set<Int> { Set(selectedCombo?.keyPositions ?? []) }

    // Chrome
    var busyMessage: String?
    var error: AppError?
    var notice: String?
    var isShowingRepoSheet = false
    var isShowingCatalogSheet = false
    var isShowingSaveSheet = false
    var pendingDiff: String = ""

    // MARK: - Derived

    var layers: [KeymapLayer] { keymap?.layers ?? [] }

    var combos: [KeymapCombo] { keymap?.combos ?? [] }

    var selectedLayerIndex: Int? {
        guard let selectedLayerID else { return nil }
        return layers.firstIndex { $0.id == selectedLayerID }
    }

    var selectedLayer: KeymapLayer? {
        selectedLayerIndex.map { layers[$0] }
    }

    var layoutVariant: LayoutVariant? {
        guard let keyboard else { return nil }
        if let layoutKey, let named = keyboard.layouts[layoutKey] { return named }
        return keyboard.defaultLayout
    }

    var layout: [KeyPosition] { layoutVariant?.layout ?? [] }

    var selectedBinding: KeyBinding? {
        guard let layer = selectedLayer, let index = selectedKeyIndex,
              layer.bindings.indices.contains(index) else { return nil }
        return layer.bindings[index]
    }

    var selectedComboID: KeymapCombo.ID? {
        if case .combo(let id) = sidebarSelection { return id }
        return nil
    }

    var selectedCombo: KeymapCombo? {
        guard let id = selectedComboID else { return nil }
        return combos.first { $0.id == id }
    }

    /// Everything about the combos that would stop the keymap being written.
    ///
    /// Recomputed only when the keymap or the layout changes, because the
    /// sidebar asks once per row: computing it on demand walked every combo
    /// against every anchor for each row, on every keystroke in a name field.
    private(set) var comboProblems: [ComboProblem] = []
    private var comboProblemsByID: [KeymapCombo.ID: [String]] = [:]

    func problems(for combo: KeymapCombo) -> [String] {
        comboProblemsByID[combo.id] ?? []
    }

    private func refreshComboProblems() {
        comboProblems = keymap?.comboProblems(positionCount: layout.count) ?? []
        comboProblemsByID = Dictionary(grouping: comboProblems, by: \.id)
            .mapValues { $0.map(\.message) }
    }

    func behavior(for code: String) -> ZMKBehavior? {
        behaviorsByCode[code]
    }

    /// False for behaviors the keymap defines itself, whose parameter kinds we
    /// can only guess at.
    func isDocumentedBehavior(_ code: String) -> Bool {
        behaviors.contains { $0.code == code }
    }

    // MARK: - The behavior index

    /// The 15 stock behaviors are only half the story: this keymap defines
    /// eight hold-taps of its own (`&hml`, `&hmr`, `&qt`, …) that metadata
    /// knows nothing about. Read them out of the parsed devicetree so they can
    /// be picked even on keys that do not already use them.
    private func rebuildBehaviorIndex() {
        var known = Dictionary(behaviors.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })

        for node in keymap?.document.allNodes() ?? [] {
            guard let label = node.label,
                  let compatible = node.compatible,
                  compatible.hasPrefix("zmk,behavior-")
            else { continue }
            let code = "&" + label
            guard known[code] == nil else { continue }
            known[code] = ZMKBehavior(
                code: code,
                name: node.name.replacingOccurrences(of: "_", with: " "),
                params: parameterKinds(of: node, stock: known)
            )
        }

        // A binding may still reference something we could not find a
        // definition for; infer its shape from how it is used.
        for binding in layers.flatMap(\.bindings) + combos.map(\.binding)
        where known[binding.behavior] == nil {
            known[binding.behavior] = ZMKBehavior(
                code: binding.behavior,
                name: String(binding.behavior.drop(while: { $0 == "&" })),
                params: binding.params.map { _ in .code }
            )
        }

        behaviorsByCode = known
    }

    /// A hold-tap declares its arity as `#binding-cells` and what each slot
    /// means through the behaviors it wraps: `bindings = <&mo>, <&tog>` is two
    /// layer slots, `<&kp>, <&kp>` is two keycodes.
    private func parameterKinds(of node: DTNode, stock: [String: ZMKBehavior]) -> [ParamKind] {
        var kinds = (node.property("bindings")?.value.cellTexts ?? []).map { cell -> ParamKind in
            let code = cell.split(separator: " ").first.map(String.init) ?? cell
            return stock[code]?.params?.first ?? .code
        }
        if let text = node.property("#binding-cells")?.value.cellTexts?.first, let cells = Int(text) {
            kinds = Array(kinds.prefix(cells))
            kinds.append(contentsOf: Array(repeating: ParamKind.code, count: max(0, cells - kinds.count)))
        }
        return kinds
    }

    /// The keymap path relative to the repo root, which is what `git diff`
    /// wants.
    var keymapRelativePath: String? {
        guard let repo else { return nil }
        let root = repo.localURL.standardizedFileURL.path
        let file = repo.keymapPath.standardizedFileURL.path
        guard file.hasPrefix(root + "/") else { return file }
        return String(file.dropFirst(root.count + 1))
    }

    /// True when the number of bindings in a layer does not match the number of
    /// key positions — usually the wrong layout is selected.
    var layoutMismatch: (bindings: Int, positions: Int)? {
        guard let layer = selectedLayer, !layout.isEmpty else { return nil }
        guard layer.bindings.count != layout.count else { return nil }
        return (layer.bindings.count, layout.count)
    }

    // MARK: - Loading

    /// Loads the metadata and opens the default repository at the same time.
    ///
    /// Nothing here depends on anything else here: only ``rebuildBehaviorIndex``
    /// needs both the metadata and the keymap, and it is called from each side
    /// as that side lands, so whichever finishes second builds the complete
    /// index. Run in series, decoding 366 metadata objects sat in front of a
    /// repo open that can itself wait on the network; overlapped, launch costs
    /// the slower of the two rather than their sum.
    func bootstrap() async {
        async let metadata: Void = loadMetadata()
        async let opened: Void = openLastRepo()
        _ = await (metadata, opened)
    }

    private func openLastRepo() async {
        guard repo == nil, let slug = UserDefaults.standard.string(forKey: Self.lastSlugKey) else { return }
        await openRepo(slug: slug)
    }

    /// Decodes the vendored metadata off the main actor. It is ~131 KB and 366
    /// objects through `JSONDecoder`, and it sat between launch and the first
    /// usable frame.
    private func loadMetadata() async {
        do {
            let loaded = try await Task.detached {
                (behaviors: try AppResources.loadBehaviors(), keycodes: try AppResources.loadKeycodes())
            }.value
            behaviors = loaded.behaviors
            keycodes = loaded.keycodes
            rebuildBehaviorIndex()
        } catch let failure {
            // `catch error` would shadow the `error` property this assigns to.
            self.error = AppError(title: "Could not load ZMK metadata", error: failure)
        }
    }

    func openRepo(slug: String) async {
        busyMessage = "Opening \(slug)…"
        defer { busyMessage = nil }
        do {
            let opened = try await RepoManager.shared.open(slug: slug)
            repo = opened
            git = Git(root: opened.localURL)
            repoHasCommits = nil
            keymap = nil
            keyboard = nil
            layoutKey = nil
            sidebarSelection = nil
            selectedLayerID = nil
            selectedKeyIndex = nil
            hasUnsavedEdits = false
            UserDefaults.standard.set(slug, forKey: Self.lastSlugKey)
            await loadKeymapAndLayout()
            await refreshStatus()
            awaitFetch(slug: slug)
        } catch {
            self.error = AppError(title: "Could not open \(slug)", error: error)
        }
    }

    /// `RepoManager.open` no longer waits on `git fetch`; it runs it in the
    /// background so the first frame does not wait on a network round trip. The
    /// status just read is therefore as stale as the last fetch, so wait for the
    /// fetch off to one side and read it again when it lands: the ahead/behind
    /// badge fills itself in a moment later.
    ///
    /// A failed fetch — an offline launch, most likely — leaves the status
    /// exactly as it is and says nothing. That is a deliberate exception to "no
    /// silent failures": the app has no non-fatal warning surface (`notice` is
    /// drawn in the success tone), and an alert on every offline launch would
    /// be noise about something that costs the user nothing but a stale badge.
    private func awaitFetch(slug: String) {
        Task { [weak self] in
            do {
                try await RepoManager.shared.fetch(slug: slug)
            } catch {
                return
            }
            guard let self, self.repo?.slug == slug else { return }
            await self.refreshStatus()
        }
    }

    func reloadKeymap() async {
        guard repo != nil else { return }
        busyMessage = "Reloading keymap…"
        defer { busyMessage = nil }
        await loadKeymapAndLayout()
        await refreshStatus()
    }

    private func loadKeymapAndLayout() async {
        guard let repo else { return }
        // Two independent loads: parsing the devicetree touches only the disk,
        // while the layout can be a fifteen-second network fetch on a cold
        // cache. Started together, waited on one after the other, so this costs
        // the slower rather than their sum. Each still reports its own failure
        // the way it did in series.
        //
        // Reading and parsing the whole devicetree is pure and `Sendable`; only
        // the assignment needs the main actor.
        let path = repo.keymapPath
        async let parsed = Task.detached { try KeymapFile(contentsOf: path) }.value
        async let definition = Self.keyboardDefinition(forRepoAt: repo.localURL)

        do {
            let file = try await parsed
            keymap = file
            hasUnsavedEdits = false
            rebuildBehaviorIndex()
            // Combo ids are minted fresh on every parse, so a reload cannot
            // keep one selected — fall back to the layer that was showing.
            let layerID = file.layers.contains { $0.id == selectedLayerID }
                ? selectedLayerID
                : file.layers.first?.id
            sidebarSelection = layerID.map { .layer($0) }
            selectedKeyIndex = nil
        } catch {
            keymap = nil
            self.error = AppError(title: "Could not read keymap", error: error)
        }

        do {
            keyboard = try await definition
            layoutKey = nil
        } catch {
            self.error = AppError(title: "Could not load keyboard layout", error: error)
        }

        refreshComboProblems()
    }

    /// The layout the repository declares, or the fallback when it declares
    /// none. `nonisolated` so ``loadKeymapAndLayout`` can start it alongside the
    /// keymap parse rather than after it.
    private nonisolated static func keyboardDefinition(forRepoAt root: URL) async throws
        -> KeyboardDefinition
    {
        if let fromRepo = try await LayoutCatalog.shared.definitionForRepo(root) { return fromRepo }
        return try await LayoutCatalog.shared.definition(id: fallbackKeyboardID)
    }

    func loadCatalog() async {
        guard catalog.isEmpty, !isLoadingCatalog else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            catalog = try await LayoutCatalog.shared.catalog()
        } catch {
            self.error = AppError(title: "Could not load keyboard catalog", error: error)
        }
    }

    func chooseKeyboard(id: String) async {
        busyMessage = "Loading \(id)…"
        defer { busyMessage = nil }
        do {
            keyboard = try await LayoutCatalog.shared.definition(id: id)
            layoutKey = nil
            // The layout decides which key positions a combo may name.
            refreshComboProblems()
        } catch {
            self.error = AppError(title: "Could not load keyboard \(id)", error: error)
        }
    }

    func refreshStatus() async {
        guard let git else { return }
        do {
            gitStatus = try await git.status()
        } catch {
            gitStatus = nil
            self.error = AppError(title: "git status failed", error: error)
        }
    }

    // MARK: - Editing

    /// A click on the board. While a combo is selected that means adding or
    /// removing one of its key positions rather than picking a key to edit.
    func selectKey(_ index: Int) {
        guard var combo = selectedCombo else {
            selectedKeyIndex = index
            return
        }
        if let existing = combo.keyPositions.firstIndex(of: index) {
            combo.keyPositions.remove(at: existing)
        } else {
            // Appended rather than sorted, so a combo the file already wrote
            // out of order stays that way and the diff stays small.
            combo.keyPositions.append(index)
        }
        updateCombo(combo)
    }

    func apply(_ binding: KeyBinding) {
        guard let layerIndex = selectedLayerIndex, let keyIndex = selectedKeyIndex else { return }
        edit("Could not change that key") {
            try $0.setBinding(layer: layerIndex, index: keyIndex, to: binding)
        }
    }

    /// Mutates the open keymap and records what that means: the file is dirty,
    /// and the last success notice is now stale.
    ///
    /// Every edit goes through here so a new consequence of editing is added
    /// once rather than in each mutator, and so a mutation that cannot be
    /// applied surfaces instead of silently dropping the user's change.
    ///
    /// It is also the app's only transaction: `change` works on a copy, and the
    /// copy is only assigned back once it has run clean through. A batch that
    /// throws half way leaves the keymap exactly as it was rather than in a
    /// state nobody asked for — which is what ``applyProposal(_:)`` relies on.
    /// The result says whether it landed, for the one caller that has to tell
    /// the user.
    @discardableResult
    private func edit(_ failureTitle: String, _ change: (inout KeymapFile) throws -> Void) -> Bool {
        guard var file = keymap else { return false }
        do {
            try change(&file)
        } catch {
            self.error = AppError(title: failureTitle, error: error)
            return false
        }
        keymap = file
        hasUnsavedEdits = true
        notice = nil
        refreshComboProblems()
        return true
    }

    // MARK: - Combos

    func updateCombo(_ combo: KeymapCombo) {
        edit("Could not update that combo") { $0.updateCombo(combo) }
    }

    /// Adds an empty combo and selects it, so the next click on the board
    /// starts filling in its key positions.
    func addCombo() {
        guard let file = keymap else { return }
        let combo = KeymapCombo(
            nodeName: file.uniqueComboName(startingFrom: "combo"),
            binding: KeyBinding(behavior: "&kp", params: [BindingParam(value: "ESC")]),
            keyPositions: []
        )
        edit("Could not add a combo") { $0.addCombo(combo) }
        sidebarSelection = .combo(combo.id)
    }

    func removeCombo(id: KeymapCombo.ID) {
        edit("Could not remove that combo") { $0.removeCombo(id: id) }
        if selectedComboID == id {
            sidebarSelection = selectedLayerID.map { .layer($0) }
        }
    }

    // MARK: - Saving

    /// Writes the keymap, then shows the resulting diff for review.
    func saveAndReview() async {
        notice = nil
        guard await writeKeymap() else { return }
        // Independent git reads; the sheet waits on the slower of the two
        // rather than on their sum.
        async let status: Void = refreshStatus()
        async let diff: Void = loadDiff()
        _ = await (status, diff)
        isShowingSaveSheet = true
    }

    @discardableResult
    private func writeKeymap() async -> Bool {
        guard let repo, let keymap else { return false }
        guard !layout.isEmpty else {
            error = AppError(
                title: "No layout loaded",
                message: "The keymap cannot be written without a keyboard layout to order the bindings by."
            )
            return false
        }
        busyMessage = "Writing keymap…"
        defer { busyMessage = nil }
        do {
            let data = try keymap.serialized(layout: layout)
            try data.write(to: repo.keymapPath, options: .atomic)
            hasUnsavedEdits = false
            return true
        } catch {
            self.error = AppError(title: "Could not write keymap", error: error)
            return false
        }
    }

    /// Whether the open repository has a HEAD to diff against, once it is
    /// known. See ``loadDiff()``.
    private var repoHasCommits: Bool?

    func loadDiff() async {
        guard let git else { return }
        do {
            // Told whether HEAD exists, `git diff` skips the `rev-parse` it
            // would otherwise spawn ahead of every diff. The answer only ever
            // changes once — the first commit — so read it at most once per
            // open repository and let `commitAndPush` update it.
            let hasCommits = if let known = repoHasCommits { known } else { try await git.hasCommits() }
            repoHasCommits = hasCommits
            pendingDiff = try await git.diff(path: keymapRelativePath, hasCommits: hasCommits)
        } catch {
            pendingDiff = ""
            self.error = AppError(title: "git diff failed", error: error)
        }
    }

    /// Commits and pushes. Returns the pushed commit's SHA so the build panel
    /// can watch for it, or nil if anything failed.
    func commitAndPush(message: String) async -> String? {
        guard let git else { return nil }
        busyMessage = "Committing…"
        defer { busyMessage = nil }
        do {
            try await git.commitAll(message: message)
            repoHasCommits = true
            busyMessage = "Pushing…"
            try await git.push()
            let sha = try await git.headSHA()
            await refreshStatus()
            notice = "Pushed \(sha.abbreviatedSHA)"
            return sha
        } catch {
            self.error = AppError(title: "Commit and push failed", error: error)
            await refreshStatus()
            return nil
        }
    }

    /// The SHA at HEAD, or nil (with an alert) if git could not tell us.
    func headSHA() async -> String? {
        guard let git else { return nil }
        do {
            return try await git.headSHA()
        } catch {
            self.error = AppError(title: "Could not read HEAD", error: error)
            return nil
        }
    }

    func currentBranch() async -> String? {
        if let branch = gitStatus?.branch { return branch }
        guard let git else { return nil }
        return try? await git.currentBranch()
    }

    func pull() async {
        guard let git else { return }
        busyMessage = "Pulling…"
        defer { busyMessage = nil }
        do {
            try await git.pull()
            await loadKeymapAndLayout()
            await refreshStatus()
        } catch {
            self.error = AppError(title: "git pull failed", error: error)
        }
    }
}

// MARK: - Assistant proposals

/// Applying and describing the edits the assistant stages.
///
/// This lives in `AppModel.swift` rather than beside the assistant because it
/// has to reach the private ``AppModel/edit(_:_:)``, and it has to reach it
/// because a proposal is not allowed a private path into the keymap. The
/// assistant's edits are the same edits the toolbar makes, applied by the same
/// code, validated by the same mutators, and spliced by the same `SourceEdit`.
extension AppModel {

    /// Applies a batch of assistant-proposed edits as one transaction: all of
    /// them land or none do.
    ///
    /// Atomicity matters more here than for a single click. A proposal is a set
    /// of changes the user read as a whole and agreed to as a whole — "swap
    /// these two thumb keys" is two edits and half of it is a broken keyboard.
    /// ``AppModel/edit(_:_:)`` already works on a copy and only assigns on
    /// success, so running the whole batch inside one call is the transaction.
    ///
    /// Returns false and raises the usual error alert when anything in the
    /// batch could not be applied.
    @discardableResult
    func applyProposal(_ edits: [ProposedEdit]) -> Bool {
        guard !edits.isEmpty else {
            error = AppError(
                title: "Nothing to apply",
                message: "There were no staged changes left to apply."
            )
            return false
        }
        let applied = edit("Could not apply the suggested changes") { file in
            for proposed in edits {
                switch proposed {
                case .setBinding(let layer, let index, let binding):
                    try file.setBinding(layer: layer, index: index, to: binding)
                case .setCombo(let combo):
                    if file.combos.contains(where: { $0.id == combo.id }) {
                        file.updateCombo(combo)
                    } else {
                        file.addCombo(combo)
                    }
                case .removeCombo(let id):
                    // `removeCombo` is a no-op on an id it does not know, which
                    // would report success for an edit that did nothing.
                    guard file.combos.contains(where: { $0.id == id }) else {
                        throw ProposalError.comboGone
                    }
                    file.removeCombo(id: id)
                case .renameLayer(let layer, let name):
                    try file.setLayerDisplayName(layer: layer, to: name)
                case .setBehavior(let behavior):
                    try file.upsertBehavior(behavior)
                case .removeBehavior(let id):
                    try file.removeBehavior(id: id)
                case .setMacro(let macro):
                    try file.upsertMacro(macro)
                case .removeMacro(let id):
                    try file.removeMacro(id: id)
                case .addLayer(let nodeName, let displayName, let bindings, let index):
                    try file.addLayer(
                        nodeName: nodeName, displayName: displayName,
                        bindings: bindings, at: index
                    )
                case .removeLayer(let index):
                    try file.removeLayer(at: index)
                }
            }
        }
        // Layer numbers move under the selection when a layer is added or
        // removed, and the sidebar would otherwise go on pointing at a number
        // that no longer names a layer. A combo selection is left alone; only
        // the layer being drawn is stale.
        if applied, let selected = selectedLayerID,
           !layers.contains(where: { $0.id == selected })
        {
            if case .layer = sidebarSelection {
                sidebarSelection = layers.first.map { .layer($0.id) }
            }
            selectedLayerID = layers.first?.id
        }
        return applied
    }

    /// How a proposed edit reads to a human, including what it replaces:
    /// "Layer 1 · key 14 — `&kp TAB` → `&kp ESC`".
    func describe(_ edit: ProposedEdit) -> String {
        switch edit {
        case .setBinding(let layer, let index, let binding):
            let previous = layers.indices.contains(layer)
                && layers[layer].bindings.indices.contains(index)
                ? layers[layer].bindings[index].text
                : nil
            let change = previous.map { "`\($0)` → `\(binding.text)`" } ?? "`\(binding.text)`"
            return "Layer \(layer) · key \(index) — \(change)"

        case .setCombo(let combo):
            guard let existing = combos.first(where: { $0.id == combo.id }) else {
                return "New combo `\(combo.nodeName)` — \(comboSummary(combo))"
            }
            // Only the properties that actually move are worth showing; a card
            // that repeats the timeout of a combo whose binding changed buries
            // the one line the user needs to read.
            var changes: [String] = []
            if existing.binding != combo.binding {
                changes.append("`\(existing.binding.text)` → `\(combo.binding.text)`")
            }
            if existing.keyPositions != combo.keyPositions {
                changes.append("keys \(positions(existing)) → \(positions(combo))")
            }
            if existing.layers != combo.layers {
                changes.append("layers \(layerList(existing.layers)) → \(layerList(combo.layers))")
            }
            if existing.timeoutMs != combo.timeoutMs {
                changes.append("timeout \(milliseconds(existing.timeoutMs)) → \(milliseconds(combo.timeoutMs))")
            }
            let body = changes.isEmpty ? "no change" : changes.joined(separator: ", ")
            return "Combo `\(combo.nodeName)` — \(body)"

        case .removeCombo(let id):
            guard let combo = combos.first(where: { $0.id == id }) else {
                return "Remove a combo that is no longer in this keymap"
            }
            return "Remove combo `\(combo.nodeName)` — \(comboSummary(combo))"

        case .renameLayer(let layer, let name):
            let previous = layers.indices.contains(layer) ? layers[layer].displayName : nil
            let change = previous.map { "“\($0)” → “\(name)”" } ?? "“\(name)”"
            return "Layer \(layer) · rename — \(change)"

        case .setBehavior(let behavior):
            let summary = AssistantTools.summary(of: behavior)
            guard keymap?.behaviors.contains(where: { $0.id == behavior.id }) == true else {
                return "New behavior `&\(behavior.label)` — \(summary)"
            }
            return "Behavior `&\(behavior.label)` — \(summary)"

        case .removeBehavior(let id):
            guard let behavior = keymap?.behaviors.first(where: { $0.id == id }) else {
                return "Remove a behavior that is no longer in this keymap"
            }
            return "Remove behavior `&\(behavior.label)` — \(AssistantTools.summary(of: behavior))"

        case .setMacro(let macro):
            // Capped, unlike the tool result: a forty-step macro spelled out in
            // full turns the card into a wall the user scrolls past rather than
            // reads.
            let summary = AssistantTools.summary(of: macro, sequenceLimit: 8)
            guard keymap?.macros.contains(where: { $0.id == macro.id }) == true else {
                return "New macro `&\(macro.label)` — \(summary)"
            }
            return "Macro `&\(macro.label)` — \(summary)"

        case .removeMacro(let id):
            guard let macro = keymap?.macros.first(where: { $0.id == id }) else {
                return "Remove a macro that is no longer in this keymap"
            }
            return "Remove macro `&\(macro.label)` — "
                + AssistantTools.summary(of: macro, sequenceLimit: 8)

        // The renumbering warning belongs on the card, not only in the tool
        // result the user never sees. Someone removing layer 2 has to read
        // "`&mo 3` on layer 0 key 31 will now point at a different layer" while
        // they are deciding whether to apply it.
        case .addLayer(_, let displayName, let bindings, let index):
            let name = displayName.map { "“\($0)”" } ?? "unnamed"
            let head = "New layer \(index) \(name) — \(bindings.count) keys"
            return head + renumbering(keymap?.layerReferencesAffected(byInsertingAt: index))

        case .removeLayer(let index):
            let name = layers.indices.contains(index) ? "“\(layers[index].displayName)”" : ""
            let head = "Remove layer \(index) \(name)".trimmingCharacters(in: .whitespaces)
            return head + renumbering(keymap?.layerReferencesAffected(byRemoving: index))
        }
    }

    /// The tail of a layer add or remove: what the file goes on calling by a
    /// number that has moved. Empty when nothing is affected, so a layer added
    /// at the end reads as one clean line.
    private func renumbering(_ affected: [String]?) -> String {
        guard let affected, let note = AssistantTools.renumbering(affected) else { return "" }
        return ". \(note)"
    }

    private func comboSummary(_ combo: KeymapCombo) -> String {
        "keys \(positions(combo)) → `\(combo.binding.text)`"
    }

    /// Position tokens rather than numbers, so a chord written with `POS_*`
    /// macros is described the way the file writes it.
    private func positions(_ combo: KeymapCombo) -> String {
        let tokens = keymap?.positionTokens(of: combo) ?? combo.keyPositions.map(String.init)
        return tokens.isEmpty ? "none" : tokens.joined(separator: "+")
    }

    private func layerList(_ layers: [Int]?) -> String {
        guard let layers else { return "all" }
        return layers.isEmpty ? "none" : layers.map(String.init).joined(separator: ", ")
    }

    private func milliseconds(_ value: Int?) -> String {
        value.map { "\($0) ms" } ?? "default"
    }
}
