import Foundation
import Observation
import ZmkonfigKit

/// What the sidebar has selected: one layer to draw, or one of the things the
/// inspector edits.
enum SidebarSelection: Hashable {
    case layer(Int)
    case combo(KeymapCombo.ID)
    case behavior(KeymapBehavior.ID)
    case macro(KeymapMacro.ID)
}

/// What the Edit tab is editing. Derived from ``SidebarSelection`` rather than
/// stored, so the inspector and the board cannot hold different opinions.
enum EditorTarget: Equatable {
    case key
    case combo(KeymapCombo.ID)
    case behavior(KeymapBehavior.ID)
    case macro(KeymapMacro.ID)
}

/// Everything the editor side of the app needs: the open repo, its keymap, the
/// keyboard layout it is drawn with, and the current selection.
@MainActor
@Observable
final class AppModel {
    /// The slug opened last, reopened on the next launch. There is no built-in
    /// default repo — the first launch opens nothing and waits for the sheet.
    static let lastSlugKey = "lastRepoSlug"
    /// `owner/name` → the catalog keyboard id chosen for it, for repos that
    /// declare no layout of their own. See ``keyboardDefinition(forRepoAt:slug:)``.
    nonisolated static let keyboardBySlugKey = "keyboardBySlug"

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
    /// The vendored ZMK behavior metadata. The behaviors *this keymap* defines
    /// are ``keymap``'s; these are the 15 stock ones every keymap can bind.
    private(set) var stockBehaviors: [ZMKBehavior] = []
    private(set) var keycodes: [ZMKKeycode] = []
    /// The behavior index: the stock ZMK behaviors plus the ones this keymap
    /// defines for itself, rebuilt when either changes. ``BehaviorIndex`` owns
    /// how it is derived; this is only where the current one is kept.
    private(set) var behaviorIndex: BehaviorIndex = .empty
    var availableBehaviors: [ZMKBehavior] { behaviorIndex.all }
    /// The prose behind the jargon: what `&kp`, `flavor` and `hold-tap` mean.
    /// Every explanation in the UI comes from here, so none of them can drift
    /// into wording it differently.
    private(set) var glossary: Glossary = .empty
    private(set) var catalog: [CatalogEntry] = []
    private(set) var isLoadingCatalog = false

    // Selection
    /// What the sidebar has picked. A combo stays selected while the board goes
    /// on showing a layer, because picking a combo's key positions means
    /// clicking keys on a layer — which one is ``showLayer(forCombo:)``.
    var sidebarSelection: SidebarSelection? {
        didSet {
            guard sidebarSelection != oldValue else { return }
            selectedKeyIndex = nil
            switch sidebarSelection {
            case .layer(let id): selectedLayerID = id
            case .combo(let id): showLayer(forCombo: id)
            case .behavior, .macro, .none: break
            }
        }
    }
    private(set) var selectedLayerID: Int?
    /// The key the board has picked, if any.
    ///
    /// Not settable from outside: a writer that selects a key without also
    /// taking the sidebar off a behavior or macro puts the board on one thing
    /// and the inspector on another. ``selectKey(_:)`` and ``reveal(layerID:keyIndex:)``
    /// are the ways in, and both go through ``sidebarSelection``.
    private(set) var selectedKeyIndex: Int?

    /// Puts the board on the layer a newly selected combo is picked against.
    ///
    /// A combo's chord is chosen by clicking keys, so the layer showing is the
    /// one whose keycaps the user reads the chord off. A combo scoped to "all
    /// layers" fires everywhere, and the default layer is where its positions
    /// mean what people expect — so selecting one comes back there rather than
    /// leaving the board wherever it happened to be. A combo scoped to
    /// particular layers only fires on those, and any other layer would label
    /// its chord with keys the combo has nothing to do with.
    private func showLayer(forCombo comboID: KeymapCombo.ID) {
        guard let combo = combos.first(where: { $0.id == comboID }) else { return }
        guard let scope = combo.layers, !scope.isEmpty else {
            selectedLayerID = layers.first?.id
            return
        }
        // Already on one of the combo's own layers: stay there, so stepping
        // through combos scoped the same way does not keep moving the board.
        if let current = selectedLayerID, scope.contains(current) { return }
        // A scoped layer that no longer exists names nothing to draw; the
        // default layer is the fallback, as it is everywhere else here.
        selectedLayerID = scope.first { id in layers.contains { $0.id == id } }
            ?? layers.first?.id
    }

