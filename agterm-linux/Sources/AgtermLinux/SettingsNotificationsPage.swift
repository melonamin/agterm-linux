import CGtk
import agtermCore

@MainActor
extension AppController {
    func makeNotificationsSettingsPage(_ settings: AppSettings) -> OpaquePointer? {
        let page = preferencesPage(
            "Notifications", name: .notifications, icon: "preferences-system-notifications-symbolic")
        let group = preferencesGroup("Notifications")
        adw_preferences_group_add(
            cast(group),
            W(
                preferencesSwitch(
                    "Desktop notification banners",
                    subtitle: "Delivery and presentation also depend on your desktop notification settings",
                    active: settings.notificationsEnabled ?? true,
                    handler: unsafeBitCast(onSettingsNotificationBanners, to: GCallback.self))))
        adw_preferences_group_add(
            cast(group),
            W(
                preferencesSwitch(
                    "Sidebar notification badges", active: settings.notificationBadgeEnabled ?? true,
                    handler: unsafeBitCast(onSettingsNotificationBadges, to: GCallback.self))))
        adw_preferences_group_add(
            cast(group),
            W(
                preferencesSwitch(
                    "Show attention indicator in the toolbar",
                    active: settings.attentionButtonEnabled ?? false,
                    handler: unsafeBitCast(onSettingsAttentionIndicator, to: GCallback.self))))
        adw_preferences_page_add(cast(page), cast(group))
        return page
    }
}

private let onSettingsNotificationBanners: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setNotificationsEnabled(adw_switch_row_get_active(row) != 0)
    }
}
private let onSettingsNotificationBadges: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setNotificationBadge(adw_switch_row_get_active(row) != 0)
    }
}
private let onSettingsAttentionIndicator: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setAttentionButtonEnabled(adw_switch_row_get_active(row) != 0)
    }
}
