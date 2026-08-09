# Outstanding work

Known gaps, deferred decisions, and things worth revisiting. Remove an entry
when it is done — this file should shrink.

## Unverified

- **The write path has never run end to end.** Commit → push → dispatch → watch
  → download → flash is implemented and each piece is verified in isolation,
  but the whole chain has never been exercised: doing so pushes to a real repo
  and needs a board in bootloader mode. The first real test should be a
  one-key edit — if the diff the app shows is a single line, the surgical-edit
  guarantee holds against a real repo and not just the fixture.

- **Only the happy path of the Anthropic integration has really run.** Saving a
  valid key, listing models, and explaining a diff have all been exercised
  against the live API. What has not: a *rejected* key (it must be reported and
  **not** written to the keychain), a network failure mid-request, and a
  response large enough to hit `max_tokens`.

- **The assistant has never run against the live API.** The whole tool loop —
  `converse`, the eighteen tools, staging, Apply — is unit-tested only at the wire
  level, against stubbed responses. Nothing has watched a real model call
  `read_layer`, stage a `set_binding` and have a human apply it. The first real
  run should be a one-key change on a layer that is on screen, checked against
  the diff: if the assistant's Apply produces the same one-line diff a manual
  edit would, the proposal path really is the manual path. Until then, treat the
  loop's behaviour under a model that misuses a tool as unknown.

- **Nothing in `Sources/Zmkonfig/` is unit tested.** `Tests/` builds against
  `ZmkonfigKit` only, so `AssistantTools`, `KeymapDigest` and
  `AppModel.applyProposal` are verified by reading rather than by running.
  Adding a `ZmkonfigTests` target would cost one `Package.swift` stanza; the
  reason not to was that the app target is `@MainActor` SwiftUI throughout,
  which none of these types actually need. The behavior, macro and layer tools
  made it worse: `behaviorProperties(_:merging:)` (JSON to `BehaviorValue`, a
  `null` value deleting a property, `false` refused), `behaviorValue(_:)`'s
  `.integers`/`.references`/`.tokens` discrimination, the line-boundary clipping
  in `read_keymap_source`, and every argument-rejection path are all pure
  functions with real edge cases and no test. `ArgumentRead`/`argument(_:_:_:_:)`
  makes the last of those one mechanism instead of fourteen copies, which is
  exactly the shape a table-driven test wants and still cannot have.

  The way in is that none of `AssistantTools`' 1,700 lines is UI or app
  lifecycle — it is validation, value discrimination and prose over the parsed
  model — and it sits in the app target only because `run(_:app:staged:)` takes
  an `AppModel`, of which it uses nine read-only members (layers, combos,
  keymap, keycodes, layout, availableBehaviors, isDocumentedBehavior,
  hasUnsavedEdits, keymapRelativePath). A `Sendable` `KeymapContext` snapshot
  carrying those nine would let `AssistantTools`, `ProposedEdit` and
  `KeymapDigest` move into the kit and be tested without a second test target;
  `applyProposal` stays in the app, where the private `edit` lives.

- **A staged proposal can go stale and only finds out at Apply.** The tools
  validate against the keymap as it stands when the model calls them, but the
  user can edit a key by hand, reload the repo, or apply an earlier proposal
  before pressing Apply on a later one. `ProposalError.comboGone` and the
  mutators' own range checks catch the cases that would corrupt something, and
  the batch is atomic so a half-applied proposal is impossible — but a
  `set_binding` whose key has since changed applies silently over the top. The
  card shows the before-state as it was when staged, which by then may be a
  lie.

- **Stable signing is now in place but the prompt has not been confirmed gone.**
  `CODESIGN_IDENTITY` now falls back through **Zmkonfig Local** → **Developer ID
  Application** → **Apple Development**, and `make bundle` signs with the last
  of those on this machine, producing a designated requirement that no longer
  changes between builds. What is unverified is the part that matters: clicking
  "Always Allow" once and then rebuilding and relaunching without being asked
  again. The existing keychain item's ACL still trusts the old ad-hoc binary,
  so the *first* launch after this change will still prompt — that one is
  expected, a second one is the bug. If it does recur, check whether the Apple
  Development certificate has expired before touching any code.

