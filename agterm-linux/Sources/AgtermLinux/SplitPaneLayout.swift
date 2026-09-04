struct SplitPaneLayout: Equatable {
    let primaryVisible: Bool
    let splitVisible: Bool

    /// Only visibility varies: a pane host's GtkPaned slot is fixed for its lifetime ([[libghostty]]).
    init(isSplit: Bool, splitFocused: Bool) {
        primaryVisible = isSplit || !splitFocused
        splitVisible = isSplit || splitFocused
    }
}
