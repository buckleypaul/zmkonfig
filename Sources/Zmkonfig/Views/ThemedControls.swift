import SwiftUI
import ZmkonfigKit

/// Small shared building blocks. Everything they draw comes from the theme, so
/// none of the feature views need to name a color or a size.

struct SectionLabel: View {
    @Environment(\.theme) private var theme
    let text: String
    /// A glossary term to explain with a `HelpBadge` beside the label. The
    /// badge is part of the label rather than something each caller assembles,
    /// because the row it needs — label, badge, trailing spacer — was being
    /// written out identically wherever a section had a term.
    var term: String?

    var body: some View {
        if let term {
            HStack(spacing: theme.metric(.spacingXS)) {
                label
                HelpBadge(term: term)
                Spacer(minLength: 0)
            }
        } else {
            label
        }
    }

    private var label: some View {
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
    /// Which surface the card is drawn on. The default is the panel surface a
    /// card in the inspector wants; a card on the bare window — the menubar
    /// panel's layer thumbnails — names the content surface so it reads as
    /// raised off the desk rather than level with it.
    var surface: ThemeColorToken = .panelBackground
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(theme.metric(.spacingM))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.metric(.cornerRadiusMedium))
                    .fill(theme.color(surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.metric(.cornerRadiusMedium))
                    .strokeBorder(theme.color(.border), lineWidth: theme.metric(.borderWidth))
            )
    }
}

/// The one way anything in this app becomes a rounded surface: filled with a
/// surface color, clipped to the corner and outlined in `border`.
///
/// Clipped, not just filled: these hold content that runs to their edges — a
/// list, a status strip, a diff — and the corners have to cut it.
///
/// `surface` is optional because the diff card sits on content that already
/// paints its own background; it wants the corner and the outline and no fill.
private struct RoundedSurface: ViewModifier {
    @Environment(\.theme) private var theme
    let surface: ThemeColorToken?
    let radius: ThemeMetricToken

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.metric(radius))
        return content
            .background { if let surface { shape.fill(theme.color(surface)) } }
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(theme.color(.border), lineWidth: theme.metric(.borderWidth))
            )
    }
}

extension View {
    /// One of the window's floating panes.
    ///
    /// The window itself is the desk — `windowBackground`, the darkest surface
    /// in the flavour — and each pane is a rounded card lying on it with
    /// `paneGutter` of bare desk all around. That gap is the whole design: two
    /// panes are told apart by the space between them, never by a hairline they
    /// share, so no card ever draws an edge that is also its neighbour's.
    func paneCard(_ surface: ThemeColorToken) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(RoundedSurface(surface: surface, radius: .cornerRadiusLarge))
    }

    /// The plate the keys mount into: a shallow well set into a pane card, one
    /// step back down the surface ramp from the card around it. Callers pad
    /// their own content — the padding belongs inside the well, not around it.
    func boardWell() -> some View {
        modifier(RoundedSurface(surface: .boardBackground, radius: .cornerRadiusMedium))
    }

    /// A card with no fill of its own: the corner and the outline only, for
    /// content that already paints its own background.
    func outlinedCard() -> some View {
        modifier(RoundedSurface(surface: nil, radius: .cornerRadiusMedium))
    }
}

