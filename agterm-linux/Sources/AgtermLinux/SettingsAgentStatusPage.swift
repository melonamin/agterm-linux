import CGtk
import agtermCore

@MainActor
extension AppController {
    func makeAgentStatusSettingsPage(_ settings: AppSettings) -> OpaquePointer? {
        let page = preferencesPage("Agent Status", name: .agentStatus, icon: "media-record-symbolic")
        let colors = preferencesGroup("Colors and Shapes")
        addStatusColorRow(
            colors, title: "Active", hex: settings.activeStatusColorHex ?? "#DBD9E6",
            handler: unsafeBitCast(onSettingsActiveColor, to: GCallback.self))
        addStatusColorRow(
            colors, title: "Blocked", hex: settings.blockedStatusColorHex ?? "#e5a50a",
            handler: unsafeBitCast(onSettingsBlockedColor, to: GCallback.self))
        addStatusColorRow(
            colors, title: "Completed", hex: settings.completedStatusColorHex ?? "#2ec27e",
            handler: unsafeBitCast(onSettingsCompletedColor, to: GCallback.self))
        addStatusShapeRow(
            colors, title: "Active shape", shape: settings.effectiveStatusShape(for: .active),
            handler: unsafeBitCast(onSettingsActiveShape, to: GCallback.self))
        addStatusShapeRow(
            colors, title: "Blocked shape", shape: settings.effectiveStatusShape(for: .blocked),
            handler: unsafeBitCast(onSettingsBlockedShape, to: GCallback.self))
        addStatusShapeRow(
            colors, title: "Completed shape", shape: settings.effectiveStatusShape(for: .completed),
            handler: unsafeBitCast(onSettingsCompletedShape, to: GCallback.self))
        adw_preferences_page_add(cast(page), cast(colors))

        let sound = preferencesGroup("Sound")
        let selectedSound = settings.blockedStatusSoundName == nil ? 0 : 1
        adw_preferences_group_add(
            cast(sound),
            W(
                preferencesCombo(
                    "Blocked sound", values: ["None", "Desktop bell"], selected: selectedSound,
                    handler: unsafeBitCast(onSettingsBlockedSound, to: GCallback.self))))
        adw_preferences_page_add(cast(page), cast(sound))

        let follow = preferencesGroup("Auto-follow")
        let mode = AppSettings.AutoFollowAttention(tolerant: settings.autoFollowAttention)
        let modes = AppSettings.AutoFollowAttention.allCases
        let labels = [
            "Disabled", "5 sec idle", "10 sec idle", "30 sec idle", "60 sec idle", "5 min idle",
        ]
        adw_preferences_group_add(
            cast(follow),
            W(
                preferencesCombo(
                    "Auto-follow blocked sessions", values: labels, selected: modes.firstIndex(of: mode) ?? 0,
                    handler: unsafeBitCast(onSettingsAutoFollow, to: GCallback.self))))
        let away = preferencesSwitch(
            "Auto-follow away from a running session",
            subtitle: "Only applies while auto-follow is enabled",
            active: !(settings.autoFollowStayOnActive ?? false),
            handler: unsafeBitCast(onSettingsAutoFollowAway, to: GCallback.self))
        settingsAutoFollowAwayRow = away
        gtk_widget_set_sensitive(W(away), mode == .off ? 0 : 1)
        adw_preferences_group_add(cast(follow), W(away))
        adw_preferences_page_add(cast(page), cast(follow))

        let setup = preferencesGroup("Setup")
        let integrations = OpaquePointer(adw_action_row_new())
        "Agent hooks and skill".withCString { adw_preferences_row_set_title(cast(integrations), $0) }
        "Inspect, install, update, or repair agent integrations".withCString {
            adw_action_row_set_subtitle(cast(integrations), $0)
        }
        adw_action_row_add_suffix(
            cast(integrations),
            W(
                preferencesButton(
                    "Manage", handler: unsafeBitCast(onManageAgentIntegrations, to: GCallback.self))))
        adw_preferences_group_add(cast(setup), W(integrations))
        let reset = OpaquePointer(adw_action_row_new())
        "Colors and sound".withCString { adw_preferences_row_set_title(cast(reset), $0) }
        adw_action_row_add_suffix(
            cast(reset),
            W(
                preferencesButton(
                    "Reset", handler: unsafeBitCast(onResetAgentStatus, to: GCallback.self))))
        adw_preferences_group_add(cast(setup), W(reset))
        adw_preferences_page_add(cast(page), cast(setup))
        return page
    }

    private func addStatusColorRow(
        _ group: OpaquePointer?, title: String, hex: String, handler: GCallback?
    ) {
        let button = OpaquePointer(gtk_color_dialog_button_new(gtk_color_dialog_new()))
        var color = GdkRGBA()
        hex.withCString { _ = gdk_rgba_parse(&color, $0) }
        gtk_color_dialog_button_set_rgba(button, &color)
        gtk_widget_set_valign(W(button), GTK_ALIGN_CENTER)
        connect(button, "notify::rgba", handler)
        let row = OpaquePointer(adw_action_row_new())
        title.withCString { adw_preferences_row_set_title(cast(row), $0) }
        adw_action_row_add_suffix(cast(row), W(button))
        adw_preferences_group_add(cast(group), W(row))
    }

    private func addStatusShapeRow(
        _ group: OpaquePointer?, title: String, shape: StatusShape?, handler: GCallback?
    ) {
        let shapes = StatusShape.allCases
        let selected = shapes.firstIndex(of: shape ?? .circle) ?? 0
        adw_preferences_group_add(
            cast(group),
            W(preferencesCombo(
                title, values: shapes.map(\.displayName), selected: selected, handler: handler)))
    }
}

private let onSettingsActiveColor: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { button, _, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.setStatusColor(.active, fromButton: button) }
}
private let onSettingsBlockedColor: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { button, _, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.setStatusColor(.blocked, fromButton: button) }
}
private let onSettingsCompletedColor: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { button, _, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.setStatusColor(.completed, fromButton: button) }
}
private let onSettingsActiveShape: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setStatusShape(.active, at: Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsBlockedShape: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setStatusShape(.blocked, at: Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsCompletedShape: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setStatusShape(.completed, at: Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsBlockedSound: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setBlockedSoundAtIndex(Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsAutoFollow: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setAutoFollowAtIndex(Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsAutoFollowAway: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setAutoFollowAwayFromRunning(adw_switch_row_get_active(row) != 0)
    }
}
private let onManageAgentIntegrations: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.showSettings(page: .integrations) }
}
private let onResetAgentStatus: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.resetAgentStatus() }
}
