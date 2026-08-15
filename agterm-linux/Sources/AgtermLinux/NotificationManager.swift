// Desktop notifications for OSC 9/777 (GHOSTTY_ACTION_DESKTOP_NOTIFICATION) and the `notify` control
// command. Sent as a GNotification through the GApplication so a click routes back to the app's
// `reveal` action (click-to-reveal the firing session); falls back to notify-send if the app handle
// isn't up yet. Action routing requires the installed `.desktop` (shipped by install-linux.sh); the
// banner itself shows either way.
import CGtk
import Foundation
import agtermCore

enum NotificationManager {
    /// Whether OS banners are enabled (the user's `notificationsEnabled` setting, default on). A
    /// delivered notification still updates its unseen badge when banners are disabled.
    static var bannersEnabled: Bool { linuxSettingsStore().load().notificationsEnabled ?? true }

    /// Post a banner. A pane-qualified target is both the click target and the coalescing identity.
    @MainActor static func send(title: String, body: String, target: String? = nil) {
        guard bannersEnabled else { return }
        guard let app = gApp else { sendViaNotifySend(title: title, body: body); return }
        let n = g_notification_new(title.isEmpty ? "agterm" : title)
        body.withCString { g_notification_set_body(n, $0) }
        if let target {
            let variant = g_variant_new_string(target)   // floating; set_..._value sinks it
            "app.reveal".withCString { g_notification_set_default_action_and_target_value(n, $0, variant) }
        }
        let notifID = target.map(notificationID) ?? "agterm-notify"
        notifID.withCString { g_application_send_notification(GAPP(app), $0, n) }
        g_object_unref(n.map { UnsafeMutableRawPointer($0) })
    }

    static func notificationID(_ target: String) -> String {
        "agterm-" + target.replacingOccurrences(of: ":", with: "-")
    }

    /// Withdraw every pane identity delivered for a selected session, plus the legacy per-session id.
    @MainActor static func withdraw(windowID: UUID, sessionID: UUID) {
        guard let app = gApp else { return }
        for pane in PaneRole.allCases {
            let target = TerminalNotification.identity(windowID: windowID, sessionID: sessionID, pane: pane)
            notificationID(target).withCString { g_application_withdraw_notification(GAPP(app), $0) }
        }
        "agterm-\(sessionID.uuidString)".withCString {
            g_application_withdraw_notification(GAPP(app), $0)
        }
    }

    private static func sendViaNotifySend(title: String, body: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/notify-send")
        // `--` terminates option parsing so a title/body starting with `-` (these come from untrusted
        // OSC 9/777 sequences and the control socket) can't smuggle flags.
        proc.arguments = ["-a", "agterm", "--", title.isEmpty ? "agterm" : title, body]
        // Inheritance minus agterm's own GDK overrides — harmless for a D-Bus client like notify-send,
        // but this is a spawned child like any other and the rule has no exceptions to remember.
        proc.environment = gdkEnvironment.restoringChildEnvironment(ProcessInfo.processInfo.environment)
        try? proc.run()
    }
}
