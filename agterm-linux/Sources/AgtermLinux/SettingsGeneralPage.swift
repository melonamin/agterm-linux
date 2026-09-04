import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func makeGeneralSettingsPage(_ settings: AppSettings) -> OpaquePointer? {
        let page = preferencesPage("General", name: .general, icon: "preferences-system-symbolic")

        let mouse = preferencesGroup("Mouse")
        let scroll = OpaquePointer(adw_spin_row_new_with_range(1, 10, 1))
        "Scroll speed".withCString { adw_preferences_row_set_title(cast(scroll), $0) }
        adw_spin_row_set_value(scroll, settings.mouseScrollMultiplier ?? 3)
        connect(scroll, "notify::value", unsafeBitCast(onSettingsScrollSpeed, to: GCallback.self))
        adw_preferences_group_add(cast(mouse), W(scroll))
        adw_preferences_group_add(
            cast(mouse),
            W(
                preferencesSwitch(
                    "Right-click pastes", active: settings.rightClickPaste ?? true,
                    handler: unsafeBitCast(onSettingsRightClickPaste, to: GCallback.self))))
        adw_preferences_page_add(cast(page), cast(mouse))

        let sessions = preferencesGroup("Sessions")
        let modes = ["Home directory", "Current session's directory", "Custom directory"]
        let currentMode =
            AppSettings.NewSessionDirectory(rawValue: settings.newSessionDirectory ?? "") ?? .home
        let selected = currentMode == .home ? 0 : (currentMode == .currentSession ? 1 : 2)
        let directoryMode = preferencesCombo(
            "New sessions open in", values: modes, selected: selected,
            handler: unsafeBitCast(onSettingsSessionDirectory, to: GCallback.self))
        adw_preferences_group_add(cast(sessions), W(directoryMode))

        let custom = OpaquePointer(adw_action_row_new())
        settingsCustomDirectoryRow = custom
        "Custom directory".withCString { adw_preferences_row_set_title(cast(custom), $0) }
        (settings.newSessionCustomDirectory ?? "Not set").withCString {
            adw_action_row_set_subtitle(cast(custom), $0)
        }
        adw_action_row_add_suffix(
            cast(custom),
            W(
                preferencesButton(
                    "Choose…", handler: unsafeBitCast(onChooseSessionDirectory, to: GCallback.self))))
        adw_preferences_group_add(cast(sessions), W(custom))
        let restoreModes = ["Fresh shells", "Re-run commands", "Live sessions (experimental)"]
        let restoreIndex: Int
        switch settings.effectiveRestoreMode {
        case .none: restoreIndex = 0
        case .rerun: restoreIndex = 1
        case .live: restoreIndex = 2
        }
        let restore = preferencesCombo(
            "Restore sessions", values: restoreModes, selected: restoreIndex,
            handler: unsafeBitCast(onSettingsRestoreMode, to: GCallback.self))
        let restoreSubtitle = settings.effectiveRestoreMode == .live
            ? LinuxZmxLaunch.liveUnavailableReason().map { "Live unavailable: \($0)" }
                ?? "Live mode is available after restarting agterm"
            : "Choose what happens to terminal processes when agterm restarts"
        restoreSubtitle.withCString {
            adw_action_row_set_subtitle(cast(restore), $0)
        }
        adw_preferences_group_add(cast(sessions), W(restore))
        adw_preferences_group_add(
            cast(sessions),
            W(
                preferencesSwitch(
                    "Confirm before closing a session", active: settings.confirmCloseSession ?? false,
                    handler: unsafeBitCast(onSettingsConfirmClose, to: GCallback.self))))
        adw_preferences_group_add(
            cast(sessions),
            W(
                preferencesSwitch(
                    "Allow undo after closing sessions and workspaces",
                    active: settings.closeGraceUndoEnabled ?? true,
                    handler: unsafeBitCast(onSettingsCloseUndo, to: GCallback.self))))
        adw_preferences_page_add(cast(page), cast(sessions))

        let ghostty = preferencesGroup("Ghostty Config")
        adw_preferences_group_add(
            cast(ghostty),
            W(
                preferencesSwitch(
                    "Use my global Ghostty config",
                    subtitle: "Also load ~/.config/ghostty/config before agterm's own configuration",
                    active: settings.inheritGlobalGhosttyConfig ?? false,
                    handler: unsafeBitCast(onSettingsInheritGhostty, to: GCallback.self))))
        let edit = OpaquePointer(adw_action_row_new())
        "agterm-scoped configuration".withCString { adw_preferences_row_set_title(cast(edit), $0) }
        ConfigPaths.ghosttyConfigPath(configDirectory: configDirectory()).path.withCString {
            adw_action_row_set_subtitle(cast(edit), $0)
        }
        adw_action_row_add_suffix(
            cast(edit),
            W(
                preferencesButton(
                    "Open", handler: unsafeBitCast(onOpenGhosttyConfig, to: GCallback.self))))
        adw_preferences_group_add(cast(ghostty), W(edit))
        adw_preferences_page_add(cast(page), cast(ghostty))
        return page
    }

    func chooseSessionDirectory() {
        let dialog = gtk_file_dialog_new()
        "Choose a directory for new sessions".withCString { gtk_file_dialog_set_title(dialog, $0) }
        "Choose".withCString { gtk_file_dialog_set_accept_label(dialog, $0) }
        let settings = linuxSettingsStore().load()
        let initial =
            settings.newSessionCustomDirectory ?? store.activeSession?.focusedCwd ?? Self.homeCwd
        let folder = initial.withCString { g_file_new_for_path($0) }
        gtk_file_dialog_set_initial_folder(dialog, folder)
        g_object_unref(RAW(folder))
        gtk_file_dialog_select_folder(
            dialog, WIN(window), nil, onSessionDirectoryChosen,
            Unmanaged.passRetained(self).toOpaque())
    }
}