- **A behavior's usage check only looks at layers and combos.**
  `AssistantTools.usage(of:in:)` reports where a behavior about to be removed is
  still bound by walking `app.layers` and `app.combos`. A reference from inside
  another behavior's `bindings`, or from a macro's sequence, is not counted. The
  message says where it looked rather than claiming the behavior is unused, but
  the model can still be told "no layer and no combo binds it" about something a
  hold-tap wraps. `KeymapFile.behaviors` and `.macros` are both parsed now, so
  checking them is a few lines.

- **The column-width floor of 7 is unexercised.** `BindingTable` uses
  `max(7, longest + 2)`, but the narrowest column in the reference keymap is
  `&trans` at 6+2=8, so the floor never engages. It rests on the reference
  implementation rather than on measurement. A keymap whose widest binding in
  some column is under 5 characters would prove or disprove it.

## Not implemented

- **Streaming the explanation.** `AnthropicClient.complete` is non-streaming, so
  the panel sits on a spinner for however long the model thinks — tens of
  seconds at the default effort. Streaming would need SSE parsing over
  `URLSession.bytes(for:)` and a token-at-a-time sink in `ExplainModel`.
- **A UI for behaviors, macros and layer structure.** `KeymapFile` can now
  upsert and remove behaviors and macros and add and remove layers, and the
  assistant can drive all of it, but there is no view for any of it — a user
  who does not want to ask Claude still cannot create a hold-tap or a macro, or
  add a layer, without editing the file by hand. This is now the biggest gap
  versus the web editor.
- **Reordering combos, behaviors, macros and layers.** New ones are appended
  (a layer can be inserted at a chosen index, but an existing one cannot be
  moved) and existing ones are edited where they sit. Moving one means
  relocating a whole node — cutting it and re-inserting it elsewhere in the
  same save — which `NodeSection`/`NodeAnchor` could express but nothing does.
- **Rewriting layer references when layers are renumbered.** Removing or
  inserting a layer shifts every layer number after it, and `&mo 2` elsewhere
  in the file goes on saying `2`.
  `KeymapFile.layerReferencesAffected(byRemoving:)`/`(byInsertingAt:)` reports
  what will drift so the user can be warned, and deliberately rewrites nothing:
  a number can sit inside a macro, a custom behavior or a `#define` that the
  editor does not model, and a partial rewrite is worse than none. Doing it
  properly needs the preprocessor, or an explicit "these are the ones I can
  see, fix the rest yourself" pass over what is modelled.
- **Local firmware builds.** Actions-only by choice. Would need a west/Zephyr
  toolchain and a much longer first-run story.

## Improvements

- **The Claude prompts are context-starved, and it is local context they are
  missing — not ZMK documentation.** `ExplainModel` sends one layer as a
  numbered list of binding strings, then asks the model to identify home-row
  mods, thumb keys, and unreachable layers. It cannot: it never sees what
  `&hml` actually is (`flavor`, `tapping-term-ms`,
  `hold-trigger-key-positions` are all parsed and sit in `KeymapFile.document`),
  never sees the physical layout (`KeyPosition` has `row`/`col`/`x`/`y`), never
  sees the other layers, and never sees the combos — which are often the only
  way back from a layer. `explainChanges` has the same gap: a diff with no
  position geometry, asked which keys moved. The layer now goes through
  `BindingTable.render(_:layout:)`, so the physical grid is no longer missing —
  the behaviors, the other layers and the combos still are. The fix is a
  context pack built from what the app already parses; it belongs in
  `ZmkonfigKit` next to the `BehaviorIndex` move below, so it can be tested.
  Fetching ZMK docs at runtime (Context7 or similar) was
  considered and rejected: a second network hop before every call, a second
  credential, non-deterministic retrieval, and a per-request snippet in the
  prefix would defeat prompt caching. Vendor a distilled primer instead.

