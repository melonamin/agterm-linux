import CGtk
import Foundation

/// GIO reports usable network changes; logind reports resume even when GTK never unmaps the window.
@MainActor
final class LinuxRemoteLinkObserver {
    static let shared = LinuxRemoteLinkObserver()
    private var monitor: OpaquePointer?
    private var connection: OpaquePointer?
    private var subscription: guint = 0

    func install() {
        guard monitor == nil else { return }
        monitor = g_network_monitor_get_default()
        connect(monitor, "network-changed", unsafeBitCast(onLinuxNetworkChanged as @convention(c)
            (OpaquePointer?, gboolean, gpointer?) -> Void, to: GCallback.self))
        var error: UnsafeMutablePointer<GError>?
        connection = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nil, &error)
        if let error { g_error_free(error) }
        guard let connection else { return }
        subscription = g_dbus_connection_signal_subscribe(connection, "org.freedesktop.login1", "org.freedesktop.login1.Manager",
                                                          "PrepareForSleep", "/org/freedesktop/login1", nil,
                                                          G_DBUS_SIGNAL_FLAGS_NONE, onLinuxPrepareForSleep, nil, nil)
    }

    func retry() {
        for controller in gWindows.values { controller.retryRemoteLinksNow() }
    }
}

private let onLinuxNetworkChanged: @MainActor @convention(c) (OpaquePointer?, gboolean, gpointer?) -> Void = { _, usable, _ in
    if usable != 0 { LinuxRemoteLinkObserver.shared.retry() }
}

private let onLinuxPrepareForSleep: @MainActor @convention(c)
    (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, OpaquePointer?, gpointer?) -> Void =
    { _, _, _, _, _, parameters, _ in
        guard let parameters, let sleeping = g_variant_get_child_value(parameters, 0) else { return }
        let value = g_variant_get_boolean(sleeping)
        g_variant_unref(sleeping)
        if value == 0 { LinuxRemoteLinkObserver.shared.retry() }
    }
