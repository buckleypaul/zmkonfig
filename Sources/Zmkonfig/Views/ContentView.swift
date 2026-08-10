import SwiftUI
import ZmkonfigKit

/// The editor window's scene root. `themedScene` is what resolves the theme for
/// everything below it.
struct RootView: View {
    @Bindable var model: AppModel
    @Bindable var build: BuildModel
    @Bindable var llm: LLMModel
    let explain: ExplainModel
    let assistant: AssistantModel

    var body: some View {
        content.themedScene()
    }

    private var content: some View {
        ContentView(model: model, build: build, explain: explain, assistant: assistant)
            .task { await model.bootstrap() }
            // Reads the saved API key, which is what asks macOS for keychain
            // access. Doing it here means one prompt as the app opens rather
            // than one part-way through a commit.
            .task { llm.loadIfNeeded() }
            .sheet(isPresented: $model.isShowingRepoSheet) {
                RepoSheet(model: model)
            }
            .sheet(isPresented: $model.isShowingCatalogSheet) {
                CatalogSheet(model: model)
            }
            .sheet(isPresented: $model.isShowingSaveSheet) {
                SaveSheet(model: model, explain: explain) { sha in
                    guard let slug = model.repo?.slug else { return }
                    build.watch(slug: slug, headSHA: sha)
                }
            }
            .errorAlert($model.error, fallbackTitle: "Something went wrong")
            .errorAlert($build.error, fallbackTitle: "Build error")
            // A keychain read that fails at launch would otherwise be invisible
            // here: the settings window is the only other place it is shown,
            // and the features it gates just quietly would not appear.
            .errorAlert($llm.error, fallbackTitle: "Keychain error")
    }
}

struct ContentView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    @Bindable var build: BuildModel
    let explain: ExplainModel
    let assistant: AssistantModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(
                    min: theme.metric(.sidebarMinWidth),
                    ideal: theme.metric(.sidebarIdealWidth),
                    max: theme.metric(.sidebarMaxWidth)
                )
        } content: {
            BoardPane(model: model)
                .navigationSplitViewColumnWidth(
                    min: theme.metric(.contentMinWidth),
                    ideal: theme.metric(.contentIdealWidth)
                )
        } detail: {
            InspectorPane(model: model, build: build, explain: explain, assistant: assistant)
                .navigationSplitViewColumnWidth(
                    min: theme.metric(.inspectorMinWidth),
                    ideal: theme.metric(.inspectorIdealWidth),
                    max: theme.metric(.inspectorMaxWidth)
                )
        }
        .navigationTitle(model.repo?.slug ?? "Zmkonfig")
        .navigationSubtitle(subtitle)
        .background(theme.color(.windowBackground))
    }

    private var subtitle: String {
        guard let status = model.gitStatus else { return "" }
        var parts = [status.branch]
        if status.isDirty { parts.append("dirty") }
        if model.hasUnsavedEdits { parts.append("unsaved edits") }
        return parts.joined(separator: " · ")
    }
}
