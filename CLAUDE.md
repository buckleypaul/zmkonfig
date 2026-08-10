# CLAUDE.md

## Tracking outstanding work

Known gaps, deferred decisions and things worth revisiting are **GitHub
issues** on `buckleypaul/zmkonfig`, prioritised on the Zmkonfig project board
(`gh project item-list 1 --owner buckleypaul`). `outstanding-work.md` is now
only a signpost to that.

- When you notice undone work, a gap, or a worthwhile suggestion — and you are
  not doing it now — **open an issue**. Say what it is and why it matters, not
  just a title; the body is where the reasoning has to survive.
- Label it with its `area:*` (`parser`, `assistant`, `llm`, `ui`, `build`,
  `testing`), plus `tech-debt`, `toolchain-workaround` or `upstream` if it
  applies. Then `gh project item-add 1 --owner buckleypaul --url <url>` and set
  Priority — P0 blocking, P1 high, P2 medium, P3 low.
- When you finish something, **close the issue** and reference it from the
  commit. Do not leave it open with a "done" comment.
- Issues are for what is *not* done. They are not a running log.

## Building

Command Line Tools only — there is no `.xcodeproj` and none is needed.

```sh
make run     # build, assemble and sign .build/Zmkonfig.app, launch it
make test    # run the suite
make bundle  # assemble without launching
```

`make CONFIG=debug run` is much faster to iterate on. For UI-only work
`swift run Zmkonfig` skips bundling entirely and still finds the kit's resource
bundle, because for a bare executable it sits beside the binary.

**Use `make test`, never bare `swift test`.** swift-testing lives in the active
developer directory, which SwiftPM does not add to the framework search path,
and Command Line Tools ships no `xctest` fallback — `swift test` fails to find
the `Testing` module. The flags cannot live in `Package.swift` because they must
also reach SwiftPM's generated runner target, so they are in the Makefile.

## The one rule that matters

**Never regenerate the `.keymap` file.** The editor parses the devicetree,
locates the byte ranges it means to change, and rewrites only those spans.
Every edit goes through `SourceEdit`, which applies them back to front and
refuses to apply two that overlap. Includes, `#define`s, custom behaviors,
macros, node overrides, comments and hand-tuned formatting must survive byte
for byte.

This is enforced by *"Re-serializing an unedited keymap reproduces it byte for
byte"* in `Tests/ZmkonfigKitTests/KeymapFileTests.swift`: re-serializing an
unedited keymap must reproduce it exactly, and every layer's bindings and every
combo's binding are re-rendered from the parsed model on every save rather than
skipped as unchanged. **Do not weaken that test to make a change pass.** If it
fails, the renderer is wrong.

A combo's *other* properties are the one deliberate exception: they are written
only when they differ from what was parsed. `key-positions` is why —
`<POS_LH_T1 POS_RH_T1>` resolves to no numbers at all, so re-rendering an
untouched combo would replace the macros with an empty list. Combos carry the
tokens they could not resolve in `unresolvedPositions` so the UI can say so.

Binding blocks are re-aligned as the reference editor does it: column width is
`max(7, longest binding in the column + 2)`, left-aligned, trailing whitespace
stripped, and layout columns with no keys still occupy exactly 2 characters —
not the floor of 7. That last rule is what produces the gap between halves on a
split board.

## Layout

```
Sources/ZmkonfigKit/     library — all logic, no UI, unit tested
  DeviceTree/            lexer, parser, KeymapFile, SourceEdit splicing,
                         binding table renderer, combo reader + writer,
                         BehaviorNote — the `/* zmkonfig: … */` description a
                         behavior node carries, and the sanitiser that makes it
                         unable to be anything but a comment
  Model/                 KeyBinding, KeyboardLayout, ZMKMetadata,
                         BindingLabel + ModifierFunction + BindingAlgebra
                         (what a binding means and how it is edited),
                         Glossary — the vendored prose behind every `?` badge;
                         BindingNarrator and BehaviorNarrator say a binding and
                         a keymap-defined behavior out loud from it,
                         BehaviorIndex, BehaviorPropertyShape,
                         KeymapContext — the read-only snapshot AssistantTools
                         (and its ProposedEdit), KeymapDigest and ContextPack
                         run on. ContextPack builds the prompt prefix; every
                         list it emits is sorted, because a prefix that
                         reorders itself between calls cannot be cached.
  Services/              Shell, Git, RepoManager, LayoutCatalog, GitHubClient,
                         Flasher, Keychain, PathComponent,
                         AnthropicClient + AnthropicConversation
  Theme/                 Theme + ThemeEngine
  Resources/             vendored zmk-behaviors.json, zmk-keycodes.json,
                         zmk-glossary.json — hand-written, because upstream
                         ships no machine-readable prose; coverage tests fail
                         when a behavior, kind or property has no entry
Sources/Zmkonfig/        the SwiftUI app
  Model/                 AppModel — repo, keymap, layout, selection
                         BuildModel — push → Actions run → artifact → flash
                         LLMModel — API key, model choice, verification
                         ClaudeRequest — one question and its answer
                         ExplainModel — the prompts, one request per feature
                         AssistantModel — the chat loop and staged proposals
                         (all @MainActor @Observable; views read them, never
                         the services directly)
  Views/                 all SwiftUI views
Tests/ZmkonfigKitTests/  includes the byte-identical round-trip test
```

## Conventions

- Shell out only through `Shell`. Resolve Homebrew-installed binaries by
  absolute path — `/opt/homebrew/bin` is **not** on a Finder-launched app's
  `PATH`, so a bare `gh` works in `swift run` and fails in the bundled app.
  `git` is in `/usr/bin` and is safe.