private let onSettingsScrollSpeed: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { controllerForWidget(row)?.setScrollSpeed(adw_spin_row_get_value(row)) }
}
private let onSettingsRightClickPaste: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setRightClickPaste(adw_switch_row_get_active(row) != 0)
    }
}
private let onSettingsRestoreMode: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setRestoreModeAtIndex(Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsConfirmClose: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setConfirmCloseSession(adw_switch_row_get_active(row) != 0)
    }
}
private let onSettingsCloseUndo: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { controllerForWidget(row)?.setCloseGraceUndo(adw_switch_row_get_active(row) != 0) }
}
private let onSettingsSessionDirectory: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setNewSessionDirectoryAtIndex(Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsInheritGhostty: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setInheritGlobalGhosttyConfig(adw_switch_row_get_active(row) != 0)
    }
}
private let onChooseSessionDirectory: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.chooseSessionDirectory() }
}
private let onOpenGhosttyConfig: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated {
        guard let controller = controllerForWidget(button) else { return }
        controller.dismissSettings()
        controller.editGhosttyConfig()
    }
}
private let onSessionDirectoryChosen: @MainActor @convention(c) (UnsafeMutablePointer<GObject>?, OpaquePointer?, gpointer?) -> Void = { dialog, result, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let controller = Unmanaged<AppController>.fromOpaque(data).takeRetainedValue()
        guard let dialog, let result, gWindows[controller.windowID] === controller else { return }
        var error: UnsafeMutablePointer<GError>?
        guard let file = gtk_file_dialog_select_folder_finish(OpaquePointer(dialog), result, &error),
              let path = g_file_get_path(file) else {
            if let error { g_error_free(error) }
            return
        }
        let value = String(cString: path)
        g_free(path)
        g_object_unref(RAW(file))
        controller.setNewSessionCustomDirectory(value)
        controller.setNewSessionDirectoryAtIndex(2)
        controller.rebuildSettings(page: .general)
    }
}
