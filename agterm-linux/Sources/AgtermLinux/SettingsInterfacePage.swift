import CGtk
import agtermCore

@MainActor
@discardableResult
func linuxHeaderToggle(_ header: OpaquePointer?, _ icon: String, _ tooltip: String,
                       _ callback: @escaping @convention(c) (OpaquePointer?, gpointer?) -> Void) -> OpaquePointer? {
    let button = OpaquePointer(gtk_button_new_from_icon_name(icon))
    gtk_widget_set_tooltip_text(W(button), tooltip)
    connect(button, "clicked", unsafeBitCast(callback, to: GCallback.self))
    adw_header_bar_pack_end(header, W(button))
    return button
}

@MainActor
func linuxHeaderSeparator(_ header: OpaquePointer?) -> OpaquePointer? {
    let separator = OpaquePointer(gtk_separator_new(GTK_ORIENTATION_VERTICAL))
    gtk_widget_set_margin_top(W(separator), 8)
    gtk_widget_set_margin_bottom(W(separator), 8)
    adw_header_bar_pack_end(header, W(separator))
    return separator
}

@MainActor
extension AppController {
    func installInterfaceTitle(in header: OpaquePointer?) {
        titleWidget = OpaquePointer(adw_window_title_new("", ""))
        adw_header_bar_set_title_widget(header, W(titleWidget))
    }

    func registerInterfaceWidgets(sidebarToggle: OpaquePointer?) {
        interfaceWidgets = [
            .sidebarToggle: sidebarToggle,
            .recentSessions: recentSessionsButton,
            .scratch: scratchToggleBtn,
            .split: splitToggleBtn,
            .dashboard: dashboardButton,
            .quickTerminal: quickToggleBtn,
            .newWorkspace: footerNewWorkspaceButton,
            .newSession: footerNewSessionButton,
            .flaggedView: footerFlaggedButton,
            .focusFilter: footerFocusFilterButton
        ].compactMapValues { $0 }
    }

    func makeInterfaceSettingsPage(_ settings: AppSettings) -> OpaquePointer? {
        let page = preferencesPage("Interface", name: .interface, icon: "preferences-desktop-display-symbolic")
        addInterfaceGroup("Title Bar", section: .titleBar, settings: settings, to: page)
        addInterfaceGroup("Sidebar", section: .sidebar, settings: settings, to: page)
        let behavior = preferencesGroup("Sidebar Behavior")
        adw_preferences_group_add(
            cast(behavior),
            W(preferencesSwitch(
                "Click a workspace row to expand or collapse",
                active: settings.workspaceRowClickExpands ?? true,
                handler: unsafeBitCast(onWorkspaceRowClickExpandsChanged, to: GCallback.self))))
        adw_preferences_page_add(cast(page), cast(behavior))
        let windows = preferencesGroup("Multiple Windows")
        adw_preferences_group_add(
            cast(windows),
            W(preferencesSwitch(
                "Show sidebar only in the active window",
                active: settings.autoHideSidebarInactiveWindows ?? false,
                handler: unsafeBitCast(onAutoHideInactiveSidebarsChanged, to: GCallback.self))))
        adw_preferences_page_add(cast(page), cast(windows))
        return page
    }

    private func addInterfaceGroup(_ title: String, section: InterfaceElement.Section,
                                   settings: AppSettings, to page: OpaquePointer?) {
        let group = preferencesGroup(title)
        for element in InterfaceElement.allCases where element.section == section {
            guard let row = preferencesSwitch(
                element.displayName,
                active: !settings.isInterfaceElementHidden(element),
                handler: unsafeBitCast(onInterfaceElementChanged, to: GCallback.self)
            ) else { continue }
            settingsInterfaceRows[row] = element
            adw_preferences_group_add(cast(group), W(row))
        }
        adw_preferences_page_add(cast(page), cast(group))
    }

    func interfaceElementChanged(_ row: OpaquePointer?) {
        guard let row, let element = settingsInterfaceRows[row] else { return }
        setInterfaceElementVisible(element, visible: adw_switch_row_get_active(row) != 0)
    }
}

private let onInterfaceElementChanged: @MainActor @convention(c)
    (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
        MainActor.assumeIsolated { controllerForWidget(row)?.interfaceElementChanged(row) }
    }

private let onAutoHideInactiveSidebarsChanged: @MainActor @convention(c)
    (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
        MainActor.assumeIsolated {
            controllerForWidget(row)?.setAutoHideInactiveSidebars(
                adw_switch_row_get_active(row) != 0)
        }
    }

private let onWorkspaceRowClickExpandsChanged: @MainActor @convention(c)
    (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
        MainActor.assumeIsolated {
            controllerForWidget(row)?.setWorkspaceRowClickExpands(
                adw_switch_row_get_active(row) != 0)
        }
    }