- **`AnthropicClient` still sends no `thinking`, so it runs at the model's
  default.** `output_config.effort` is now gated on the `capabilities` tree
  `GET /v1/models` returns, but `thinking` was deliberately left out of that
  pass: its per-model rules are stricter than effort's — on some models an
  explicit `disabled` is rejected outright, on others only below a certain
  effort — so the same "unknown means send nothing" gate needs per-model rules
  rather than one capability lookup. Worth doing only if the effort gate turns
  out not to have bought back enough of the spinner.

- **The assistant's turn budget is still 4096 and still unchecked.**
  `AnthropicConversation.converse` caps `max_tokens` at 4096 and never looks at
  `stop_reason`, so a long tool-use turn hits the same truncation `complete`
  now reports — silently, and mid-way through a loop that will then act on a
  half-written turn. It needs the `ClaudeCompletion` treatment: a bigger
  ceiling and a truncation flag the loop can stop on.

- **No prompt caching, and the per-model minimum is a trap.** Once a stable
  context pack exists it should carry `cache_control` on the last system block:
  reads cost ~0.1x, writes 1.25x, so break-even is two requests and a session
  spent reading six layers is one write and five reads. The catch is that the
  minimum cacheable prefix depends on the model the user picked — 512 tokens on
  Opus 5, 1024 on Sonnet 5, 4096 on Haiku 4.5 — and a prefix under the minimum
  does not error, it just silently reports `cache_creation_input_tokens: 0`.
  The pack must also stay byte-identical across requests: the layer id and the
  diff belong in the user turn, after the breakpoint, never in the system block.

- **`ClaudeRequest` throws away every answer it has already paid for.**
  Answers are keyed by `subject` already, but `clear()` discards them, so
  flipping between two layers re-asks and re-bills. A small LRU on `subject`
  would make revisiting instant and free.

- **The ZMK binding semantics live in the app target, so none of it is
  testable.** `BindingLabel` (the keycode spelling table and modifier set),
  `BindingFieldsView`'s `decompose`/`compose`/`rebuild` algebra, and
  `AppModel.rebuildBehaviorIndex`/`parameterKinds` are ~500 lines of pure ZMK
  domain logic with no SwiftUI in them, sitting outside `ZmkonfigKit`. The one
  test target depends on the kit, so there is no way to write a test for any of
  it — the parser next door has 63 tests, the layer deciding what
  `&hml LEFT_GUI A` *means* has none. Worse, `decompose` asks
  `BindingLabel.modifierSymbols` — a *display* table — whether a parameter is a
  modifier wrapper, so adding a glyph silently changes how bindings are parsed
  and recomposed on save. Moving them into `Sources/ZmkonfigKit/Model/` behind a
  `BehaviorIndex` type, and splitting `modifierSymbols` into a structural set
  and a glyph table, would unlock tests for all of it. Deferred from the
  cleanup pass because it is a real refactor that deserves its own tests rather
  than a mechanical move.

  `rebuildBehaviorIndex` has a second problem worth fixing in the same pass: it
  re-derives from raw devicetree what `KeymapFile` has already parsed. It walks
  `keymap.document.allNodes()` filtering on `compatible.hasPrefix(
  "zmk,behavior-")`, and `parameterKinds` reads `bindings` cell texts and
  `#binding-cells` by hand — while `KeymapFile.init` walks the identical
  `allNodes()` and reads every one of those nodes into `behaviors` and `macros`
  with a typed compatible and `bindingCells`. So the app parses the tree a
  second time, with a second predicate, to compute a fact the parsed model
  already holds. A kit-side `definedBehaviors()` built from `behaviors + macros`
  would shrink `AppModel` to an assignment and make the `.macroBehavior` split
  visible to the behavior picker, which it currently is not.

