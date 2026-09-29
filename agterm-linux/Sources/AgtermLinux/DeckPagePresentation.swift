import CGtk
import Foundation

@MainActor
func makeTerminalDeck() -> OpaquePointer {
    guard let deck = OpaquePointer(gtk_overlay_new()),
          let base = OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)) else {
        preconditionFailure("GTK failed to allocate the terminal deck")
    }
    gtk_widget_set_hexpand(W(base), 1)
    gtk_widget_set_vexpand(W(base), 1)
    gtk_overlay_set_child(deck, W(base))
    return deck
}

struct DeckPagePresentation: Equatable {
    let childVisible: Bool
    let opacity: Double
    let canTarget: Bool

    init(isActive: Bool, dashboardOpen: Bool) {
        childVisible = isActive || dashboardOpen
        opacity = isActive || dashboardOpen ? 1 : 0
        canTarget = isActive && !dashboardOpen
    }

    /// A page is active only while a session is selected: a nil `activeID` — the visible tree names no
    /// session, which is what soft-closing the LAST one leaves behind while its surfaces are held for the
    /// undo — makes EVERY page inactive instead of keeping the previous selection on screen and targetable.
    init(pageID: UUID, activeID: UUID?, dashboardOpen: Bool) {
        self.init(isActive: activeID == pageID, dashboardOpen: dashboardOpen)
    }
}
