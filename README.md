# Zmkonfig

A native macOS keymap editor for [ZMK](https://zmk.dev) keyboards — a desktop
take on [nickcoutsos/keymap-editor](https://github.com/nickcoutsos/keymap-editor),
built for a Ferris Sweep (34 keys, 5 layers) but not tied to it.

It opens a ZMK config repository, draws the keyboard from its layout data, lets
you edit bindings on any layer, writes the `.keymap` file back, shows you the
diff, commits and pushes, watches the GitHub Actions build, and flashes the
resulting firmware onto a mounted bootloader volume.

## What it does

1. **Open a repo** — `owner/name`, cloned on first use. The slug you opened
   last is reopened on the next launch.
2. **Pick the layout** — from the repo's own `config/info.json` when it has one,
   otherwise from the remote keyboard catalog (the Sweep is `cradio`).
3. **Edit** — click a key, choose a behavior, fill in one slot per parameter:
   searchable keycode picker, layer list, behavior command list, or a number.
   Modifier toggles wrap a keycode as `LG(LS(X))`.
4. **Save** — writes the keymap, shows the real `git diff`, then commits and
   pushes on your say-so.
5. **Build and flash** — follows the workflow run for the pushed commit, pulls
   its artifacts, and flashes a half onto a bootloader volume after an explicit
   left/right confirmation.

Errors are shown as they came back, the working tree's state is always on
screen, and a build is never reported as succeeding unless it did.

## Requirements

- macOS 15 or later
- Xcode **Command Line Tools** only (`xcode-select --install`) — there is no
  `.xcodeproj` and none is needed
- `git` and `gh` on `PATH` (`gh` provides the GitHub credentials)

## Build and run

```sh
make run      # build, assemble .build/Zmkonfig.app, and launch it
make build    # swift build -c release
make bundle   # assemble the .app without launching
make test     # swift test
make clean
```

`make CONFIG=debug run` does the same with a debug build, which is much faster
to iterate on.

Use `make test` rather than bare `swift test`: with Command Line Tools, SwiftPM
cannot find `Testing.framework` on its own and silently runs zero tests. The
target passes the search paths in for it.

For quick UI work without bundling, `swift run Zmkonfig` also works — the app
sets its own activation policy so the window comes to the front.

## Layout

```
Sources/ZmkonfigKit/      library: model, devicetree parsing, services, theme
  Model/                  KeyBinding, KeyboardLayout, ZMKMetadata
  DeviceTree/             lexer, parser, KeymapFile (surgical edits)
  Services/               Git, RepoManager, LayoutCatalog, GitHubClient, Flasher
  Theme/                  Theme + ThemeEngine
  Resources/              vendored ZMK behavior and keycode metadata
Sources/Zmkonfig/         the app: entry point, models, views
Tests/ZmkonfigKitTests/   parser round-trip and layout fixtures
```

## Theming

The app ships two themes, **Plain** and **Catppuccin**, each with a light and a
dark appearance and both defined as data in
`Sources/ZmkonfigKit/Theme/Theme.swift`. Pick one in Settings (⌘,). No view
names a color, size or font
directly — each one asks the theme for a token (`theme.color(.keycapFill)`,
`theme.metric(.keyUnit)`, `theme.font(.keycapPrimary)`), so a new look is a new
`Theme` value rather than a refactor.

To change it without touching the code, drop a JSON file in
`~/.config/zmkonfig/themes/`. It is layered over the built-in theme, so it only
needs the tokens you want to change:

```json
{
  "name": "Warm",
  "light": { "keycapFill": "#FFFDF7", "accent": "#B4551F" },
  "dark":  { "keycapFill": "#241F1A" },
  "metrics": { "keyUnit": 60 },
  "fonts": { "keycapPrimary": { "size": 16, "weight": "bold" } }
}
```

Colors are `#rrggbb`, `#rrggbbaa`, or `system:<name>` (`system:label`,
`system:accent`, `system:windowBackground`, …) for values that should follow
macOS. Themes are picked up at launch, or via **View → Reload Themes**.
