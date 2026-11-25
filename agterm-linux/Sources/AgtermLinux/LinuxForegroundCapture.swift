import Foundation
import agtermCore

@MainActor
protocol LinuxForegroundCapturePane: AnyObject {
    var backedByZmx: Bool { get }
    var isRealized: Bool { get }
}

extension GhosttySurface: LinuxForegroundCapturePane {}

/// Captures panes' foreground argv into their `Session` fields for the snapshot save, mirroring upstream
/// `AppDelegate.captureForegroundCommands`. Contract in `.claude/rules/settings.md`.
@MainActor
enum LinuxForegroundCapture {
    static let budget: Duration = .milliseconds(500)

    /// Returns the slots actually WRITTEN from a read: counting non-nil slots afterwards would include a
    /// hidden split's earlier capture or a preserved pending argv.
    ///
    /// The argv is stored raw: the denylist rejects it at replay, which keeps `hadForeground` true so a
    /// stale creation command is not replayed in its place.
    ///
    /// `preserveUnconsumedPending` is EXIT-ONLY. `restore.capture` persisting an unconsumed slot while it
    /// stays armed lets a later show replay it, and a crash then replays the persisted copy again.
    @discardableResult
    static func capture<Pane: LinuxForegroundCapturePane, Snapshot>(
        sessions: [Session], preserveUnconsumedPending: Bool,
        panes: (Session) -> (primary: Pane?, split: Pane?),
        snapshot: () -> Snapshot?,
        timeRemaining suppliedTimeRemaining: (() -> Bool)? = nil,
        read: (Pane, Snapshot?) -> [String]?
    ) -> Int {
        // A remote pane's foreground is an ssh client the save drops; reading it would inflate the count and
        // spend the exit budget.
        let sessions = sessions.filter(\.isPersistable)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        let timeRemaining = suppliedTimeRemaining ?? { clock.now < deadline }
        let resolved = sessions.map { ($0, panes($0)) }
        let hasWrappedPane = resolved.contains { $0.1.primary?.backedByZmx == true || $0.1.split?.backedByZmx == true }
        let zmxSnapshot = hasWrappedPane ? snapshot() : nil
        var captured = 0
        for (session, pane) in resolved {
            // `loadStore` moved the persisted argv into the pending slot, so at exit a slot no factory
            // consumed (fallback launch, restored hidden split never shown) would otherwise be lost.
            let pending = preserveUnconsumedPending ? session.pendingForegroundCommand : nil
            let pendingSplit = preserveUnconsumedPending ? session.pendingSplitForegroundCommand : nil
            let primary = readSlot(pane.primary, snapshot: zmxSnapshot, timeRemaining: timeRemaining, read: read)
            session.foregroundCommand = primary ?? pending
            let readsSplit = session.isSplit || (pane.split?.backedByZmx == true && pane.split?.isRealized == true)
            let split = readSlot(readsSplit ? pane.split : nil, snapshot: zmxSnapshot,
                                 timeRemaining: timeRemaining, read: read)
            session.splitForegroundCommand = split ?? pendingSplit
            captured += [primary, split].compactMap { $0 }.count
        }
        return captured
    }

    /// A static function rather than a nested one: Release/WMO region checking rejects a main-actor
    /// closure that captures the snapshot, which comes from a non-Sendable generic parameter.
    private static func readSlot<Pane: LinuxForegroundCapturePane, Snapshot>(
        _ pane: Pane?, snapshot: Snapshot?, timeRemaining: () -> Bool, read: (Pane, Snapshot?) -> [String]?
    ) -> [String]? {
        guard let pane, timeRemaining(), !pane.backedByZmx || snapshot != nil else { return nil }
        return read(pane, snapshot)
    }
}
