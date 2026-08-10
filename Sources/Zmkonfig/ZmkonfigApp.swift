import SwiftUI
import ZmkonfigKit

@main
struct ZmkonfigApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var build = BuildModel()
    @State private var llm: LLMModel
    @State private var explain: ExplainModel
    @State private var assistant: AssistantModel
    @State private var themeEngine = ThemeEngine.shared

    init() {
        // `explain` reads the key and model out of `llm`, so it cannot be a
        // plain default and has to be built once the settings model exists.
        // `assistant` needs the app model too — it reads the keymap through
        // tools and applies what the user approves through `AppModel`.
        let settings = LLMModel()
        let app = AppModel()
        _llm = State(initialValue: settings)
        _model = State(initialValue: app)
        _explain = State(initialValue: ExplainModel(llm: settings))
        _assistant = State(initialValue: AssistantModel(llm: settings, app: app))
    }

    /// The editor window's scene id, so the menubar panel can reopen it after
    /// it has been closed.
    static let mainWindowID = "editor"

    var body: some Scene {
        // `Window` rather than `WindowGroup`: there is one editor, and
        // `openWindow` on a group opens a second one rather than raising the
        // one that is already there.
        Window("Zmkonfig", id: Self.mainWindowID) {
            RootView(model: model, build: build, llm: llm, explain: explain, assistant: assistant)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandMenu("Keymap") {
                Button("Open Repository…") { model.isShowingRepoSheet = true }
                    .keyboardShortcut("o")
                Button("Change Keyboard…") {
                    model.isShowingCatalogSheet = true
                    Task { await model.loadCatalog() }
                }
                .disabled(model.repo == nil)

                Divider()

                Button("Reload From Disk") { Task { await model.reloadKeymap() } }
                    .keyboardShortcut("r")
                Button("Save & Review Changes…") { Task { await model.saveAndReview() } }
                    .keyboardShortcut("s")
                    .disabled(model.repo == nil)
            }

            CommandGroup(after: .toolbar) {
                Menu("Theme") {
                    Picker("Appearance", selection: $themeEngine.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)

                    Divider()

                    ForEach(themeEngine.themes) { theme in
                        Button {
                            themeEngine.selectedName = theme.name
                        } label: {
                            if theme.name == themeEngine.selectedName {
                                Label(theme.name, systemImage: "checkmark")
                            } else {
                                Text(theme.name)
                            }
                        }
                    }
                    Divider()
                    Button("Reload From ~/.config/zmkonfig/themes") { themeEngine.reload() }
                    // A theme file that failed to parse should say so rather
                    // than just not appearing.
                    ForEach(themeEngine.loadErrors, id: \.self) { failure in
                        Text(failure).disabled(true)
                    }
                }
            }
        }

        // The keymap at a glance, from anywhere. It outlives the editor window
        // — see `applicationShouldTerminateAfterLastWindowClosed` — so closing
        // the window leaves the layers one click away and Quit is the way out.
        MenuBarExtra("Zmkonfig", systemImage: "keyboard") {
            MenuBarPanelScene(model: model)
        }
        .menuBarExtraStyle(.window)

        // Reached from the app menu and ⌘,. Its own scene, so it carries its
        // own theme rather than the main window's.
        Settings {
            SettingsRootView(llm: llm)
        }
    }
}

/// Wraps the panel so it can hold `openWindow`, which is only available to a
/// view inside a scene.
private struct MenuBarPanelScene: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        MenuBarPanel(model: model, showEditor: showEditor)
            .themedScene()
    }

    /// Raises the editor, reopening it if it was closed — `openWindow` on a
    /// `Window` scene does both.
    private func showEditor() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: ZmkonfigApp.mainWindowID)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from a bare SwiftPM binary (swift run) there is no bundle to
        // set this for us, and the window would open behind everything.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// False so the menubar item survives closing the editor window: the whole
    /// point of it is to be there at any point. Quit is ⌘Q, or the button in
    /// the menubar panel.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
