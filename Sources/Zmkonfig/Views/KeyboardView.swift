import SwiftUI
import ZmkonfigKit

/// How small the board may be drawn. A thumbnail has to shrink far below the
/// editor's floor — a 42-key board in a menubar cell lands around 0.15 — and
/// clamping it there would push the board out of its cell instead of fitting.
enum BoardDensity {
    case editor
    case thumbnail

    var minScaleToken: ThemeMetricToken {
        switch self {
        case .editor: .boardMinScale
        case .thumbnail: .boardThumbnailMinScale
        }
    }
}

/// Draws the physical keyboard from `KeyPosition` coordinates and scales the
/// whole board to fit whatever room it is given.
struct KeyboardView: View {
    @Environment(\.theme) private var theme
    /// Read from the environment rather than passed in: the board is drawn from
    /// four callers, none of which is otherwise interested in what a binding
    /// means, and the glossary is the same for all of them.
    @Environment(\.glossary) private var glossary

    let layout: [KeyPosition]
    let bindings: [KeyBinding]
    let layers: [KeymapLayer]
    let behaviors: BehaviorIndex
    var selectedIndex: Int? = nil
    var highlightedIndices: Set<Int> = []
    /// Nil for a board that cannot be clicked. That also drops the per-key
    /// gesture and tooltip, which a thumbnail's keycaps are far too small to
    /// aim at anyway.
    var onSelect: ((Int) -> Void)? = nil
    var density: BoardDensity = .editor

    var body: some View {
        GeometryReader { proxy in
            let unit = theme.metric(.keyUnit)
            let bounds = Self.bounds(of: layout)
            let boardSize = CGSize(width: bounds.width * unit, height: bounds.height * unit)
            let scale = Self.scale(
                board: boardSize,
                available: proxy.size,
                min: theme.metric(density.minScaleToken),
                max: theme.metric(.boardMaxScale)
            )

            // Below the editor's own floor the board is a thumbnail: a 2pt
            // reveal and a 4pt shadow land on a fraction of a pixel each and
            // come back as mud, so those caps are drawn flat. The editor is
            // clamped to `boardMinScale`, so it always sculpts.
            let sculpted = scale >= theme.metric(.boardMinScale)

            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.enumerated()), id: \.offset) { index, position in
                    keycap(index: index, position: position, sculpted: sculpted)
                        .frame(width: position.width * unit, height: position.height * unit)
                        .rotationEffect(
                            .degrees(position.r ?? 0),
                            anchor: Self.rotationAnchor(for: position)
                        )
                        .offset(
                            x: (position.x - bounds.minX) * unit,
                            y: (position.y - bounds.minY) * unit
                        )
                }
            }
            .frame(width: boardSize.width, height: boardSize.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: boardSize.width * scale, height: boardSize.height * scale, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func keycap(index: Int, position: KeyPosition, sculpted: Bool) -> some View {
        let binding = bindings.indices.contains(index) ? bindings[index] : nil
        KeycapView(
            label: binding.map {
                BindingLabel.make($0, behavior: behaviors.behavior(for: $0.behavior), layers: layers)
            },
            // A position with no binding at all is drawn as a ghost, which has
            // no kit; `.mods` is the same answer the empty behaviors give.
            kit: binding.map(KeycapKit.of) ?? .mods,
            isSelected: selectedIndex == index,
            isHighlighted: highlightedIndices.contains(index),
            isSculpted: sculpted,
            inset: theme.metric(.keyInset),
            // `&mo`, `&lt`, `&tog`, `&sl`, `&to` — nil for anything else, or
            // for a target this editor cannot resolve to a number.
            targetLayerID: binding.flatMap(KeycapKit.layerTarget(of:))
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect?(index) }
        // A sentence, not the binding text. Hovering a key used to show the
        // exact string — `&mt LCTRL A` — that the person hovering it did not
        // understand; the text is still there, on the line underneath.
        .help(onSelect == nil ? "" : help(for: binding, at: index))
        .allowsHitTesting(onSelect != nil)
    }

    private func help(for binding: KeyBinding?, at index: Int) -> String {
        guard let binding else { return "position \(index) — no binding in this layer" }
        return BindingNarrator.keyDescription(
            for: binding,
            behavior: behaviors.behavior(for: binding.behavior),
            layers: layers,
            glossary: glossary
        )
    }

    // MARK: - Geometry

    static func bounds(of layout: [KeyPosition]) -> (minX: Double, minY: Double, width: Double, height: Double) {
        guard !layout.isEmpty else { return (0, 0, 1, 1) }
        let minX = layout.map(\.x).min() ?? 0
        let minY = layout.map(\.y).min() ?? 0
        let maxX = layout.map { $0.x + $0.width }.max() ?? 1
        let maxY = layout.map { $0.y + $0.height }.max() ?? 1
        return (minX, minY, max(maxX - minX, 1), max(maxY - minY, 1))
    }

    static func scale(board: CGSize, available: CGSize, min minScale: CGFloat, max maxScale: CGFloat) -> CGFloat {
        guard board.width > 0, board.height > 0, available.width > 0, available.height > 0 else { return 1 }
        let fit = Swift.min(available.width / board.width, available.height / board.height)
        return Swift.max(minScale, Swift.min(maxScale, fit))
    }

    /// `r` rotates around (`rx`, `ry`) in board units; SwiftUI wants that as a
    /// unit point inside the key's own frame.
    static func rotationAnchor(for position: KeyPosition) -> UnitPoint {
        let originX = position.rx ?? position.x
        let originY = position.ry ?? position.y
        return UnitPoint(
            x: (originX - position.x) / position.width,
            y: (originY - position.y) / position.height
        )
    }
}

