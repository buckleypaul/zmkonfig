import SwiftUI
import ZmkonfigKit

/// The right-hand column: edit whatever the sidebar and board have selected —
/// a key or a combo — or drive a build and flash.
struct InspectorPane: View {
    @Environment(\.theme) private var theme
    @Bindable var model: AppModel
    let build: BuildModel
    let explain: ExplainModel
    let assistant: AssistantModel

    @State private var tab: Tab = .edit

    enum Tab: String, CaseIterable, Identifiable {
        case edit
        case explain
        case build
        case assistant
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                ForEach(Tab.allCases) { option in
                    Text(title(of: option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(theme.metric(.spacingM))

            Divider()

            switch tab {
            case .edit:
                if let combo = model.selectedCombo {
                    ComboEditorView(model: model, combo: combo)
                } else {
                    BindingEditorView(model: model)
                }
            case .explain:
                ExplainPanelView(model: model, explain: explain)
            case .build:
                BuildPanelView(model: model, build: build)
            case .assistant:
                AssistantPanelView(model: model, assistant: assistant)
            }
        }
        .background(theme.color(.panelBackground))
        // Selecting a combo while the build tab is open would otherwise leave
        // the edit it just made out of sight.
        .onChange(of: model.selectedComboID) { _, id in
            if id != nil { tab = .edit }
        }
    }

    private func title(of tab: Tab) -> String {
        switch tab {
        // The first tab edits whichever thing is selected, so it says which one
        // that is rather than always claiming to be a key.
        case .edit: model.selectedCombo == nil ? "Key" : "Combo"
        case .explain: "Explain"
        case .build: "Build"
        case .assistant: "Assist"
        }
    }
}
