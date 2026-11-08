import CGtk
import agtermCore

@MainActor
extension AppController {
    /// Linux keeps first-run setup advisory: the Integrations page inspects files and asks for a second,
    /// explicit confirmation before it changes anything.
    func showFirstRunWelcome() {
        let message = """
        agterm includes optional integrations for its command-line control tool, agent status hooks, and \
        the agent skill that teaches coding agents to drive the control socket.

        Review their current status in Settings ▸ Integrations. Nothing is installed or changed until \
        you review a plan and confirm it there.
        """
        let dialog = OpaquePointer(
            FirstRunWelcome.title.withCString { title in
                message.withCString { body in adw_alert_dialog_new(title, body) }
            })
        attachControllerContext(to: dialog, windowID: windowID)
        "later".withCString { id in
            "Later".withCString { label in adw_alert_dialog_add_response(cast(dialog), id, label) }
        }
        "integrations".withCString { id in
            "Open Integrations".withCString { label in
                adw_alert_dialog_add_response(cast(dialog), id, label)
            }
        }
        "integrations".withCString { adw_alert_dialog_set_default_response(cast(dialog), $0) }
        "later".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        connect(dialog, "response", unsafeBitCast(onFirstRunWelcomeResponse, to: GCallback.self))
        adw_dialog_present(cast(dialog), W(window))
    }
}

private let onFirstRunWelcomeResponse: @MainActor @convention(c)
    (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
        guard response.map({ String(cString: $0) }) == "integrations" else { return }
        MainActor.assumeIsolated { controllerForWidget(dialog)?.showSettings(page: .integrations) }
    }
