import Foundation
import agtermCore

extension ConfigPaths {
    /// Prefer the launch environment's home on Linux. `FileManager` resolves the passwd entry here,
    /// ignoring an intentionally isolated HOME (tests, containers, portable launches) and can start a
    /// shell inside the real user's config tree instead.
    static func defaultNewSessionCwd(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let home = environment["HOME"], !home.isEmpty { return home }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func starterGhosttyConfig() -> String {
        """
        # agterm-scoped ghostty config. This file is loaded after the bundled defaults.
        # Put agterm-only terminal settings here.

        """
    }

    static func starterRestoreDenylist() -> String {
        """
        # Commands that should not be automatically re-run by restore-running-command.
        tmux
        screen
        zellij

        """
    }
}
