import Foundation

/// Once per process, including repeated activation and cold URI delivery.
enum LinuxLaunchTrace {
    private static let storage = Storage()

    static func mark(_ milestone: String) {
        guard storage.insert(milestone) else { return }
        LinuxStructuredLogger(category: "launch").notice(milestone)
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = Set<String>()
        func insert(_ milestone: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return seen.insert(milestone).inserted
        }
    }
}