    /// The single authority for what the Edit tab shows, so the inspector
    /// cannot disagree with the board.
    ///
    /// A layer selected — or nothing selected — means the board owns the tab
    /// and it edits the picked key; anything else in the sidebar owns it
    /// instead. There is no combination of the two selection axes that leaves
    /// this ambiguous, which is the point of deriving it in one place.
    var editorTarget: EditorTarget {
        switch sidebarSelection {
        case .combo(let id): .combo(id)
        case .behavior(let id): .behavior(id)
        case .macro(let id): .macro(id)
        case .layer, .none: .key
        }
    }

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

    /// A combo's key positions as the file states them, falling back to the
    /// numbers when there is no keymap to ask. Every view that prints a chord
    /// goes through this, because two of them printing it differently is a bug
    /// this project has already had.
    func positionTokens(of combo: KeymapCombo) -> [String] {
        keymap?.positionTokens(of: combo) ?? combo.keyPositions.map(String.init)
    }

    /// The combos that fire on one layer. `KeymapLayer.id` is the layer number,
    /// which is what a combo's `layers` property holds.
    func combos(onLayer id: Int) -> [KeymapCombo] {
        combos.filter { $0.isActive(onLayer: id) }
    }

    var behaviors: [KeymapBehavior] { keymap?.behaviors ?? [] }

    var macros: [KeymapMacro] { keymap?.macros ?? [] }

