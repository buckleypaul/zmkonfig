import SwiftUI
import ZmkonfigKit

/// Edits the binding on the selected key. The fields themselves are shared with
/// the combo editor; this view only says which binding they are pointed at.
struct BindingEditorView: View {
    @Environment(\.theme) private var theme
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metric(.spacingL)) {
                if let binding = model.selectedBinding, let index = model.selectedKeyIndex {
                    summary(binding: binding, index: index)
                    BindingFieldsView(model: model, binding: binding, apply: model.apply)
                } else {
                    Hint(text: model.selectedLayer == nil
                         ? "Select a layer, then click a key."
                         : "Click a key on the board to edit its binding.")
                }
            }
            .padding(theme.metric(.spacingM))
        }
    }

    private func summary(binding: KeyBinding, index: Int) -> some View {
        Card {
            VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                SectionLabel(text: "Key \(index) · \(model.selectedLayer?.displayName ?? "")")
                Text(binding.text)
                    .font(theme.font(.mono))
                    .foregroundStyle(theme.color(.primaryText))
                    .textSelection(.enabled)
            }
        }
    }
}
