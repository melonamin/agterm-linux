import Foundation

/// A skipped free leaves the engine live until process exit, its threads and pty running, still using its config
/// buffers, the owner context and its unretained `userdata`. This holds all of them for the process lifetime and is the
/// explicit state: `surface == nil` also describes every wrapper before creation.
///
/// Keys are raw `userdata` bits and never dereferenced. The lock is never held while logging or calling host code.
final class LinuxSurfaceQuarantine<Record>: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UInt: Record] = [:]
    private var droppedKinds: Set<String> = []
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    static func key(_ userdata: UnsafeRawPointer?) -> UInt {
        UInt(bitPattern: userdata)
    }

    var count: Int {
        lock.withLock { records.count }
    }

    func contains(_ key: UInt) -> Bool {
        lock.withLock { records[key] != nil }
    }

    func insert(_ record: Record, key: UInt) {
        lock.withLock {
            if records[key] == nil { records[key] = record }
        }
    }

    /// Moves `storage` and `configs` into the record, so the caller's release lines find nothing and cannot free
    /// what the engine still reads.
    func transfer<Storage, Config>(key: UInt, storage: inout Storage?, configs: inout [Config],
                                   makeRecord: (Storage?, [Config]) -> Record) {
        insert(makeRecord(storage, configs), key: key)
        storage = nil
        configs = []
    }

    /// Logs each kind once; a live engine can repeat an action forever.
    func dropped(_ kind: String) {
        let first = lock.withLock { droppedKinds.insert(kind).inserted }
        if first { log("\(LinuxRetainedGLTeardown.logPrefix) dropped \(kind)") }
    }

    /// True, after logging, when an entry check must return before touching GTK or the model.
    func drops(_ key: UInt, kind: String) -> Bool {
        guard contains(key) else { return false }
        dropped(kind)
        return true
    }

    /// The write prompt's response. Its entry checks ran when the prompt was shown, not at the answer.
    func writeAnswer(key: UInt, write: @escaping () -> Void) -> (Bool) -> Void {
        { [self] allowed in
            guard allowed, !drops(key, kind: "clipboard write") else { return }
            write()
        }
    }

    /// A queued exit hop. `handleProcessExit` runs `finishExitCodeCapture` before `onExit`, and that capture can mutate
    /// the store, so clearing `onExit` alone would not stop it.
    func exitHop(key: UInt, handleExit: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        { [self] in
            guard !drops(key, kind: "close") else { return }
            handleExit()
        }
    }
}
