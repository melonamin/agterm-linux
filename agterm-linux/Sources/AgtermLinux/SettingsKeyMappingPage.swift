import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func makeKeyMappingSettingsPage(_ settings: AppSettings) -> OpaquePointer? {
        let page = preferencesPage("Key Mapping", name: .keyMapping, icon: "input-keyboard-symbolic")
        let files = preferencesGroup("Configuration")
        let directory = OpaquePointer(adw_action_row_new())
        settingsConfigDirectoryRow = directory
        "Config directory".withCString { adw_preferences_row_set_title(cast(directory), $0) }
        configDirectory().path.withCString { adw_action_row_set_subtitle(cast(directory), $0) }
        adw_action_row_add_suffix(
            cast(directory),
            W(
                preferencesButton(
                    "Choose…", handler: unsafeBitCast(onChooseConfigDirectory, to: GCallback.self))))
        adw_preferences_group_add(cast(files), W(directory))

        let keymap = OpaquePointer(adw_action_row_new())
        "keymap.conf".withCString { adw_preferences_row_set_title(cast(keymap), $0) }
        ConfigPaths.keymapPath(configDirectory: configDirectory()).path.withCString {
            adw_action_row_set_subtitle(cast(keymap), $0)
        }
        adw_action_row_add_suffix(
            cast(keymap),
            W(
                preferencesButton(
                    "Open", handler: unsafeBitCast(onOpenKeymapConfig, to: GCallback.self))))
        adw_preferences_group_add(cast(files), W(keymap))

        let actions = OpaquePointer(adw_action_row_new())
        "Configuration actions".withCString { adw_preferences_row_set_title(cast(actions), $0) }
        for (title, callback) in [
            ("Open Directory", onOpenKeymapDirectory),
            ("Use Default", onUseDefaultConfigDirectory),
            ("Reload", onReloadKeymapSettings),
        ] {
            adw_action_row_add_suffix(
                cast(actions),
                W(
                    preferencesButton(
                        title, handler: unsafeBitCast(callback, to: GCallback.self))))
        }
        adw_preferences_group_add(cast(files), W(actions))
        adw_preferences_page_add(cast(page), cast(files))

        let diagnostics = preferencesGroup("Diagnostics")
        let loaded = loadLinuxKeymap(configDirectory: configDirectory()).diagnostics
        if loaded.isEmpty {
            let row = OpaquePointer(adw_action_row_new())
            "No keymap errors".withCString { adw_preferences_row_set_title(cast(row), $0) }
            "The active keymap parsed successfully".withCString {
                adw_action_row_set_subtitle(cast(row), $0)
            }
            adw_preferences_group_add(cast(diagnostics), W(row))
        } else {
            for diagnostic in loaded {
                let row = OpaquePointer(adw_action_row_new())
                let line = diagnostic.line == 0 ? "File" : "Line \(diagnostic.line)"
                line.withCString { adw_preferences_row_set_title(cast(row), $0) }
                diagnostic.message.withCString { adw_action_row_set_subtitle(cast(row), $0) }
                adw_preferences_group_add(cast(diagnostics), W(row))
            }
        }
        adw_preferences_page_add(cast(page), cast(diagnostics))
        _ = settings
        return page
    }

    func chooseConfigDirectory() {
        let dialog = gtk_file_dialog_new()
        "Choose the agterm configuration directory".withCString {
            gtk_file_dialog_set_title(dialog, $0)
        }
        "Choose".withCString { gtk_file_dialog_set_accept_label(dialog, $0) }
        let folder = configDirectory().path.withCString { g_file_new_for_path($0) }
        gtk_file_dialog_set_initial_folder(dialog, folder)
        g_object_unref(RAW(folder))
        gtk_file_dialog_select_folder(
            dialog, WIN(window), nil, onConfigDirectoryChosen,
            Unmanaged.passRetained(self).toOpaque())
    }

    func openConfigDirectory() {
        launchDefaultHandler(forURI: configDirectory().absoluteString)
    }
}

private let onChooseConfigDirectory: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.chooseConfigDirectory() }
}
private let onOpenKeymapConfig: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated {
        guard let controller = controllerForWidget(button) else { return }
        controller.dismissSettings()
        controller.editKeymap()
    }
}
private let onOpenKeymapDirectory: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.openConfigDirectory() }
}
private let onUseDefaultConfigDirectory: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated {
        controllerForWidget(button)?.setConfigDirectory(nil)
        controllerForWidget(button)?.rebuildSettings(page: .keyMapping)
    }
}
private let onReloadKeymapSettings: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated {
        // No `guard` on the controller — see `reloadKeymapAllWindows(reportingIn:)`: the fan-out never
        // depends on it resolving. This is the ONE reload the user asked for by pressing a button, so it
        // is also the one that confirms success; the seam itself only reports errors, which is what ends
        // this site's old double-toast (a per-window error banner plus its own summary).
        let controller = controllerForWidget(button)
        if reloadKeymapAllWindows(reportingIn: controller) == 0 { controller?.showToast("keymap.conf reloaded") }
        controller?.rebuildSettings(page: .keyMapping)
    }
}
private let onConfigDirectoryChosen: @MainActor @convention(c) (UnsafeMutablePointer<GObject>?, OpaquePointer?, gpointer?) -> Void = { dialog, result, data in
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
        controller.setConfigDirectory(value)
        controller.rebuildSettings(page: .keyMapping)
    }
}