- **Combos bypass the generic node-editing mechanism written to replace them.**
  `NodeEditing.swift` opens by saying the logic exists once because "a second
  copy of it is how the second copy drifts" — and there are now two.
  `KeymapFile.comboEdits`/`edits(for:anchor:)`/`insertion(of:keeping:)` hand-roll
  removal, `clearingAll`, per-property diffing and section insertion; the
  generic `nodeEdits` does the same for behaviors and macros. There are two
  property splicers (`NodeAnchor.propertyEdit`, used only by combos, and
  `KeymapFile.propertyEdits`) and two property-value types. What blocks
  unification is that `ComboWriter` pre-renders values into strings
  (`.value("<\(combo.binding.text)>")`) before `KeymapFile` sees them, where a
  behavior hands over a structured `BehaviorValue`. Have `ComboWriter.properties`
  return `[(String, BehaviorValue)]` and route combos through `nodeEdits` with an
  `alwaysRewritten: Set<String>` parameter holding `bindings`, mirroring the
  existing `wholeLineProperties`; `PropertyWrite` and `NodeAnchor.propertyEdit`
  then delete. This *declares* the always-rewrite-bindings rule the round-trip
  test protects rather than weakening it — but it is the riskiest refactor in
  the file and wants doing on its own, with that test watched closely.

- **Every tool parameter is still declared twice.** The schema block in
  `AssistantTools` states each parameter's name, type and requiredness, and the
  executor a thousand lines away states all three again. The copy-paste is gone
  — `argument(_:_:_:_:)` names the key once per site — but adding a parameter
  still means editing two distant places, and the expected-type string in
  `badArgument` is free text that can silently disagree with the schema. One
  `ToolParameter` value per parameter, with the schema generated from it and a
  typed accessor (`try args.int(.layer)`) throwing a failure the run loop
  funnels, would make the two impossible to desync.

- **`checkNodeName` only considers behaviors and macros.** `uniqueNodeName` now
  works from `modelledNodeNames` (layers ∪ combos ∪ behaviors ∪ macros), so
  generated names no longer collide with a layer or combo node — but the
  validator a user-supplied name goes through still checks the narrower set, and
  it excludes the node's own id from what counts as taken, which a plain
  `Set<String>` cannot express. Widening it would start rejecting existing files
  that already carry such a collision, so it needs a deliberate decision about
  what to do with them rather than a one-line change.

- **`BuildModel` takes the repo slug as a parameter on four entry points.**
  `dispatch`, `loadRecentRuns`, `watch` and `useRun` each take `slug`, so five
  view call sites open with `Task { guard let slug = model.repo?.slug else
  { return } … }` — a guard whose failure is a silent no-op, so pressing Watch
  or Refresh with no repo open does nothing with no explanation. `BuildModel`
  should hold the slug, set when `AppModel.openRepo` succeeds, and the "no repo"
  case handled once by the existing hint in `BuildPanelView`.

- **`KeymapFile.updateCombo` and `removeCombo` are silent no-ops for an unknown
  id.** `setBinding` now throws instead, because a dropped binding edit is
  user-visible. The combo mutators are currently unreachable with a bad id
  (the id always comes from `selectedCombo`), so they were left alone — but they
  are the same silent-failure shape and should throw too if a second caller
  ever appears.

- **A zero-parameter behavior is indistinguishable from an unknown one.** Both
  present as an empty `params`, so `BindingLabel`'s `kinds.isEmpty &&
  values.count == 2` hold-tap guess and `BindingFieldsView.slotKinds`' fallback
  cannot be deleted as dead code even though `rebuildBehaviorIndex` guarantees
  an entry for every referenced behavior: `parameterKinds` returns `[]` for any
  node whose `#binding-cells` is `<0>` or unreadable, and the editor parses
  malformed keymaps by design. Distinguishing "declares no parameters" from
  "we could not tell" — an optional rather than an empty array — would make
  both fallbacks provably unnecessary.

- **A handful of view literals have no theme token.** `ZmkonfigApp`'s window
  `minWidth: 1000, minHeight: 640` and `defaultSize(1240, 780)` (the column
  tokens do not sum to these), the layer-index gutter's `minWidth: 14`, the
  layout picker's `maxWidth: 220`, the `.padding(.vertical, 1/2)` on badges,
  list rows and diff lines (between `spacingXS` of 4 and nothing), and
  `SectionLabel`'s `.kerning(0.6)`. Each needs either a new token or a decision
  that it is not themeable.

