import Foundation

/// Which branch of the free ran. Anything but `ownerCurrent` with `.restored` is degraded and logged.
enum LinuxGLFreeOutcome: Sendable, Equatable {
    case ownerCurrent
    /// The free ran with nothing current, which can leave GPU objects alive.
    case noContext
    /// The free was skipped, so the engine is still running and must be quarantined.
    case leaked

    /// True for every branch that called free: its handle must never reach a later teardown.
    var calledFree: Bool { self != .leaked }
}

enum LinuxGLRestoreResult: Sendable, Equatable {
    /// Back on the prior context, no prior included.
    case restored
    /// A restore failed and the recovery cleared the slot.
    case cleared
    case failed
}

struct LinuxRetainedGLTeardownResult: Sendable, Equatable {
    let free: LinuxGLFreeOutcome
    let restore: LinuxGLRestoreResult
}

/// `makeCurrent` and `clear` report GDK's slot by read-back, not a native context: a disposed prior still in the slot
/// reads as restored, and GLX's clear ignores the native result.
struct LinuxRetainedGLTeardownSteps<Context: Equatable> {
    var displayIsOpen: () -> Bool
    var current: () -> Context?
    var retain: (Context) -> Void
    var release: (Context) -> Void
    var makeCurrent: (Context) -> Bool
    var clear: () -> Bool
    var free: () -> Void
    var log: (String) -> Void
}

enum LinuxRetainedGLTeardown {
    static let logPrefix = "agterm: retained GL context:"

    /// Runs on the GTK main thread with no nested main-loop iteration. Consumes `owner`'s ref unless the free was
    /// skipped, when the caller's quarantine keeps it.
    static func run<Context>(owner: Context, steps: LinuxRetainedGLTeardownSteps<Context>) -> LinuxRetainedGLTeardownResult {
        // GDK's make-current fast path has no closed-display test and its clear would enter the closed display.
        guard steps.displayIsOpen() else {
            steps.log("\(logPrefix) display closed; surface left running")
            return LinuxRetainedGLTeardownResult(free: .leaked, restore: .restored)
        }
        let prior = steps.current()
        if let prior { steps.retain(prior) }
        let free = freeUnderOwner(owner, steps: steps)
        let restore = restorePrior(prior, steps: steps)
        if let prior { steps.release(prior) }
        if free.calledFree { steps.release(owner) }
        return LinuxRetainedGLTeardownResult(free: free, restore: restore)
    }

    private static func freeUnderOwner<Context>(_ owner: Context, steps: LinuxRetainedGLTeardownSteps<Context>) -> LinuxGLFreeOutcome {
        if steps.makeCurrent(owner) {
            steps.free()
            return .ownerCurrent
        }
        guard steps.clear() else {
            steps.log("\(logPrefix) owner not current and the clear failed; surface left running")
            return .leaked
        }
        steps.free()
        steps.log("\(logPrefix) owner not current; freed with no context, possible GPU leak")
        return .noContext
    }

    private static func restorePrior<Context>(_ prior: Context?, steps: LinuxRetainedGLTeardownSteps<Context>) -> LinuxGLRestoreResult {
        let restored = prior.map(steps.makeCurrent) ?? steps.clear()
        if restored { return .restored }
        let cleared = steps.clear()
        steps.log("\(logPrefix) restore failed; \(cleared ? "cleared" : "current context unknown")")
        return cleared ? .cleared : .failed
    }
}

/// The widget-destroy half of a surface's lifetime, apart from GTK so its order can be tested with stand-ins.
@MainActor
protocol LinuxEngineSurfaceOwner: AnyObject {
    var isRealized: Bool { get }
    var awaitingSpawnPermit: Bool { get set }
    func dischargeEngineSurface()
}

enum LinuxSurfaceWidgetLifecycle {
    /// GTK's reference is released only at `destroy`, so this is the last moment `owner` can be pinned, and `closeQuick`
    /// reaches here before `teardown()`. `resumePacedSpawn` is the one creation path that could outlive the widget.
    @MainActor
    static func destroyed(_ owner: some LinuxEngineSurfaceOwner, releaseWidgetReference: () -> Void) {
        if owner.isRealized { owner.dischargeEngineSurface() }
        owner.awaitingSpawnPermit = false
        releaseWidgetReference()
    }
}
