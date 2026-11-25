import Foundation

/// The host's nonisolated-to-main-actor hop, used by observation callbacks that may run on any thread.
/// AppKit drains the default Dispatch queue; other hosts install their main-loop adapter at startup.
public enum MainActorHop {
    public typealias Scheduler = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private static let storage = Storage()

    public static func enqueue(_ work: @escaping @MainActor @Sendable () -> Void) {
        storage.read()(work)
    }

    /// Returns the previous adapter so a synchronous test fixture can restore it.
    @discardableResult
    public static func install(_ scheduler: @escaping Scheduler) -> Scheduler {
        storage.replace(scheduler)
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var scheduler: Scheduler = { work in
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }

        func read() -> Scheduler {
            lock.lock()
            defer { lock.unlock() }
            return scheduler
        }

        func replace(_ newer: @escaping Scheduler) -> Scheduler {
            lock.lock()
            defer { lock.unlock() }
            let previous = scheduler
            scheduler = newer
            return previous
        }
    }
}