/// A quieter `Card`: content set into the page rather than raised off it, with
/// no border. For a block of prose that belongs to the field above it — a
/// worked example, a sentence about the binding being edited.
struct ContentBox<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(theme.metric(.spacingS))
            .background(
                RoundedRectangle(cornerRadius: theme.metric(.cornerRadiusSmall))
                    .fill(theme.color(.contentBackground))
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

/// A layer's identity color as a vertical bar, drawn the height of whatever it
/// sits beside. It names *which* layer this is, not that the layer is chosen,
/// so it is drawn whether or not the row it marks is selected — and it is one
/// view so the sidebar row and the board's eyebrow cannot drift apart.
struct LayerAccentBar: View {
    @Environment(\.theme) private var theme
    let layerID: Int

    var body: some View {
        let width = theme.metric(.layerAccentBarWidth)
        // Half the width, so the ends round off completely.
        RoundedRectangle(cornerRadius: width / 2)
            .fill(theme.layerAccent(layerID))
            .frame(width: width)
    }
}

/// The mark a combo that switches layers wears: a dot in the target layer's own
/// accent — the same color that layer's bar carries — so a list of combos reads
/// as "which layer does this go to" at a glance. A combo that does not switch
/// layers, or that names one through a `#define` this editor cannot resolve,
/// draws nothing.
///
/// The tooltip names the layer the way a keycap does, through
/// ``BindingLabel/layerLabel(_:layers:)``, rather than looking the number up
/// separately — the board and the sidebar must agree on what a layer is called.
struct LayerTargetDot: View {
    @Environment(\.theme) private var theme
    let binding: KeyBinding
    let layers: [KeymapLayer]

    var body: some View {
        if let target = KeycapKit.layerTarget(of: binding), let param = binding.params.first {
            StatusDot(color: theme.layerAccent(target))
                .help("Switches to \(BindingLabel.layerLabel(param, layers: layers))")
        }
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
    /// A glossary term to put a `HelpBadge` beside the label for, or nil for a
    /// field with no general explanation to offer.
    var term: String?
    /// The line drawn under the control, or nil to draw none.
    ///
    /// Passed in rather than read from `term`, because the two are not always
    /// the same text: a keymap-defined `&hml` is *explained* by the generic
    /// hold-tap entry the badge opens, but what belongs under the picker is a
    /// description of that node in particular.
    ///
    /// The caption is the point of the pair. A badge only helps someone who
    /// thinks to hover it, and the person who does not know what `&mt` is does
    /// not know there is anything to hover; one line of always-visible prose
    /// under the control is what actually answers the question.
    var summary: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
            SectionLabel(text: label, term: term)
            content
            if let summary {
                Caption(summary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

/// Opens a popover once the pointer has rested on this view, and closes it the
/// moment the pointer leaves.
///
/// The delay is the whole point: without one, dragging the pointer across a
/// toolbar or a column of fields flashes the popover of everything passed on
/// the way. `isHovering` is handed back rather than kept private because both
/// callers restyle themselves while hovered, and a second `.onHover` to learn
/// what this one already knows would be two sources of the same truth.
///
/// The content is a label, not a control. Without `allowsHitTesting(false)` it
/// takes the pointer the moment it opens, the view beneath reads as
/// un-hovered, and the two states chase each other.
extension View {
    func hoverPopover<Content: View>(
        isHovering: Binding<Bool>,
        delay: Duration = .milliseconds(400),
        arrowEdge: Edge = .bottom,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(HoverPopover(isHovering: isHovering, delay: delay, arrowEdge: arrowEdge, popover: content))
    }
}

private struct HoverPopover<Popover: View>: ViewModifier {
    @Binding var isHovering: Bool
    let delay: Duration
    let arrowEdge: Edge
    @ViewBuilder var popover: () -> Popover

    @State private var isShowing = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                if !hovering { isShowing = false }
            }
            // Keyed on the hover state so leaving cancels the pending open
            // rather than letting it land after the pointer has gone.
            .task(id: isHovering) {
                guard isHovering else { return }
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                isShowing = true
            }
            .popover(isPresented: $isShowing, arrowEdge: arrowEdge) {
                popover().allowsHitTesting(false)
            }
    }
}

/// A toolbar button that explains itself in a popover on hover. The button
/// itself never changes size, so the toolbar does not reflow under the pointer.
///
/// This replaces the `help` tooltip rather than adding to it — two explanations
/// of one button appearing a second apart is worse than either alone. The help
/// sentence becomes the accessibility hint, which is where VoiceOver looks for
/// it, so nothing is lost for a user who never hovers.
struct ToolbarActionButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .hoverPopover(isHovering: $isHovering) {
            VStack(alignment: .leading, spacing: theme.metric(.spacingXS)) {
                Text(title)
                    .font(theme.font(.heading))
                    .foregroundStyle(theme.color(.primaryText))
                Text(help)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.color(.secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(theme.metric(.spacingM))
            .frame(width: theme.metric(.dialogWidth) / 2)
        }
        .accessibilityLabel(title)
        .accessibilityHint(help)
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

/// Resolves the theme for the current appearance and hands it to everything
/// below. Every scene — the editor window, Settings, the menubar panel — needs
/// this, because a scene does not inherit another scene's environment; this is
/// the only place the theme is read from the engine.
private struct ThemedScene: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    private let themeEngine = ThemeEngine.shared

    func body(content: Content) -> some View {
        content
            .environment(\.theme, themeEngine.resolved(for: themeEngine.scheme(system: colorScheme)))
            // Forces the appearance on the window's own controls — scrollers,
            // pickers, text fields — which draw themselves and would otherwise
            // stay in the system's appearance while the theme moved. Nil in
            // auto mode, which is what leaves them following macOS.
            .preferredColorScheme(themeEngine.appearance.colorScheme)
    }
}

extension View {
    /// Theme a scene root. Apply it from *outside* the view that reads the
    /// theme: a view cannot see an environment value it sets itself.
    func themedScene() -> some View { modifier(ThemedScene()) }

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