/// One key, drawn as the object it is: a top face standing on a wall, with a
/// shadow on the plate under it.
///
/// The extrusion is two rounded rectangles, not a gradient. The wall fills the
/// cap's whole footprint; the top face is the same rectangle inset by
/// `keycapTopInset` and lifted by `keycapTopShift`, so the reveal along the
/// bottom edge is deeper than the one along the top and the eye reads height.
/// The legends ride up with the face they are printed on.
struct KeycapView: View {
    @Environment(\.theme) private var theme

    let label: BindingLabel.Label?
    let kit: KeycapKit
    let isSelected: Bool
    let isHighlighted: Bool
    /// False when the board is drawn too small for the sculpt to survive being
    /// scaled down — see `KeyboardView`. Such a cap is a flat outlined
    /// rectangle, which is what a thumbnail wants anyway.
    let isSculpted: Bool
    let inset: CGFloat
    /// The layer this key switches to — `&mo`, `&lt`, `&tog`, `&sl`, `&to` —
    /// or nil for a key that does not target one. Nil is also what a target
    /// this editor cannot resolve to a number looks like; such a key is drawn
    /// exactly as an ordinary mod, because there is no layer to point at.
    var targetLayerID: Int? = nil

    var body: some View {
        legends
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { cap }
            // Behind the cap, so only the bleed shows: the light is under the
            // key, not on it. Layout-neutral, so the blur spills across the
            // gap onto the plate instead of pushing the board around.
            .background { halo }
            .padding(inset)
    }

    private var legends: some View {
        VStack(spacing: theme.metric(.keycapLabelSpacing)) {
            if let hold = label?.hold {
                Text(hold)
                    .font(theme.font(.keycapSecondary))
                    .foregroundStyle(layerAccent ?? theme.color(.keycapSubtext))
                    .lineLimit(1)
                    .minimumScaleFactor(theme.metric(.keycapSecondaryMinScale))
            }
            Text(label?.tap ?? "—")
                .font(theme.font(.keycapPrimary))
                .foregroundStyle(layerAccent ?? textColor)
                .lineLimit(1)
                .minimumScaleFactor(theme.metric(.keycapMinScale))
        }
        .padding(.horizontal, theme.metric(.keycapPadding))
        .offset(y: isFlat ? 0 : -theme.metric(.keycapTopShift))
    }

    @ViewBuilder
    private var cap: some View {
        let radius = theme.metric(.keyCornerRadius)
        let shape = RoundedRectangle(cornerRadius: radius)
        if isFlat {
            shape
                .fill(topFill)
                .overlay(shape.strokeBorder(theme.color(.keycapStroke), lineWidth: theme.metric(.borderWidth)))
        } else {
            let topInset = theme.metric(.keycapTopInset)
            shape
                .fill(theme.color(.keycapSide))
                // The cap's silhouette is the wall's, so this is the whole of
                // the cap's shadow — and the only shadow in the app.
                .shadow(
                    color: theme.color(.keycapShadow),
                    radius: theme.metric(.keycapShadowRadius),
                    x: 0,
                    y: theme.metric(.keycapShadowYOffset)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: max(radius - topInset, 1))
                        .fill(topFill)
                        .padding(topInset)
                        .offset(y: -theme.metric(.keycapTopShift))
                }
        }
    }

    @ViewBuilder
    private var halo: some View {
        if let glow = glowColor {
            RoundedRectangle(cornerRadius: theme.metric(.keyCornerRadius))
                .fill(glow)
                .blur(radius: theme.metric(.underglowBlur))
        }
    }

    /// A key is "quiet" when it holds nothing: `&trans`, `&none`, or a position
    /// the current layer has no binding for at all.
    private var isQuiet: Bool { label?.kind != .normal }

    /// Drawn as a ghosted outline rather than an object, for either of two
    /// reasons: a cap with nothing on it is a hole in the keyset and not a key,
    /// so the board's raised silhouette is only ever the keys that are really
    /// there; and a board too small to sculpt has nowhere to put the reveal.
    private var isFlat: Bool { isQuiet || !isSculpted }

    private var topFill: Color {
        if isSelected { return theme.color(.keycapSelectedFill) }
        if isQuiet { return theme.color(.keycapEmptyFill) }
        return theme.color(kit == .mods ? .keycapModFill : .keycapFill)
    }

    private var textColor: Color {
        isQuiet ? theme.color(.keycapEmptyText) : theme.color(.keycapText)
    }

    /// The layer this key switches to, drawn as a color rather than a
    /// position — nil for anything that is not a layer-switching binding.
    private var layerAccent: Color? {
        targetLayerID.map(theme.layerAccent)
    }

    private var glowColor: Color? {
        // A layer-switch key's own halo points at where it goes, not at the
        // generic "this is selected" blue every other key uses.
        if isSelected {
            return targetLayerID.map { theme.layerAccentGlow($0) } ?? theme.color(.underglow)
        }
        if isHighlighted { return theme.color(.keycapHighlight) }
        return nil
    }
}