- **Window chrome stays macOS's, not the theme's.** The titlebar/toolbar strip,
  the sidebar's translucent material and the sidebar selection fill are drawn by
  AppKit, so they hold the system appearance and the system accent while
  everything below them is Catppuccin. In light mode this reads as a white bar
  over a Latte window; pinning the app to dark on a light system makes it
  obvious. Fixing it means a `titlebarAppearsTransparent` window with our own
  background, and it is why `SidebarView.rowTitle`/`rowDetail` have to defer to
  SwiftUI's `primary`/`secondary` on a selected row instead of using a token.

- **A failed background `git fetch` is invisible.** `RepoManager.open` now runs
  the fetch in the background and `RepoManager.fetch(slug:)` rethrows it, but
  `AppModel.awaitFetch` discards that error: the app has no non-fatal warning
  surface — `notice` is drawn in the success tone — and an alert on every
  offline launch would be noise. Wants a real warning surface (a muted
  status-bar line, or a `notice` that carries a tone), and then this failure
  should use it. The only cost today is an ahead/behind badge as stale as the
  last successful fetch.
- **Per-half firmware artifacts.** `zmk-sweep`'s `build.yml` uploads both
  `.uf2` files in a single artifact, so there is no way to build or fetch just
  one side. Splitting it into two artifacts would make flashing one half
  cheaper.

## Workarounds to revisit

Both are compensating for toolchain bugs, not design choices. Re-test each when
the Swift toolchain updates and delete the workaround if it is no longer needed.

- **`DTToken` stores `punct`/`identifier` instead of computing them.** As
  computed properties, the borrow chains at the use sites crash the Swift 6.3.3
  optimizer — CopyPropagation fails ownership verification with "Found outside
  of lifetime use?!", so `-O` builds abort while debug builds are fine. See the
  comment in `DTLexer.swift`.
- **A `Binding`'s setter must be written as a literal closure.** A `Binding`
  setter is `@isolated(any) @Sendable`, and handing it a ready-made function
  value — anything built by a helper that *returns* a closure — needs a
  reabstraction thunk that crashes Swift 6.3.3 in IRGen with "SmallVector
  unable to grow. Requested capacity (4294967297)". `ComboEditorView` therefore
  spells out every setter in place and uses a `with { }` helper that returns an
  edited combo rather than a closure. See the comment on that helper.

- **swift-testing search paths live in the Makefile, not `Package.swift`.** They
  have to reach SwiftPM's *generated* runner target, so putting them in the
  manifest's `testTarget` does not work, and Command Line Tools ships no
  `xctest` fallback. Bare `swift test` therefore fails to find the `Testing`
  module. Use `make test`. Revisit if SwiftPM starts searching the active
  developer directory on its own.

- **`BehaviorKind.macroBehavior` can be written but not read back.**
  `BehaviorReader.read` declines `zmk,behavior-macro*` nodes so `MacroReader`
  owns them and `KeymapFile` never lists one node as both a behavior and a
  macro. But `BehaviorKind` still offers `macroBehavior`, so a caller that
  writes a behavior with that `compatible` produces a node the behavior model
  will not see again. `AssistantTools.behaviorKinds` filters it out of
  `set_behavior` and `behaviorKind(_:)` rejects it by name, so the assistant is
  covered — but that is a guard at one call site, not a fix. Either drop the
  case from `BehaviorKind` or route it to `MacroWriter`.

## External

Not this repo, but found while working on it.

- **`buckleypaul/zmk-sweep` has a macro bug.** `#define KEYS_LEFT POS_LH_C1R1 4
  POS_LH_C1R2 14 …` lists both each `POS_*` macro *and* its literal value, so
  every position is doubled in the expansion. It feeds
  `hold-trigger-key-positions` on the homerow mods. Duplicates in a position set
  are harmless, so the keyboard behaves correctly — it is just redundant.
