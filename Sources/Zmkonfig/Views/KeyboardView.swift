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

            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.enumerated()), id: \.offset) { index, position in
                    keycap(index: index, position: position)
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
    private func keycap(index: Int, position: KeyPosition) -> some View {
        let binding = bindings.indices.contains(index) ? bindings[index] : nil
        KeycapView(
            label: binding.map {
                BindingLabel.make($0, behavior: behaviors.behavior(for: $0.behavior), layers: layers)
            },
            source: binding?.text,
            isSelected: selectedIndex == index,
            isHighlighted: highlightedIndices.contains(index),
            inset: theme.metric(.keyInset)
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

struct KeycapView: View {
    @Environment(\.theme) private var theme

    let label: BindingLabel.Label?
    let source: String?
    let isSelected: Bool
    let isHighlighted: Bool
    let inset: CGFloat

    var body: some View {
        let radius = theme.metric(.keyCornerRadius)
        VStack(spacing: theme.metric(.keycapLabelSpacing)) {
            if let hold = label?.hold {
                Text(hold)
                    .font(theme.font(.keycapSecondary))
                    .foregroundStyle(theme.color(.keycapSubtext))
                    .lineLimit(1)
                    .minimumScaleFactor(theme.metric(.keycapSecondaryMinScale))
            }
            Text(label?.tap ?? "—")
                .font(theme.font(.keycapPrimary))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .minimumScaleFactor(theme.metric(.keycapMinScale))
        }
        .padding(.horizontal, theme.metric(.keycapPadding))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: radius).fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(strokeColor, lineWidth: strokeWidth)
        )
        .padding(inset)
    }

    /// A key is "quiet" when it holds nothing: `&trans`, `&none`, or a position
    /// the current layer has no binding for at all.
    private var isQuiet: Bool { label?.kind != .normal }

    private var fillColor: Color {
        if isSelected { return theme.color(.keycapSelectedFill) }
        return isQuiet ? theme.color(.keycapEmptyFill) : theme.color(.keycapFill)
    }

    private var textColor: Color {
        isQuiet ? theme.color(.keycapEmptyText) : theme.color(.keycapText)
    }

    private var strokeColor: Color {
        if isSelected { return theme.color(.keycapSelectedStroke) }
        if isHighlighted { return theme.color(.keycapHighlightStroke) }
        return theme.color(.keycapStroke)
    }

    private var strokeWidth: CGFloat {
        (isSelected || isHighlighted) ? theme.metric(.borderWidthSelected) : theme.metric(.borderWidth)
    }
}
