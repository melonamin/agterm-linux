import Foundation

enum LinuxDesktopEnvironment {
    /// Hyprland users manage window actions through compositor bindings, so duplicating them in
    /// client-side header bars adds foreign-looking chrome that other GTK desktops still expect.
    static func hidesClientSideWindowButtons(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["HYPRLAND_INSTANCE_SIGNATURE"] != nil { return true }

        return ["XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP"].contains { key in
            environment[key]?
                .split(separator: ":")
                .contains { $0.caseInsensitiveCompare("Hyprland") == .orderedSame } == true
        }
    }
}
