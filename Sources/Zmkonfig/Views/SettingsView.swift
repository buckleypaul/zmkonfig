import SwiftUI
import ZmkonfigKit

/// The `Settings` scene. Its own root, because a settings window is a separate
/// scene and does not inherit the main window's theme environment.
struct SettingsRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var llm: LLMModel

    private let themeEngine = ThemeEngine.shared

    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ClaudeSettingsView(llm: llm)
                .tabItem { Label("Claude", systemImage: "sparkles") }
        }
        .environment(\.theme, themeEngine.resolved(for: themeEngine.scheme(system: colorScheme)))
        .preferredColorScheme(themeEngine.appearance.colorScheme)
        .errorAlert($llm.error, fallbackTitle: "Keychain error")
    }
}

/// Light/dark/auto and which theme supplies the two palettes.
struct AppearanceSettingsView: View {
    @Environment(\.theme) private var theme

    @Bindable private var themeEngine = ThemeEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingL)) {
            FieldRow(label: "Mode") {
                Picker("Mode", selection: $themeEngine.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: theme.metric(.dialogWidth))
                Caption("Auto follows macOS. Light and dark pin the app regardless of what the system does.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            FieldRow(label: "Theme") {
                Picker("Theme", selection: $themeEngine.selectedName) {
                    ForEach(themeEngine.themes) { candidate in
                        Text(candidate.name).tag(candidate.name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: theme.metric(.dialogWidth))
                Caption(
                    """
                    Zmkonfig ships with Catppuccin — Latte in light, Frappé in dark. \
                    Drop a JSON file in ~/.config/zmkonfig/themes to add your own.
                    """
                )
                .fixedSize(horizontal: false, vertical: true)
            }

            // A theme file that failed to parse should say so rather than just
            // not appearing in the picker.
            ForEach(themeEngine.loadErrors, id: \.self) { failure in
                WarningStrip(text: failure, tone: .danger)
            }

            HStack {
                Spacer()
                Button("Reload Themes") { themeEngine.reload() }
            }
        }
        .padding(theme.metric(.spacingL))
        .frame(width: theme.metric(.sheetWidthMedium))
        .background(theme.color(.panelBackground))
    }
}

/// API key and model for Anthropic's API. Saving verifies the key before it is
/// stored, so a key that is never going to work is never kept.
struct ClaudeSettingsView: View {
    @Environment(\.theme) private var theme
    @Bindable var llm: LLMModel

    @State private var isKeyVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingL)) {
            FieldRow(label: "API key") {
                HStack(spacing: theme.metric(.spacingS)) {
                    keyField
                    Button {
                        isKeyVisible.toggle()
                    } label: {
                        Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(isKeyVisible ? "Hide the key" : "Show the key")
                }
                Caption(
                    """
                    Stored in your login keychain, never in the keymap or in \
                    Zmkonfig's preferences. Create one at console.anthropic.com.
                    """
                )
                .fixedSize(horizontal: false, vertical: true)
            }

            FieldRow(label: "Model") {
                Picker("Model", selection: $llm.selectedModelID) {
                    ForEach(llm.models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: theme.metric(.dialogWidth))
                Caption(
                    llm.isConfigured
                        ? "The models this key can use, read from the API when it was verified."
                        : "Common models. Save a key to replace this with what your key can actually use."
                )
                .fixedSize(horizontal: false, vertical: true)
            }

            status

            HStack(spacing: theme.metric(.spacingS)) {
                Button("Forget key") { llm.forget() }
                    .disabled(!llm.isConfigured)
                Spacer()
                if llm.verification == .verifying {
                    ProgressView().controlSize(.small)
                }
                Button("Save") { Task { await llm.saveAndVerify() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(theme.metric(.spacingL))
        // Width only: a settings pane sizes itself to what it holds, and a
        // fixed height would leave the buttons stranded at the bottom.
        .frame(width: theme.metric(.sheetWidthMedium))
        .background(theme.color(.panelBackground))
        .onAppear { llm.load() }
    }

    @ViewBuilder
    private var keyField: some View {
        // A `SecureField` and a `TextField` are different views, so the toggle
        // swaps one for the other rather than changing a style.
        if isKeyVisible {
            TextField("sk-ant-…", text: $llm.apiKeyDraft)
                .textFieldStyle(.roundedBorder)
                .font(theme.font(.mono))
                .onSubmit { save() }
        } else {
            SecureField("sk-ant-…", text: $llm.apiKeyDraft)
                .textFieldStyle(.roundedBorder)
                .font(theme.font(.mono))
                .onSubmit { save() }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch llm.verification {
        case .idle:
            if llm.isConfigured {
                statusLine(
                    icon: "key.fill",
                    text: "A key is saved. Save again to re-check it.",
                    tone: .secondaryText
                )
            }
        case .verifying:
            statusLine(icon: "arrow.triangle.2.circlepath", text: "Verifying…", tone: .secondaryText)
        case .verified(let count):
            statusLine(
                icon: "checkmark.circle.fill",
                text: "Verified — \(count) model\(count == 1 ? "" : "s") available.",
                tone: .success
            )
        case .failed(let message):
            WarningStrip(text: message, tone: .danger)
        }
    }

    private func statusLine(icon: String, text: String, tone: ThemeColorToken) -> some View {
        HStack(spacing: theme.metric(.spacingS)) {
            Image(systemName: icon)
                .font(theme.font(.caption))
                .foregroundStyle(theme.color(tone))
            Caption(text, tone: tone)
        }
    }

    private var canSave: Bool {
        guard llm.verification != .verifying else { return false }
        return !llm.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard canSave else { return }
        Task { await llm.saveAndVerify() }
    }
}
