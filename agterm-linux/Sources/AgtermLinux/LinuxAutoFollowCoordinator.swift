import CGtk
import Foundation
import Observation
import agtermCore

/// Linux-owned auto-follow runtime.
///
/// Upstream's AppStore uses DispatchQueue.main for its native host. GTK owns the Linux main thread through
/// GLib, so this adapter keeps the timer, observation re-arm, suppression state, and pane reconciliation in
/// the Linux target while reusing only AppStore's public model surface.
@MainActor
final class LinuxAutoFollowCoordinator: @unchecked Sendable {
    private let store: AppStore
    private var timeout: TimeInterval?
    private var stayOnActive = false
    private var timeoutSource: guint = 0
    private var suppressionCount = 0
    private var rearmScheduled = false
    private var observationGeneration = 0

    init(store: AppStore) {
        self.store = store
    }

    var timeoutMs: Int? {
        timeout.map { Int($0 * 1_000) }
    }

    func configure(timeout: TimeInterval?, stayOnActive: Bool) {
        let previousTimeout = self.timeout
        let previousStayOnActive = self.stayOnActive
        self.timeout = timeout
        self.stayOnActive = stayOnActive
        guard let timeout else {
            cancelTimer()
            observationGeneration &+= 1
            rearmScheduled = false
            return
        }
        if previousTimeout != timeout || previousStayOnActive != stayOnActive {
            arm(after: timeout)
        }
        if previousTimeout == nil {
            observationGeneration &+= 1
            observeAttention(generation: observationGeneration)
        }
    }

    func noteUserActivity() {
        guard let timeout else {
            cancelTimer()
            return
        }
        arm(after: timeout)
    }

    func suppress() {
        suppressionCount += 1
    }

    func resume() {
        suppressionCount = max(0, suppressionCount - 1)
    }

    func stop() {
        timeout = nil
        cancelTimer()
        observationGeneration &+= 1
        rearmScheduled = false
    }

    private func arm(after delay: TimeInterval) {
        cancelTimer()
        let milliseconds = guint(max(1, min(Double(guint.max), (delay * 1_000).rounded())))
        timeoutSource = g_timeout_add(
            milliseconds,
            onLinuxAutoFollowTimeout,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func cancelTimer() {
        guard timeoutSource != 0 else { return }
        g_source_remove(timeoutSource)
        timeoutSource = 0
    }

    private func observeAttention(generation: Int) {
        guard timeout != nil, generation == observationGeneration else { return }
        let coordinator = WeakLinuxAutoFollowCoordinator(self)
        withObservationTracking {
            _ = store.attentionSessions
        } onChange: {
            runOnMain {
                MainActor.assumeIsolated {
                    coordinator.value?.scheduleAttentionRearm(generation: generation)
                }
            }
        }
    }

    private func scheduleAttentionRearm(generation: Int) {
        guard generation == observationGeneration, timeout != nil, !rearmScheduled else { return }
        rearmScheduled = true
        runOnMain { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rearmScheduled = false
                guard generation == self.observationGeneration, let timeout = self.timeout else { return }
                self.arm(after: timeout)
                self.observeAttention(generation: generation)
            }
        }
    }

    fileprivate func fire() {
        timeoutSource = 0
        guard suppressionCount == 0 else { return }
        let current = store.activeSession
        if current?.agentIndicator.status == .blocked { return }
        if stayOnActive, current?.agentIndicator.status == .active { return }
        let blocked = store.attentionSessions.filter {
            $0.agentIndicator.status == .blocked && !$0.autoFollowConsumed
        }
        guard let target = blocked.min(by: {
            ($0.statusChangedAt ?? .distantFuture) < ($1.statusChangedAt ?? .distantFuture)
        }) else { return }
        let statusPane = target.agentIndicator.statusPane
        store.selectSession(target.id)
        target.autoFollowConsumed = true
        handleAutoFollow(target.id, statusPane: statusPane)
    }
}

private final class WeakLinuxAutoFollowCoordinator: @unchecked Sendable {
    weak var value: LinuxAutoFollowCoordinator?

    init(_ value: LinuxAutoFollowCoordinator) {
        self.value = value
    }
}

private let onLinuxAutoFollowTimeout: @MainActor @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    MainActor.assumeIsolated {
        Unmanaged<LinuxAutoFollowCoordinator>.fromOpaque(data).takeUnretainedValue().fire()
    }
    return 0
}

@MainActor
extension AppController {
    func noteUserActivity() {
        store.noteUserActivity()
        autoFollowCoordinator.noteUserActivity()
    }

    func suppressAutoFollow() {
        autoFollowCoordinator.suppress()
    }

    func resumeAutoFollow() {
        autoFollowCoordinator.resume()
    }

    func projectingLinuxAutoFollow(_ tree: ControlTree) -> ControlTree {
        ControlTree(
            workspaces: tree.workspaces,
            idleMs: tree.idleMs,
            autoFollowMs: autoFollowCoordinator.timeoutMs,
            sidebarVisible: tree.sidebarVisible,
            sidebarMode: tree.sidebarMode,
            quickVisible: tree.quickVisible,
            zoomedSurface: tree.zoomedSurface,
            dashboardMembers: tree.dashboardMembers,
            dashboardHighlighted: tree.dashboardHighlighted,
            dashboardFontSize: tree.dashboardFontSize,
            dashboardFontMode: tree.dashboardFontMode
        )
    }

    func projectingLinuxAutoFollow(_ nodes: [ControlWindowNode]) -> [ControlWindowNode] {
        nodes.map { node in
            let autoFollowMs = UUID(uuidString: node.id)
                .flatMap { gWindows[$0]?.autoFollowCoordinator.timeoutMs }
            return ControlWindowNode(
                id: node.id,
                name: node.name,
                open: node.open,
                active: node.active,
                autoFollowMs: autoFollowMs,
                sidebarVisible: node.sidebarVisible,
                geometry: node.geometry,
                fullscreen: node.fullscreen,
                zoomed: node.zoomed
            )
        }
    }
}
