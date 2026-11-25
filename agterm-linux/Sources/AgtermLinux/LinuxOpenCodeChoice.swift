import CGtk
import LinuxIntegrations

@MainActor
extension AppController {
    func chooseOpenCodeVersion() {
        integrationOperationInFlight = false
        let dialog = OpaquePointer(adw_alert_dialog_new("Which OpenCode version?",
            "The installed major version could not be detected. Choose the loader to install, or skip its plugin."))
        attachControllerContext(to: dialog, windowID: windowID)
        for (id, label) in [("v1", "OpenCode v1"), ("v2", "OpenCode v2"), ("skip", "Skip OpenCode"), ("cancel", "Cancel")] {
            id.withCString { key in label.withCString { adw_alert_dialog_add_response(cast(dialog), key, $0) } }
        }
        "cancel".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        connect(dialog, "response", unsafeBitCast(onLinuxOpenCodeChoice as @convention(c)
            (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self))
        adw_dialog_present(cast(dialog), W(windowPointer))
    }
}

private let onLinuxOpenCodeChoice: @MainActor @convention(c)
    (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
        guard let response, let controller = controllerForWidget(dialog) else { return }
        let choice = String(cString: response)
        if choice != "cancel" { controller.prepareIntegration(.hooks, openCodeSelection: choice) }
    }
