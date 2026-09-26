// Linux window-level settings application.
// Preferences construction and mutations are split across Settings*Page.swift and
// LinuxSettingsController.swift so the GTK adapter stays reviewable.
import CGtk
import agtermCore

@MainActor
extension AppController {
    func applyToolbarMode() {
        let mode = linuxSettingsStore().load().effectiveToolbarMode
        let visible: gboolean = mode == .hidden ? 0 : 1
        if let sidebarHeader { gtk_widget_set_visible(W(sidebarHeader), visible) }
        if let contentHeader { gtk_widget_set_visible(W(contentHeader), visible) }
        if let dashboardHeader = dashboardRuntime.header {
            gtk_widget_set_visible(W(dashboardHeader), visible)
        }
        if let zoomHeader { gtk_widget_set_visible(W(zoomHeader), visible) }
        if let bar = bottomBar {
            let padding: Int32 = mode == .normal ? 14 : 4
            gtk_widget_set_margin_top(W(bar), padding)
            gtk_widget_set_margin_bottom(W(bar), padding)
        }
        // The header moves the paned start child's minimum but not the CONTENT floor (it is an
        // `AdwToolbarView` top bar, not a child of `sidebarBox`), so re-lay out rather than re-measure.
        if let paned = splitView { applySidebarWidth(paned) }
    }

    func applyWindowTranslucency(settings: AppSettings? = nil) {
        let translucent = ((settings ?? linuxSettingsStore().load()).backgroundOpacity ?? 1) < 1
        "agterm-translucent".withCString {
            if translucent {
                gtk_widget_add_css_class(W(window), $0)
            } else {
                gtk_widget_remove_css_class(W(window), $0)
            }
        }
    }
}
