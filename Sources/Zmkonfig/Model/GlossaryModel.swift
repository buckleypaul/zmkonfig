import Observation
import SwiftUI
import ZmkonfigKit

/// What the glossary window is showing.
///
/// Separate from ``AppModel`` because none of it is about the keymap: closing
/// the repo, or having none open at all, does not change what `&kp` means. It
/// is also what lets a help badge anywhere in the editor say "open the glossary
/// at *this* term" without every view in between having to pass the selection
/// down.
@MainActor
@Observable
final class GlossaryModel {
    /// The scene id the app registers the window under.
    static let windowID = "glossary"

    /// The entry the window has open, by ``GlossaryEntry/term``. Nil until
    /// something is picked, which is the state the window opens in when it is
    /// summoned from the menu rather than from a badge.
    var selectedTerm: String?
    var query = ""

    /// Points the window at a term and asks for it to be opened.
    ///
    /// The order matters: the selection is set before the window is asked for,
    /// so a window that was already open changes what it is showing in the same
    /// frame it comes forward, rather than flashing its previous entry.
    func show(_ term: String, using openWindow: OpenWindowAction) {
        // A search still narrowing the list to something else would hide the
        // entry we were just asked to show.
        query = ""
        selectedTerm = term
        openWindow(id: Self.windowID)
    }
}

// MARK: - Environment

/// The glossary itself, put in the environment so that a help badge deep in a
/// view tree does not need it threaded through every view above it. There is
/// one glossary for the whole app and it never changes after launch, which is
/// exactly what the environment is for.
private struct GlossaryEnvironmentKey: EnvironmentKey {
    static let defaultValue: Glossary = .empty
}

extension EnvironmentValues {
    var glossary: Glossary {
        get { self[GlossaryEnvironmentKey.self] }
        set { self[GlossaryEnvironmentKey.self] = newValue }
    }
}
