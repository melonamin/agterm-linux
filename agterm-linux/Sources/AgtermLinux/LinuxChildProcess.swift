import Foundation
import Glibc

/// OpenSSH closes inherited descriptors, including Foundation.Process's exit-notification socket.
/// Own waitpid on a dedicated thread so a live SSH stream cannot park Foundation's global process watcher.
final class LinuxChildProcess: @unchecked Sendable {
    private let pid: pid_t
    private let state = NSCondition()
    private var running = true
    private var status: Int32?

    init(argv: [String], environment: [String: String], input: Int32, output: Int32, errors: Int32,
         onExit: @escaping @Sendable (Int32) -> Void = { _ in }) throws {
        var actions = posix_spawn_file_actions_t()
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (source, destination) in [(input, STDIN_FILENO), (output, STDOUT_FILENO), (errors, STDERR_FILENO)] {
            try Self.check(posix_spawn_file_actions_adddup2(&actions, source, destination))
        }
        // In particular, a bridge must not inherit the writer of its own stdin pipe and prevent EOF on stop.
        try Self.check(posix_spawn_file_actions_addclosefrom_np(&actions, STDERR_FILENO + 1))
        var attributes = posix_spawnattr_t()
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var empty = sigset_t(), defaults = sigset_t()
        sigemptyset(&empty)
        sigfillset(&defaults)
        try Self.check(posix_spawnattr_setsigmask(&attributes, &empty))
        try Self.check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try Self.check(posix_spawnattr_setpgroup(&attributes, 0))
        try Self.check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP)))
        var launched: pid_t = 0
        let result = try Self.withStrings(["/usr/bin/env"] + argv) { arguments in
            try Self.withStrings(environment.map { "\($0.key)=\($0.value)" }) { variables in
                posix_spawn(&launched, "/usr/bin/env", &actions, &attributes, arguments, variables)
            }
        }
        try Self.check(result)
        pid = launched
        let waiter = Thread { [self] in
            // Leave the exited child reserved until the status lock is held, so terminate cannot signal a reused pid.
            var info = siginfo_t()
            var result: Int32
            repeat { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while result < 0 && errno == EINTR
            state.lock()
            var code: Int32 = 0
            if result == 0 {
                repeat { result = waitpid(pid, &code, 0) } while result < 0 && errno == EINTR
            }
            let exit = result < 0 ? 127 : code & 0x7f == 0 ? (code >> 8) & 0xff : 128 + (code & 0x7f)
            running = false
            status = exit
            state.broadcast()
            state.unlock()
            onExit(exit)
        }
        waiter.name = "agterm.ssh.wait"
        waiter.start()
    }

    func terminate(signal: Int32 = SIGTERM) {
        state.lock()
        defer { state.unlock() }
        if running { _ = kill(pid, signal) }
    }

    /// Worker-only bounded wait; a cancelled command's reaper stays alive even if the caller times out.
    func wait(until deadline: Date) -> Int32? {
        state.lock()
        defer { state.unlock() }
        while running {
            if !state.wait(until: deadline), running { return nil }
        }
        return status
    }

    private static func check(_ result: Int32) throws {
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }

    private static func withStrings<T>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
        var pointers = strings.map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        guard pointers.dropLast().allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }
}