- Load kit resources through `AppResources`, never `Bundle.module`. SwiftPM
  looks for the bundle beside `Bundle.main.bundleURL`, which inside a .app is
  the bundle root — a place `codesign` refuses to seal. `make bundle` puts it in
  `Contents/Resources` instead and `AppResources.kit` checks both. New kit
  resources go in `Sources/ZmkonfigKit/Resources/` or the bundle check in
  `make bundle` fails.
- No silent failures. Surface real error messages; do not fall back to an empty
  array on error. Where a failure genuinely is expected — a bootloader volume
  vanishing mid-copy means the board took the image and rebooted — say so in a
  comment.
- No view names a color, size or font directly. Ask the theme for a token so a
  new look stays a data change.

## The Anthropic API key

The key is a keychain item, never a file and never a default. It is a generic
password under service `com.buckleypaul.zmkonfig` (`Keychain.defaultService` —
the same bundle id the Makefile signs with, so `swift run` and the bundled app
read the same item) and account `anthropic-api-key`
(`LLMModel.keychainAccount`).

- **The user sets it in Settings.** ⌘, or the app menu → Settings… → Claude.
  Saving verifies against `GET /v1/models` before it writes, so a key the API
  rejects is never stored. There is no environment variable and no config file:
  if a feature says "no key", the answer is always that page.
- **Reach it through `LLMModel.client()`.** Nothing else constructs an
  `AnthropicClient`, and no other type reads the keychain item. A feature that
  needs Claude takes a `ClaudeRequest`, which holds the task, the answer and the
  failure so the view never touches a service.
- **Never print, log, or persist the key.** `UserDefaults` holds the selected
  model id and the cached model list, and nothing else. It must not reach the
  keymap, a commit message, a prompt, or stdout.
- **Debugging: read the attributes, not the secret.**
  `security find-generic-password -s com.buckleypaul.zmkonfig -a anthropic-api-key`
  shows whether an item exists and when it changed, which answers almost every
  question. **Do not add `-w`** — that prints the key itself into the terminal,
  the scrollback, and any transcript recording the session. If a key does get
  exposed that way, say so plainly and tell the user to rotate it at
  console.anthropic.com.
- **Sign with a stable identity or macOS re-asks on every build.** An ad-hoc
  signature gives the app a new code identity each time it is built, the
  keychain stops recognising it, and the login-password prompt comes back —
  "Always Allow" only holds until the next `make`. `CODESIGN_IDENTITY` in the
  Makefile finds a real certificate automatically, preferring a self-signed
  **Zmkonfig Local**, then **Developer ID Application**, then the **Apple
  Development** certificate a free Apple ID already provides; it prints which
  one it used, and warns when it falls back to ad hoc. `make bundle` then
  produces the same designated requirement every time, so one "Always Allow"
  holds for good. Do not "fix" a returning prompt in code; it is a signing
  problem — a genuinely returning prompt means the certificate expired (Apple
  Development certificates last a year) and wants renewing.

  `swift run Zmkonfig` is the exception and always will be: SwiftPM ad-hoc
  signs the bare executable, so that path re-prompts after every rebuild. Use
  `make CONFIG=debug run` for anything that touches the key.

The client itself:

- There is no official Anthropic SDK for Swift, so `AnthropicClient` speaks REST
  over `URLSession`. Two endpoints are used: `GET /v1/models` (which doubles as
  key verification — it fails loudly on a bad key and costs no tokens on a good
  one) and non-streaming `POST /v1/messages`.
- `converse` runs the multi-turn tool loop the assistant needs. A turn that only
  calls tools has no prose, so emptiness is not the end condition — the loop
  ends when `toolUses` comes back empty. A turn that stops on `max_tokens` may
  have a half-written `tool_use` as its last block; that is reported as
  truncation and stops the loop rather than being run.
- A refusal is an HTTP **200** with empty content and `stop_reason: "refusal"`.
  It is checked before the content is read, because otherwise it reads as a
  successful empty answer.
- Thinking is on by default on current models and its blocks carry no text, so
  only `type == "text"` blocks are read.
- Model ids are user-chosen at runtime, so do not send parameters that only some
  models accept (`output_config.effort`, `fallbacks`, `thinking`) — a key set to
  Haiku would start 400ing.

**No model output may become devicetree.** `ExplainModel` mostly returns prose
nobody keeps — a `KeymapLayer` or a diff string in, paragraphs out. The
assistant does propose changes, and the safety story there is structural, not a
matter of prompting: its edit tools only hand an `AssistantTools.ProposedEdit`
back to `AssistantModel`, the proposal sits in the transcript until the user
presses Apply, and applying runs `AppModel.applyProposal` → `KeymapFile`
mutators → `SourceEdit` like every other edit. **No case of `ProposedEdit`
carries devicetree text, and none may be added that does** — that is what makes
splicing model output impossible rather than merely discouraged.

There is exactly one path by which model output does reach the file, and it is
deliberate: `ExplainModel.describeBehavior` drafts a behavior's description, the
user presses **Use this** to put it in the Description field, and saving writes
it as the `/* zmkonfig: … */` comment `BehaviorNote` owns. It is held to the
same standard rather than exempted from it. Everything on the way in goes
through **`BehaviorNote.sanitized`, whose output can contain neither `*/` nor
`/*`** — a `*` is never allowed to be followed by a `/`, so text inside the
comment cannot close it, and therefore cannot become devicetree. That invariant
is the whole permission slip, it is tested directly in `BehaviorNoteTests`, and
weakening it turns a description field into an injection site. A note is also
never written by the app on its own: drafting fills a field, and the user saves.

## Committing

Hand commits off to a Haiku subagent — the `Agent` tool with `model: haiku` —
rather than doing them inline. Commit messages are not worth deliberating over
here: a short summary of what changed is enough, and it does not need drafting
or review before it lands. Spend the care on the code, not the history.
