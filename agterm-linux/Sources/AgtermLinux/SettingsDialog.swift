import CGtk
import agtermCore

enum LinuxSettingsPage: String {
    case general
    case appearance
    case interface
    case notifications
    case agentStatus = "agent-status"
    case keyMapping = "key-mapping"
    case integrations
}

@MainActor
extension AppController {
    func showSettings(page: LinuxSettingsPage = .general) {
        if let dialog = settingsDialog {
            page.rawValue.withCString { adw_preferences_dialog_set_visible_page_name(cast(dialog), $0) }
            adw_dialog_present(cast(dialog), W(window))
            return
        }

        let settings = linuxSettingsStore().load()
        let dialog = OpaquePointer(adw_preferences_dialog_new())
        attachControllerContext(to: dialog, windowID: windowID)
        settingsDialog = dialog
        "preferences".withCString { gtk_widget_set_name(W(dialog), $0) }
        adw_preferences_dialog_set_search_enabled(cast(dialog), 1)
        let pages = [makeGeneralSettingsPage(settings), makeAppearanceSettingsPage(settings),
                     makeInterfaceSettingsPage(settings),
                     makeNotificationsSettingsPage(settings), makeAgentStatusSettingsPage(settings),
                     makeKeyMappingSettingsPage(settings), makeIntegrationsSettingsPage()]
        for preferencesPage in pages { adw_preferences_dialog_add(cast(dialog), cast(preferencesPage)) }
        page.rawValue.withCString { adw_preferences_dialog_set_visible_page_name(cast(dialog), $0) }
        connect(dialog, "closed", unsafeBitCast(onSettingsClosed, to: GCallback.self),
                Unmanaged.passRetained(self).toOpaque())
        adw_dialog_present(cast(dialog), W(window))
        noteUserActivity()
        suppressAutoFollow()
    }

    func rebuildSettings(page: LinuxSettingsPage) {
        guard let dialog = settingsDialog else { showSettings(page: page); return }
        settingsDialog = nil
        adw_dialog_force_close(cast(dialog))
        showSettings(page: page)
    }

    func dismissSettings() {
        guard let dialog = settingsDialog else { return }
        adw_dialog_force_close(cast(dialog))
    }

    /// Rebuild the open dialog after a desktop light/dark transition so the Appearance page's active and
    /// alternate theme rows retain their correct labels, selections, and light/dark write targets.
    func rebuildSettingsForColorSchemeChange() {
        guard let dialog = settingsDialog else { return }
        let raw = adw_preferences_dialog_get_visible_page_name(cast(dialog)).map(String.init(cString:))
        rebuildSettings(page: raw.flatMap(LinuxSettingsPage.init(rawValue:)) ?? .appearance)
    }
}

func preferencesPage(_ title: String, name: LinuxSettingsPage, icon: String) -> OpaquePointer? {
    let page = OpaquePointer(adw_preferences_page_new())
    title.withCString { adw_preferences_page_set_title(cast(page), $0) }
    name.rawValue.withCString { adw_preferences_page_set_name(cast(page), $0) }
    icon.withCString { adw_preferences_page_set_icon_name(cast(page), $0) }
    return page
}

func preferencesGroup(_ title: String) -> OpaquePointer? {
    let group = OpaquePointer(adw_preferences_group_new())
    title.withCString { adw_preferences_group_set_title(cast(group), $0) }
    return group
}

func preferencesSwitch(_ title: String, subtitle: String? = nil, active: Bool,
                       handler: GCallback?) -> OpaquePointer? {
    let row = OpaquePointer(adw_switch_row_new())
    title.withCString { adw_preferences_row_set_title(cast(row), $0) }
    if let subtitle { subtitle.withCString { adw_action_row_set_subtitle(cast(row), $0) } }
    adw_switch_row_set_active(row, active ? 1 : 0)
    connect(row, "notify::active", handler)
    return row
}

func preferencesCombo(_ title: String, values: [String], selected: Int,
                      handler: GCallback?) -> OpaquePointer? {
    let model = gtk_string_list_new(nil)
    for value in values { value.withCString { gtk_string_list_append(model, $0) } }
    let row = OpaquePointer(adw_combo_row_new())
    title.withCString { adw_preferences_row_set_title(cast(row), $0) }
    adw_combo_row_set_model(cast(row), model)
    "string".withCString {
        let expression = gtk_property_expression_new(gtk_string_object_get_type(), nil, $0)
        adw_combo_row_set_expression(cast(row), expression)
    }
    adw_combo_row_set_enable_search(cast(row), values.count > 10 ? 1 : 0)
    adw_combo_row_set_selected(cast(row), UInt32(max(0, selected)))
    connect(row, "notify::selected", handler)
    return row
}

func preferencesButton(
    _ title: String, handler: GCallback?, data: UnsafeMutableRawPointer? = nil
) -> OpaquePointer? {
    let button = OpaquePointer(gtk_button_new_with_label(title))
    gtk_widget_set_valign(W(button), GTK_ALIGN_CENTER)
    connect(button, "clicked", handler, data)
    return button
}

private let onSettingsClosed: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { dialog, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let controller = Unmanaged<AppController>.fromOpaque(data).takeRetainedValue()
        controller.commitBackgroundOpacity()
        controller.resumeAutoFollow()
        if controller.settingsDialog == dialog {
            controller.integrationRefreshGeneration &+= 1
            controller.settingsDialog = nil
            controller.settingsCustomDirectoryRow = nil
            controller.settingsConfigDirectoryRow = nil
            controller.settingsAutoFollowAwayRow = nil
            controller.settingsInterfaceRows.removeAll()
            controller.integrationRows.removeAll()
            controller.integrationKindButtons.removeAll()
            controller.integrationButtons.removeAll()
        }
    }
}
