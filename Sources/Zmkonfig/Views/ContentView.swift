import AppKit
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
    @Bindable var model: AppModel
    @Bindable var build: BuildModel
    let explain: ExplainModel
    let assistant: AssistantModel

    var body: some View {
        SplitLayout {
            SidebarView(model: model)
        } content: {
            BoardPane(model: model)
        } inspector: {
            InspectorPane(model: model, build: build, explain: explain, assistant: assistant)
        }
        .navigationTitle(model.repo?.slug ?? "Zmkonfig")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard let status = model.gitStatus else { return "" }
        var parts = [status.branch]
        if status.isDirty { parts.append("dirty") }
        if model.hasUnsavedEdits { parts.append("unsaved edits") }
        return parts.joined(separator: " · ")
    }
}

/// The three columns, as cards lying on the window's desk.
///
/// Not a `NavigationSplitView`. That draws its own background under each column
/// and a hairline down every boundary, and both fight a layout whose whole
/// claim is that the panes are separate objects with nothing but desk between
/// them. What it was still providing here is a draggable width, which is what
/// `resizer` is — the sidebar never collapsed anyway: it is the layer list, so
/// hiding it leaves the window unnavigable, and `ZmkonfigApp` already takes the
/// View-menu toggle away.
///
/// Widths are remembered in defaults because the split view remembered them.
private struct SplitLayout<Sidebar: View, Content: View, Inspector: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var content: Content
    @ViewBuilder var inspector: Inspector

    /// Zero means "never dragged", which resolves to the ideal width — a stored
    /// default cannot itself be the ideal, because the theme is what says what
    /// that is and a user theme may say something else.
    @AppStorage("layout.sidebarWidth") private var storedSidebarWidth = 0.0
    @AppStorage("layout.inspectorWidth") private var storedInspectorWidth = 0.0

    /// Which column a resizer moves. One piece of drag state covers both, since
    /// only one resizer can be under the pointer at a time.
    private enum Column { case sidebar, inspector }

    /// The drag in progress, or nil.
    ///
    /// The live width lives here rather than in `@AppStorage` because a drag
    /// produces a pointer event per frame and each one would be a `UserDefaults`
    /// write. What the columns are laid out from is this while a drag is on and
    /// the stored default the rest of the time; the default is written once, on
    /// mouse-up.
    @State private var drag: Drag?

    private struct Drag {
        let column: Column
        /// The column's width when the drag began, which every translation is
        /// measured from.
        let anchor: Double
        var width: Double
    }

    var body: some View {
        let gutter = theme.metric(.paneGutter)
        GeometryReader { proxy in
            let widths = resolvedWidths(available: proxy.size.width - 4 * gutter)
            HStack(spacing: 0) {
                sidebar
                    .paneCard(.sidebarBackground)
                    .frame(width: widths.sidebar)

                resizer(
                    .sidebar, from: widths.sidebar, sign: 1,
                    limits: (.sidebarMinWidth, .sidebarMaxWidth)
                ) { storedSidebarWidth = $0 }

                content
                    .paneCard(.contentBackground)
                    .frame(minWidth: theme.metric(.contentMinWidth), maxWidth: .infinity)

                resizer(
                    .inspector, from: widths.inspector, sign: -1,
                    limits: (.inspectorMinWidth, .inspectorMaxWidth)
                ) { storedInspectorWidth = $0 }

                inspector
                    .paneCard(.panelBackground)
                    .frame(width: widths.inspector)
            }
            .padding(gutter)
        }
        .background(theme.color(.windowBackground))
    }

    /// The drag in progress if it is this column's, or nil.
    private func inProgress(_ column: Column) -> Drag? {
        guard let drag, drag.column == column else { return nil }
        return drag
    }

    /// The two fixed column widths for a given amount of room, once the gutters
    /// are already spoken for.
    ///
    /// The content column has a floor and the other two do not get to push it
    /// through: when the window is too narrow for everything, the inspector
    /// gives way first and the sidebar after it. At the window's own minimum
    /// size the three minimums add up to exactly the room available, so that is
    /// as far as it goes.
    private func resolvedWidths(available: CGFloat) -> (sidebar: CGFloat, inspector: CGFloat) {
        let askedSidebar = inProgress(.sidebar)?.width ?? storedSidebarWidth
        let askedInspector = inProgress(.inspector)?.width ?? storedInspectorWidth
        var sidebar = clamp(
            askedSidebar > 0 ? askedSidebar : theme.metric(.sidebarIdealWidth),
            min: theme.metric(.sidebarMinWidth),
            max: theme.metric(.sidebarMaxWidth)
        )
        var inspector = clamp(
            askedInspector > 0 ? askedInspector : theme.metric(.inspectorIdealWidth),
            min: theme.metric(.inspectorMinWidth),
            max: theme.metric(.inspectorMaxWidth)
        )
        let overflow = sidebar + inspector + theme.metric(.contentMinWidth) - available
        if overflow > 0 {
            let fromInspector = Swift.min(overflow, inspector - theme.metric(.inspectorMinWidth))
            inspector -= fromInspector
            sidebar = Swift.max(theme.metric(.sidebarMinWidth), sidebar - (overflow - fromInspector))
        }
        return (sidebar, inspector)
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), upper)
    }

    /// A gutter that can be dragged. It draws nothing — the desk shows through
    /// — so the only sign it is there is the pointer changing over it.
    ///
    /// `sign` is which way the column it resizes grows: the sidebar widens as
    /// the pointer moves right, the inspector as it moves left.
    private func resizer(
        _ column: Column,
        from current: CGFloat,
        sign: CGFloat,
        limits: (min: ThemeMetricToken, max: ThemeMetricToken),
        store: @escaping (Double) -> Void
    ) -> some View {
        Color.clear
            .frame(width: theme.metric(.paneGutter))
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            // Global, not the default local space. The resizer is carried along
            // by the column it is widening, so a translation measured inside it
            // is the pointer's movement minus the movement it just caused — and
            // the column ends up following the pointer at half speed.
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let anchor = inProgress(column)?.anchor ?? Double(current)
                        // Clamped here, so what `onEnded` stores is in range as
                        // well as what `resolvedWidths` reads. Clamping only on
                        // the way out would let a default sit way past the
                        // maximum, and the edge would not move again until it
                        // had been dragged all the way back.
                        drag = Drag(
                            column: column,
                            anchor: anchor,
                            width: clamp(
                                anchor + Double(sign * value.translation.width),
                                min: theme.metric(limits.min), max: theme.metric(limits.max)
                            )
                        )
                    }
                    // The one write to defaults per drag. Until here the live
                    // width is what the columns are laid out from, so nothing
                    // about the resize waits on this.
                    .onEnded { _ in
                        if let width = inProgress(column)?.width { store(width) }
                        drag = nil
                    }
            )
    }
}
