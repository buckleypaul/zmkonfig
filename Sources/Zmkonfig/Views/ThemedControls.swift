import SwiftUI
import ZmkonfigKit

/// Small shared building blocks. Everything they draw comes from the theme, so
/// none of the feature views need to name a color or a size.

struct SectionLabel: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(theme.font(.sectionLabel))
            .kerning(0.6)
            .foregroundStyle(theme.color(.tertiaryText))
    }
}

/// The title line of a sheet or dialog. Every sheet draws one the same way.
struct SheetTitle: View {
    @Environment(\.theme) private var theme
    let text: String

    /// Unlabelled, as `Text` is.
    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(theme.font(.title))
            .foregroundStyle(theme.color(.primaryText))
    }
}

struct Card<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(theme.metric(.spacingM))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.metric(.cornerRadiusMedium))
                    .fill(theme.color(.panelBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.metric(.cornerRadiusMedium))
                    .strokeBorder(theme.color(.border), lineWidth: theme.metric(.borderWidth))
            )
    }
}

struct Badge: View {
    @Environment(\.theme) private var theme
    let text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(theme.font(.caption))
            .foregroundStyle(tint ?? theme.color(.badgeText))
            .padding(.horizontal, theme.metric(.spacingS))
            .padding(.vertical, 2)
            .background(
                Capsule().fill(tint?.opacity(0.14) ?? theme.color(.badgeBackground))
            )
    }
}

struct StatusDot: View {
    @Environment(\.theme) private var theme
    let color: Color

    var body: some View {
        let size = theme.metric(.statusDotSize)
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// Secondary text, which is most of the text in the app. Naming the tone rather
/// than the color keeps the caption style in one place.
struct Caption: View {
    @Environment(\.theme) private var theme
    let text: String
    var tone: ThemeColorToken = .secondaryText

    /// Unlabelled, as `Text` is — this stands in for `Text` at ~30 call sites.
    init(_ text: String, tone: ThemeColorToken = .secondaryText) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(theme.font(.caption))
            .foregroundStyle(theme.color(tone))
    }
}

struct Hint: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Caption(text)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(theme.metric(.spacingL))
    }
}

/// A field label / value pair used throughout the inspector.
struct FieldRow<Content: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
            SectionLabel(text: label)
            content
        }
    }
}

/// A text field that only reports values that parse as an integer.
struct IntegerField: View {
    @Environment(\.theme) private var theme
    let value: String
    let onCommit: (String) -> Void

    @State private var text = ""

    var body: some View {
        TextField("0", text: $text)
            .font(theme.font(.mono))
            .frame(maxWidth: theme.metric(.numericFieldWidth))
            .onAppear { text = value }
            .onChange(of: value) { _, latest in
                if latest != text { text = latest }
            }
            .onChange(of: text) { _, latest in
                if Int(latest) != nil, latest != value { onCommit(latest) }
            }
    }
}

/// A monospaced field for a value the model normalizes: a binding, a cell of
/// tokens.
///
/// A plain `Binding` cannot be used for these. `&kp  A` is stored as a parsed
/// binding and reads back as `&kp A`, so the value the field is bound to changes
/// under the cursor on the keystroke after the one that caused it — the second
/// space vanishes as it is typed, and text that does not parse at all is
/// rejected and snaps back mid-word. So while the field has focus it shows what
/// the user typed and nothing else; it takes the model's own spelling when the
/// field is left, and any change from elsewhere while it is not focused.
struct NormalizingField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    let value: String
    let onChange: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .font(theme.font(.mono))
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onAppear { text = value }
            .onChange(of: value) { _, latest in
                guard !isFocused, latest != text else { return }
                text = latest
            }
            .onChange(of: isFocused) { _, focused in
                // Leaving shows what the model actually holds, which is how the
                // user finds out that what they typed did not parse.
                if !focused, text != value { text = value }
            }
            .onChange(of: text) { _, latest in
                guard latest != value else { return }
                onChange(latest)
            }
    }
}

/// A property that a keymap node can simply leave out. Unchecked means the
/// property is not written at all and ZMK's own default applies, which is not
/// the same as writing that default down.
struct OptionalIntegerField: View {
    @Environment(\.theme) private var theme
    let label: String
    let placeholder: Int
    let value: Int?
    let onChange: (Int?) -> Void

    var body: some View {
        HStack(spacing: theme.metric(.spacingS)) {
            Toggle(label, isOn: Binding(
                get: { value != nil },
                set: { onChange($0 ? placeholder : nil) }
            ))
            .toggleStyle(.checkbox)
            .font(theme.font(.body))

            if let value {
                IntegerField(value: String(value), onCommit: { onChange(Int($0)) })
            } else {
                Caption("ZMK default", tone: .tertiaryText)
            }
            Spacer(minLength: 0)
        }
    }
}

/// An inline warning strip: visible, but not a modal.
struct WarningStrip: View {
    @Environment(\.theme) private var theme
    let text: String
    var tone: ThemeColorToken = .warning

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.metric(.spacingS)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(theme.font(.caption))
            Text(text)
                .font(theme.font(.caption))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.color(tone))
        .padding(.horizontal, theme.metric(.spacingM))
        .padding(.vertical, theme.metric(.spacingS))
        .background(
            RoundedRectangle(cornerRadius: theme.metric(.cornerRadiusSmall))
                .fill(theme.color(tone).opacity(0.12))
        )
    }
}

extension View {
    /// The one way an `AppError` is put in front of the user: an alert carrying
    /// the error's own title and message, which clears it when dismissed.
    func errorAlert(_ error: Binding<AppError?>, fallbackTitle: String) -> some View {
        alert(
            error.wrappedValue?.title ?? fallbackTitle,
            isPresented: Binding(
                get: { error.wrappedValue != nil },
                set: { if !$0 { error.wrappedValue = nil } }
            ),
            presenting: error.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) { error.wrappedValue = nil }
        } message: { presented in
            Text(presented.message)
        }
    }
}