    // There is deliberately no `selectedBehavior`/`selectedMacro` here. Asking
    // the model "is a behavior selected?" is what let the inspector answer
    // differently from the board; ``editorTarget`` is the one way to ask.

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
        behaviorIndex.behavior(for: code)
    }

    /// False for behaviors the keymap defines itself, whose parameter kinds we
    /// can only guess at.
    func isDocumentedBehavior(_ code: String) -> Bool {
        behaviorIndex.isDocumented(code)
    }

    /// The term explaining a bound behavior — see
    /// ``Glossary/term(forBehavior:in:)``, which owns the fall-through to the
    /// kind that a keymap's own behaviors rely on. This is what the help badge
    /// opens; the line printed under the picker is ``explanation(ofBehavior:)``.
    func glossaryTerm(forBehavior code: String) -> String? {
        glossary.term(forBehavior: code, in: keymap)
    }

    /// The line shown under the behavior picker — see
    /// ``Glossary/explanation(forBehavior:in:)``, which owns the choice between
    /// a stored summary, a saved note and a derived sentence.
    func explanation(ofBehavior code: String) -> String? {
        glossary.explanation(forBehavior: code, in: keymap)
    }

    /// What a binding does, in a sentence, or nil for a behavior the glossary
    /// has nothing to say about. Views draw nothing rather than a placeholder;
    /// see ``BindingNarrator/sentence(for:behavior:layers:glossary:)``.
    func narration(of binding: KeyBinding) -> String? {
        BindingNarrator.sentence(
            for: binding,
            behavior: behavior(for: binding.behavior),
            layers: layers,
            glossary: glossary
        )
    }

    /// The sentence plus the binding text under it, for a keycap's tooltip.
    func description(of binding: KeyBinding) -> String {
        BindingNarrator.keyDescription(
            for: binding,
            behavior: behavior(for: binding.behavior),
            layers: layers,
            glossary: glossary
        )
    }

    /// The 15 stock behaviors are only half the story: this keymap defines
    /// eight hold-taps of its own (`&hml`, `&hmr`, `&qt`, …) that metadata
    /// knows nothing about. ``BehaviorIndex`` reads them out of the parsed
    /// keymap so they can be picked even on keys that do not already use them.
    private func rebuildBehaviorIndex() {
        behaviorIndex = BehaviorIndex(stock: stockBehaviors, keymap: keymap)
    }

    /// What the keymap looks like to a feature that only reads it — the
    /// assistant's tools, and the digests they answer with.
    ///
    /// Built per call rather than stored: it is a handful of already-shared
    /// values, and a stored copy is one more thing that can be a turn out of
    /// date while the model reasons about it.
    var context: KeymapContext {
        KeymapContext(
            keymap: keymap,
            keycodes: keycodes,
            layout: layout,
            behaviors: behaviorIndex,
            hasUnsavedEdits: hasUnsavedEdits,
            keymapRelativePath: keymapRelativePath
        )
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
                (
                    behaviors: try AppResources.loadBehaviors(),
                    keycodes: try AppResources.loadKeycodes(),
                    glossary: try AppResources.loadGlossary()
                )
            }.value
            stockBehaviors = loaded.behaviors
            keycodes = loaded.keycodes
            glossary = loaded.glossary
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
        async let definition = Self.keyboardDefinition(forRepoAt: repo.localURL, slug: repo.slug)

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
            // Nothing declared it and nothing was remembered: ask, rather than
            // draw the keymap on whatever board happens to be lying around.
            if keyboard == nil { promptForKeyboard() }
        } catch {
            // A remembered id that will not load leaves the board empty and the
            // reason on screen. The prompt is not opened on top of the alert —
            // the hint under the board and the toolbar's keyboard button both
            // still lead to the picker.
            keyboard = nil
            layoutKey = nil
            self.error = AppError(title: "Could not load keyboard layout", error: error)
        }

        refreshComboProblems()
    }

    /// The layout to draw the keymap on: what the repository declares, else
    /// what was last chosen for this repository, else nothing.
    ///
    /// **There is no default keyboard.** A keymap drawn on the wrong physical
    /// layout still looks like a keyboard — the keys land in plausible places
    /// and every one of them is in the wrong position — so a guess here is worse
    /// than an empty board and a question. `nil` means ask.
    ///
    /// `config/info.json` wins over the remembered choice because it is the
    /// repository's own declaration and is version controlled; a local
    /// preference must not silently contradict it. The remembered id is
    /// therefore only ever consulted for repositories that declare nothing,
    /// which are exactly the ones that get prompted.
    ///
    /// `nonisolated` so ``loadKeymapAndLayout`` can start it alongside the
    /// keymap parse rather than after it.
    private nonisolated static func keyboardDefinition(
        forRepoAt root: URL, slug: String
    ) async throws -> KeyboardDefinition? {
        if let fromRepo = try await LayoutCatalog.shared.definitionForRepo(root) { return fromRepo }
        guard let remembered = rememberedKeyboardID(forSlug: slug) else { return nil }
        return try await LayoutCatalog.shared.definition(id: remembered)
    }

    /// The keyboard chosen for a repository on a previous run, if any.
    nonisolated static func rememberedKeyboardID(forSlug slug: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: keyboardBySlugKey) as? [String: String]
        return map?[slug]
    }

    nonisolated static func rememberKeyboardID(_ id: String, forSlug slug: String) {
        var map =
            UserDefaults.standard.dictionary(forKey: keyboardBySlugKey) as? [String: String] ?? [:]
        map[slug] = id
        UserDefaults.standard.set(map, forKey: keyboardBySlugKey)
    }

    /// Opens the catalog picker, with the catalog already on its way.
    func promptForKeyboard() {
        isShowingCatalogSheet = true
        Task { await loadCatalog() }
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

    /// Picks a keyboard by catalog id and remembers it for the open repository.
    ///
    /// The choice is recorded even when the repository declares its own layout
    /// and the record will therefore not be read back — it costs a defaults key
    /// and means the answer is already there if `config/info.json` later goes
    /// away. Only a load that succeeded is remembered: an id that does not
    /// resolve is not an answer worth keeping.
    func chooseKeyboard(id: String) async {
        busyMessage = "Loading \(id)…"
        defer { busyMessage = nil }
        do {
            keyboard = try await LayoutCatalog.shared.definition(id: id)
            layoutKey = nil
            if let slug = repo?.slug { Self.rememberKeyboardID(id, forSlug: slug) }
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

    /// Point the editor at one layer, and optionally one key on it. Used by the
    /// menubar panel, which selects from outside the window. It goes through
    /// `sidebarSelection` rather than `selectKey` on purpose: a combo may be
    /// selected, and there a click on a key edits the combo's chord.
    func reveal(layerID: Int, keyIndex: Int? = nil) {
        sidebarSelection = .layer(layerID)
        // `sidebarSelection`'s didSet clears the key, so this has to come after.
        selectedKeyIndex = keyIndex
    }

    // MARK: - Editing

    /// A click on the board. While a combo is selected that means adding or
    /// removing one of its key positions rather than picking a key to edit.
    func selectKey(_ index: Int) {
        guard var combo = selectedCombo else {
            // A behavior or macro selected in the sidebar owns the inspector,
            // and unlike a combo it is not edited by clicking the board. So a
            // click here means "edit this key" and has to take the inspector
            // back, or the key would highlight with nothing to show for it.
            if let layerID = selectedLayerID, sidebarSelection != .layer(layerID) {
                reveal(layerID: layerID, keyIndex: index)
            } else {
                selectedKeyIndex = index
            }
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
        // What `&hml` is, and whether there is an `&hml` at all, is derived from
        // these — so defining a behavior has to reach the picker without a
        // reload. Guarded because a plain key edit changes neither and rebuilding
        // walks every binding in the keymap.
        let definitionsChanged = file.behaviors != keymap?.behaviors || file.macros != keymap?.macros
        keymap = file
        hasUnsavedEdits = true
        notice = nil
        if definitionsChanged { rebuildBehaviorIndex() }
        refreshComboProblems()
        reconcileSelection()
        return true
    }

    /// Puts the selection back on something that still exists.
    ///
    /// Adding or removing a layer renumbers the ones after it, so a stored layer
    /// number can stop naming a layer; removing a behavior, macro or combo
    /// leaves the sidebar pointing at an id nothing answers to. Both leave the
    /// inspector drawing a hint where an editor was, which reads as the edit
    /// having failed.
    private func reconcileSelection() {
        let stillThere: Bool = switch sidebarSelection {
        case .layer(let id): layers.contains { $0.id == id }
        case .combo(let id): combos.contains { $0.id == id }
        case .behavior(let id): behaviors.contains { $0.id == id }
        case .macro(let id): macros.contains { $0.id == id }
        case .none: true
        }
        if !stillThere {
            // Back to a layer, which is what the board is drawing anyway.
            let fallback = selectedLayerID.flatMap { id in layers.first { $0.id == id } }
                ?? layers.first
            sidebarSelection = fallback.map { .layer($0.id) }
        }
        if let selected = selectedLayerID, !layers.contains(where: { $0.id == selected }) {
            selectedLayerID = layers.first?.id
        }
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
    }

    // MARK: - Behaviors

    func updateBehavior(_ behavior: KeymapBehavior) {
        edit("Could not update that behavior") { try $0.upsertBehavior(behavior) }
    }

    /// Defines a behavior of `kind` and selects it, so the inspector opens on
    /// the fields the user has to fill in.
    ///
    /// It is deliberately created incomplete: a hold-tap arrives wrapping
    /// `&kp`/`&kp` and a mod-morph with no `mods`, because the alternative is
    /// inventing a default for a property whose whole point is that the user
    /// chooses it. ``BehaviorWriter/problems(with:)`` says what is still missing,
    /// and the editor shows it — the same sentences the assistant is told.
    func addBehavior(kind: BehaviorKind) {
        guard let file = keymap else { return }
        let label = file.uniqueNodeName(
            startingFrom: kind.rawValue, separator: "_", taken: file.modelledNodeNames
        )
        let bindings: [String] = switch kind.bindings {
        case .none: []
        case .phandles(let count), .phandleArray(.some(let count)):
            Array(repeating: "&kp", count: count)
        case .phandleArray(.none): ["&kp", "&kp"]
        }
        let behavior = KeymapBehavior(
            nodeName: label,
            label: label,
            compatible: kind.compatible,
            bindingCells: kind.bindingCells,
            bindings: bindings,
            properties: kind.requiredProperties.map {
                BehaviorProperty(name: $0, value: BehaviorPropertyShape.shape(of: $0).initialValue)
            }
        )
        guard edit("Could not add a behavior", { try $0.upsertBehavior(behavior) }) else { return }
        sidebarSelection = .behavior(behavior.id)
    }

    func removeBehavior(id: KeymapBehavior.ID) {
        edit("Could not remove that behavior") { try $0.removeBehavior(id: id) }
    }

    /// What in the keymap would stop resolving if `&label` went away. Shown
    /// before the deletion, not after it.
    ///
    /// Labelled for a behavior *or* a macro: both are referred to as `&label`
    /// and both delete confirmations ask the same question.
    func usage(ofLabel label: String) -> [String] {
        references(to: "&\(label)")
    }

    // MARK: - Macros

    func updateMacro(_ macro: KeymapMacro) {
        edit("Could not update that macro") { try $0.upsertMacro(macro) }
    }

    func addMacro() {
        guard let file = keymap else { return }
        let label = file.uniqueNodeName(
            startingFrom: "macro", separator: "_", taken: file.modelledNodeNames
        )
        let macro = KeymapMacro(
            nodeName: label,
            label: label,
            compatible: MacroKind.plain.compatible,
            bindingCells: MacroKind.plain.bindingCells,
            bindings: [KeyBinding(behavior: "&kp", params: [BindingParam(value: "A")])]
        )
        guard edit("Could not add a macro", { try $0.upsertMacro(macro) }) else { return }
        sidebarSelection = .macro(macro.id)
    }

    func removeMacro(id: KeymapMacro.ID) {
        edit("Could not remove that macro") { try $0.removeMacro(id: id) }
    }

    /// Every place in the keymap that refers to `code`, as phrases for the
    /// delete confirmation.
    ///
    /// The walk is ``AssistantTools/references(to:in:)``'s, not this file's. It
    /// used to be a second traversal here, and it was the weaker of the two:
    /// it never looked at a behavior's phandle-list properties, so a
    /// `sensor-bindings` still pointing at a behavior was reported as nothing
    /// referring to it — a confirmation dialog wrong in the direction that
    /// costs the user something.
    ///
    /// Only what the editor models is searched — a node override, or a
    /// `#define` that expands to a reference, cannot be found — so this is a
    /// warning and never a guarantee that a deletion is safe. Same limit, and
    /// the same reason for it, as
    /// ``KeymapFile/layerReferencesAffected(byRemoving:)``.
    private func references(to code: String) -> [String] {
        AssistantTools.references(to: code, in: context).map { reference in
            // Only the layer case is re-worded, and only because this side
            // knows something the kit does not: what the layer is called. A
            // dialog naming "layer 3" alone makes the user go and look.
            guard case .layer(let id, let keys) = reference.site,
                  let layer = layers.first(where: { $0.id == id })
            else { return reference.description }
            let numbers = keys.map(String.init).joined(separator: ", ")
            return "layer \(id) (\(layer.displayName)) key\(keys.count == 1 ? "" : "s") \(numbers)"
        }
    }

    // MARK: - Layers

    /// Adds a layer of `&trans` at `index` and selects it.
    ///
    /// The key count comes from the layout, falling back to an existing layer,
    /// exactly as `add_layer` does — a layer of the wrong length is a keymap
    /// that does not build, so it is refused rather than guessed at.
    func addLayer(nodeName: String, displayName: String?, at index: Int) {
        let keyCount = layout.isEmpty ? layers.first?.bindings.count : layout.count
        guard let keyCount else {
            error = AppError(
                title: "Could not add a layer",
                message: "No keyboard layout is loaded and there is no existing layer to take a "
                    + "key count from, so there is no way to know how many keys the new layer has."
            )
            return
        }
        let bindings = Array(repeating: KeyBinding(behavior: "&trans"), count: keyCount)
        let applied = edit("Could not add a layer") {
            try $0.addLayer(
                nodeName: nodeName, displayName: displayName, bindings: bindings, at: index
            )
        }
        guard applied else { return }
        sidebarSelection = .layer(index)
    }

    func renameLayer(at index: Int, to name: String) {
        edit("Could not rename that layer") { try $0.setLayerDisplayName(layer: index, to: name) }
    }

    func removeLayer(at index: Int) {
        edit("Could not remove that layer") { try $0.removeLayer(at: index) }
    }

    /// A node name nothing in the keymap is using yet, for a new layer, behavior
    /// or macro. `separator` is `-` for a combo and `_` for everything else.
    func uniqueNodeName(startingFrom base: String, separator: Character = "_") -> String {
        guard let keymap else { return base }
        return keymap.uniqueNodeName(
            startingFrom: base, separator: separator, taken: keymap.modelledNodeNames
        )
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
            // Refresh first, then report. The status is what tells Rebase and
            // Discard whether they apply, so a failed pull is exactly when it
            // has to be re-read — and re-reading before the assignment keeps
            // the pull's own message on screen rather than letting a status
            // read that failed for the same reason overwrite it.
            await refreshStatus()
            self.error = AppError(title: "git pull failed", error: error)
        }
    }

    /// Replays local commits on top of the upstream, for the case a
    /// fast-forward cannot reach: commits on both sides.
    func pullRebase() async {
        guard let git else { return }
        busyMessage = "Rebasing…"
        defer { busyMessage = nil }
        do {
            let upstream = try? await git.upstream()
            try await git.pullRebase()
            await loadKeymapAndLayout()
            await refreshStatus()
            notice = "Rebased onto \(upstream ?? "the upstream")"
        } catch {
            await refreshStatus()
            self.error = AppError(title: "git rebase failed", error: error)
        }
    }

    /// Throws away every uncommitted change to tracked files and re-reads the
    /// keymap from disk. Unsaved edits in the editor go with them — the reload
    /// is what makes the board agree with the file again.
    func discardLocalChanges() async {
        guard let git else { return }
        busyMessage = "Discarding local changes…"
        defer { busyMessage = nil }
        do {
            try await git.discardLocalChanges()
            await loadKeymapAndLayout()
            await refreshStatus()
            notice = "Discarded local changes"
        } catch {
            await refreshStatus()
            self.error = AppError(title: "Could not discard local changes", error: error)
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
        // removed, and a removed behavior or macro leaves the sidebar pointing
        // at an id nothing answers to. `edit` reconciles both, so there is
        // nothing left to do here — and one fixup rather than two is why a
        // sidebar deletion cannot behave differently from an applied proposal.
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
        let tokens = positionTokens(of: combo)
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
