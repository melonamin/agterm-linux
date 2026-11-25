import CGtk
import agtermCore

@MainActor
private final class AuxiliaryDialogContext {
    let controller: AppController
    let dialog: OpaquePointer?

    init(controller: AppController, dialog: OpaquePointer?) {
        self.controller = controller
        self.dialog = dialog
    }
}

@MainActor
extension AppController {
    func installPreferencesShortcut() {
        let action = "preferences".withCString { g_simple_action_new($0, nil) }
        attachControllerContext(to: action, windowID: windowID)
        connect(action, "activate", unsafeBitCast(onPreferencesShortcut, to: GCallback.self))
        g_action_map_add_action(window, action)

        guard let app = gApp else { return }
        "<Control>comma".withCString { accelerator in
            var accelerators: [UnsafePointer<CChar>?] = [accelerator, nil]
            "win.preferences".withCString { actionName in
                accelerators.withUnsafeMutableBufferPointer {
                    gtk_application_set_accels_for_action(APPW(app), actionName, $0.baseAddress)
                }
            }
        }
    }

    func showKeyboardShortcuts() {
        let dialog = OpaquePointer(adw_preferences_dialog_new())
        let dialogContext = prepareAuxiliaryDialog(dialog)
        let page = preferencesPage(
            "Keyboard Shortcuts", name: .keyMapping, icon: "input-keyboard-symbolic")
        let common = preferencesGroup("Resolved Bindings")
        for action in BuiltinAction.allCases {
            guard let chord = resolvedChord(for: action) else { continue }
            let row = OpaquePointer(adw_action_row_new())
            shortcutTitle(action).withCString { adw_preferences_row_set_title(cast(row), $0) }
            chord.displayString.withCString { adw_action_row_set_subtitle(cast(row), $0) }
            adw_preferences_group_add(cast(common), W(row))
        }
        for binding in fixedShortcutCatalog {
            let row = OpaquePointer(adw_action_row_new())
            binding.title.withCString { adw_preferences_row_set_title(cast(row), $0) }
            binding.shortcut.withCString { adw_action_row_set_subtitle(cast(row), $0) }
            adw_preferences_group_add(cast(common), W(row))
        }
        let preferences = OpaquePointer(adw_action_row_new())
        "Customize shortcuts".withCString { adw_preferences_row_set_title(cast(preferences), $0) }
        "Edit keymap.conf and review diagnostics".withCString {
            adw_action_row_set_subtitle(cast(preferences), $0)
        }
        adw_action_row_add_suffix(
            cast(preferences),
            W(
                preferencesButton(
                    "Open Settings", handler: unsafeBitCast(onShortcutPreferences, to: GCallback.self),
                    data: dialogContext)))
        adw_preferences_group_add(cast(common), W(preferences))
        adw_preferences_page_add(cast(page), cast(common))
        adw_preferences_dialog_add(cast(dialog), cast(page))
        adw_dialog_present(cast(dialog), W(window))
    }

    func showAbout() {
        let dialog = OpaquePointer(adw_about_dialog_new())
        "agterm".withCString { adw_about_dialog_set_application_name(dialog, $0) }
        LinuxAppMetadata.applicationID.withCString { adw_about_dialog_set_application_icon(dialog, $0) }
        "agterm-linux maintainers".withCString { adw_about_dialog_set_developer_name(dialog, $0) }
        LinuxAppMetadata.version.withCString { adw_about_dialog_set_version(dialog, $0) }
        "A workspace terminal for long-lived coding-agent and shell sessions.".withCString {
            adw_about_dialog_set_comments(dialog, $0)
        }
        "https://github.com/melonamin/agterm-linux".withCString {
            adw_about_dialog_set_website(dialog, $0)
        }
        "https://github.com/melonamin/agterm-linux/issues".withCString {
            adw_about_dialog_set_issue_url(dialog, $0)
        }
        adw_about_dialog_set_license_type(dialog, GTK_LICENSE_MIT_X11)
        _ = prepareAuxiliaryDialog(dialog)
        adw_dialog_present(cast(dialog), W(window))
    }

    private func prepareAuxiliaryDialog(_ dialog: OpaquePointer?) -> UnsafeMutableRawPointer {
        attachControllerContext(to: dialog, windowID: windowID)
        let context = AuxiliaryDialogContext(controller: self, dialog: dialog)
        let data = Unmanaged.passRetained(context).toOpaque()
        connect(
            dialog, "closed", unsafeBitCast(onAuxiliaryDialogClosed, to: GCallback.self),
            data)
        if let dialog { auxiliaryDialogs.append(dialog) }
        noteUserActivity()
        suppressAutoFollow()
        return data
    }

    /// Force-close every auxiliary dialog (Keyboard Shortcuts, About) this window still owns: like the
    /// Settings dialog they are hosted AdwDialogs holding a `passRetained` on "closed", so that signal must
    /// be emitted at a point we control (see `.claude/rules/main-loop.md`). Tracked as a set because they are
    /// built ad hoc, with no single dialog slot to dismiss.
    func dismissAuxiliaryDialogs() {
        let open = auxiliaryDialogs
        auxiliaryDialogs.removeAll()
        for dialog in open { adw_dialog_force_close(cast(dialog)) }
    }

    /// An auxiliary dialog emitted "closed": drop it from the tracked set so a later dismissal cannot
    /// force-close a dialog libadwaita already destroyed. Idempotent — the window-close sweep clears the
    /// set first, so the handler it triggers finds nothing left to remove.
    func auxiliaryDialogDidClose(_ dialog: OpaquePointer?) {
        guard let dialog else { return }
        auxiliaryDialogs.removeAll { $0 == dialog }
    }
}

private func shortcutTitle(_ action: BuiltinAction) -> String {
    action.rawValue.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
}

private let fixedShortcutCatalog: [(title: String, shortcut: String)] = [
    ("Preferences", "ctrl+,"),
    ("Quick switch session", "ctrl+tab"),
    ("Previous session", "ctrl+pageup"),
    ("Next session", "ctrl+pagedown"),
    ("Focus left pane", "ctrl+1 / ctrl+shift+left"),
    ("Focus right pane", "ctrl+2 / ctrl+shift+right"),
    ("Move session up", "ctrl+shift+up"),
    ("Move session down", "ctrl+shift+down"),
    ("Move workspace up", "ctrl+shift+pageup"),
    ("Move workspace down", "ctrl+shift+pagedown"),
    ("Increase font size", "ctrl+= / ctrl++"),
    ("Decrease font size", "ctrl+-"),
    ("Reset font size", "ctrl+0"),
]

private let onPreferencesShortcut: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { action, _, _ in
    MainActor.assumeIsolated { controllerForObject(action)?.showSettings() }
}
private let onShortcutPreferences: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let context = Unmanaged<AuxiliaryDialogContext>.fromOpaque(data).takeUnretainedValue()
        let controller = context.controller
        let dialog = context.dialog
        adw_dialog_force_close(cast(dialog))
        controller.showSettings(page: .keyMapping)
    }
}
private let onAuxiliaryDialogClosed: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let context = Unmanaged<AuxiliaryDialogContext>.fromOpaque(data).takeRetainedValue()
        context.controller.auxiliaryDialogDidClose(context.dialog)
        context.controller.resumeAutoFollow()
    }
}
