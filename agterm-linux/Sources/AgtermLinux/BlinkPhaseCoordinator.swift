import CGtk
import Foundation

/// Owns the ONE repeating blink source per window: a repeating timer stays on the Linux side with a direct
/// `g_timeout_add` (`.claude/rules/main-loop.md`; `MainTimer` is one-shot). The tick flips the phase and
/// hands it to an apply closure that writes every marked label, so the pulse costs one main-loop wakeup per
/// half period. `windowWillClose` must `cancel()`: the apply closure touches widgets GTK is about to
/// destroy, and a live `[weak self]` controller cannot tell that tree apart from a fresh one.
@MainActor
final class BlinkPhaseCoordinator {
    private(set) var phase = false
    private var cancelTimer: (@MainActor () -> Void)?
    private var apply: (@MainActor (Bool) -> Void)?
    private let start: @MainActor (TimeInterval, @escaping @MainActor () -> Bool) -> (@MainActor () -> Void)

    init(start: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Bool)
        -> (@MainActor () -> Void) = { BlinkPhaseSource.start(interval: $0, tick: $1) }) {
        self.start = start
    }

    var isArmed: Bool { cancelTimer != nil }

    /// Arm or disarm to match `shouldRun`. Arming while already armed applies nothing but rebinds `apply`,
    /// so the tick always resolves the CURRENT widget maps; a label that just started blinking is already
    /// in step, since `applyStatusGlyph` writes the live phase when it adds the marker.
    func resync(shouldRun: Bool, apply: @escaping @MainActor (Bool) -> Void) {
        guard shouldRun else {
            guard isArmed else { return }
            cancel()
            apply(false)
            return
        }
        self.apply = apply
        guard !isArmed else { return }
        cancelTimer = start(LinuxBlinkPolicy.halfPeriod) { [weak self] in
            guard let self else { return false }
            tick()
            return true
        }
    }

    /// Stop the pulse and forget the apply closure. Idempotent; leaves the phase undimmed so the next arm
    /// starts from full opacity.
    func cancel() {
        cancelTimer?()
        cancelTimer = nil
        apply = nil
        phase = false
    }

    private func tick() {
        guard isArmed else { return }
        phase.toggle()
        apply?(phase)
    }
}

/// One repeating `g_timeout_add_full` source retaining this box as its user data; the destroy notify
/// balances that retain on fire-through-cancel (`g_source_remove` triggers it too).
@MainActor
private final class BlinkPhaseSource {
    private var sourceID: guint = 0
    private let tick: @MainActor () -> Bool

    static func start(
        interval: TimeInterval, tick: @escaping @MainActor () -> Bool
    ) -> (@MainActor () -> Void) {
        let source = BlinkPhaseSource(interval: interval, tick: tick)
        return { source.cancel() }
    }

    private init(interval: TimeInterval, tick: @escaping @MainActor () -> Bool) {
        self.tick = tick
        let ms = (interval * 1000).rounded()
        let clamped = ms.isFinite ? guint(min(max(1, ms), Double(guint.max))) : guint.max
        sourceID = g_timeout_add_full(G_PRIORITY_DEFAULT, clamped, onBlinkPhaseTick,
                                      Unmanaged.passRetained(self).toOpaque(), releaseBlinkPhaseSource)
    }

    /// Whether the source survives. A coordinator deallocated while armed answers false, so its orphaned
    /// timer removes itself on the first fire instead of waking the main loop for the process lifetime.
    fileprivate func fire() -> Bool {
        guard tick() else {
            sourceID = 0
            return false
        }
        return true
    }

    fileprivate func cancel() {
        guard sourceID != 0 else { return }
        _ = g_source_remove(sourceID)
        sourceID = 0
    }
}

private let onBlinkPhaseTick: @MainActor @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    let source = Unmanaged<BlinkPhaseSource>.fromOpaque(data).takeUnretainedValue()
    return MainActor.assumeIsolated { source.fire() ? 1 : 0 }   // G_SOURCE_CONTINUE / G_SOURCE_REMOVE
}

private let releaseBlinkPhaseSource: @MainActor @convention(c) (gpointer?) -> Void = { data in
    guard let data else { return }
    Unmanaged<BlinkPhaseSource>.fromOpaque(data).release()
}
