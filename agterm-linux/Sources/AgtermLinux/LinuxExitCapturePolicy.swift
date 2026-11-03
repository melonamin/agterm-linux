import Foundation
import agtermCore

/// Which exit edge captures a window's foreground commands, following the CONFIGURED restore mode read at
/// that edge rather than the launch latch.
///
/// Linux runs upstream's ordering inverted: the quit confirm sets `isTerminating` before its
/// `gtk_window_close`, and `windowWillClose` drops the window from `gWindows`, so `flushOnQuit` never sees
/// that window's surfaces. The terminating close therefore captures, and the quit flush only captures
/// windows still registered. Each window is captured at most once per exit. Contract in
/// `.claude/rules/settings.md`.
@MainActor
final class LinuxExitCapturePolicy {
    enum Action: Equatable {
        case capture(preserveUnconsumedPending: Bool)
        case clear
        case skip
    }

    private let configuredMode: () -> RestoreMode
    private var capturedWindows: Set<UUID> = []

    init(configuredMode: @escaping () -> RestoreMode) {
        self.configuredMode = configuredMode
    }

    static func capturesForegroundOnExit(mode: RestoreMode) -> Bool { mode == .rerun || mode == .live }

    /// A window's close edge, evaluated while its surfaces are still alive.
    func windowClosing(_ windowID: UUID, isTerminating: Bool, openIDs: [UUID]) -> Action {
        // A non-last close must leave no argv: a launch restore cannot tell it from a file open at exit.
        guard isTerminating || openIDs == [windowID] else { return .clear }
        return exitAction(for: windowID)
    }

    /// The quit flush, over the windows whose surfaces are still registered.
    func quitting(registeredWindows: [UUID]) -> [(UUID, Action)] {
        registeredWindows.map { ($0, exitAction(for: $0)) }
    }

    /// A window opened again after an exit edge claimed it is live once more and captures at the next exit.
    func windowOpened(_ windowID: UUID) { capturedWindows.remove(windowID) }

    private func exitAction(for windowID: UUID) -> Action {
        guard capturedWindows.insert(windowID).inserted else { return .skip }
        return Self.capturesForegroundOnExit(mode: configuredMode())
            ? .capture(preserveUnconsumedPending: true) : .clear
    }
}
