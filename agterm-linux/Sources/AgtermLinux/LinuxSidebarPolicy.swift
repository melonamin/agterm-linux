import agtermCore

enum LinuxSidebarPolicy {
    /// The CSS that scales the sidebar rows to the configured sidebar font size (nil = the shared
    /// default): the row text size, plus a `min-height` derived from the shared
    /// `AppSettings.sidebarRowHeight` that lowers libadwaita's `navigation-sidebar` row pin.
    /// That height is a FLOOR, not a cap — taller content still grows the row.
    /// Read the Linux row-height bullet in `.claude/rules/sidebar.md` before changing this: it records
    /// which libadwaita rule is overridden, why the row's inner box is deliberately left alone, and what
    /// the emitted floor actually measures at each supported size.
    static func sidebarCSS(fontSize: Double?) -> String {
        let size = AppSettings.clampSidebarFontSize(fontSize ?? AppSettings.defaultSidebarFontSize)
        let rowHeight = Int(AppSettings.sidebarRowHeight(fontSize: size))
        return """
            .agterm-sidebar label { font-size: \(size)pt; }
            .agterm-sidebar .navigation-sidebar > row { min-height: \(rowHeight)px; }
            """
    }

    @MainActor
    static func flaggedRowLabel(for session: Session, in store: AppStore) -> String {
        if let workspace = store.workspace(forSession: session.id) {
            return "\(session.displayName)  —  \(workspace.name)"
        }
        return session.displayName
    }
}
