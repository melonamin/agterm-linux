import CGtk
import Foundation
import Glibc
import agtermCore

/// Match filesystem sockets to kernel listener inodes, then their current owner in /proc.
/// Neither a stopped daemon nor zmx's unlinked temporary bind path requires a daemon request.
enum LinuxZmxDaemonForeground {
    struct Snapshot: Sendable {
        let daemons: [String: Int32]

        func foreground(name: String) -> Int32? {
            guard let daemon = daemons[name] else { return nil }
            return ZmxDaemonLeader.foreground(ofDaemon: daemon, children: children(daemon), row: row)
        }

        func leader(name: String) -> Int32? {
            guard let daemon = daemons[name] else { return nil }
            return ZmxDaemonLeader.leader(ofDaemon: daemon, children: children(daemon), row: row)
        }
    }

    private struct FileID: Hashable {
        let inode: UInt32
        init(inode: UInt32) { self.inode = inode }
        init?(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { return nil }
            inode = UInt32(truncatingIfNeeded: info.st_ino)
        }
    }

    static func foreground(directory: String, name: String) -> Int32? { snapshot(directory: directory).foreground(name: name) }
    static func leader(directory: String, name: String) -> Int32? { snapshot(directory: directory).leader(name: name) }

    /// A capture shares one socket/fd walk; each pane then reads only its own daemon's child and terminal record.
    static func snapshot(directory: String) -> Snapshot {
        guard let processes = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return Snapshot(daemons: [:]) }
        var listeners = [agterm_unix_listener_t](repeating: agterm_unix_listener_t(), count: 16384)
        let count = listeners.withUnsafeMutableBufferPointer { agterm_unix_listeners($0.baseAddress, $0.count) }
        guard count >= 0 else { return Snapshot(daemons: [:]) }
        let root = URL(fileURLWithPath: directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var endpoints: [FileID: Set<String>] = [:]
        for listener in listeners.prefix(Int(count)) {
            // Overlayfs can expose a different stat device from UNIX_DIAG_VFS's underlying device.
            // Require one unique matching listener inode across the entire dump instead of guessing a device.
            let file = FileID(inode: listener.filesystem_inode)
            endpoints[file, default: []].insert(String(listener.socket_inode))
        }
        var sockets: [String: Set<String>] = [:]
        for name in names where !name.hasPrefix(".") {
            // Public names remain after zmx unlinks its temporary bind path.
            let path = root.appendingPathComponent(name).resolvingSymlinksInPath().path
            guard let file = FileID(path) else { continue }
            sockets[name] = endpoints[file]
        }
        let wanted = Set(sockets.values.flatMap { $0 })
        guard !wanted.isEmpty else { return Snapshot(daemons: [:]) }
        var owners: [String: Set<Int32>] = [:]
        for process in processes {
            guard let pid = Int32(process) else { continue }
            let root = "/proc/" + process
            var info = stat()
            guard lstat(root, &info) == 0, info.st_uid == geteuid(),
                  let descriptors = try? FileManager.default.contentsOfDirectory(atPath: root + "/fd") else { continue }
            for fd in descriptors {
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/fd/" + fd),
                      target.hasPrefix("socket:["), target.hasSuffix("]") else { continue }
                let inode = String(target.dropFirst(8).dropLast())
                if wanted.contains(inode) { owners[inode, default: []].insert(pid) }
            }
        }
        let daemons = sockets.compactMapValues { inodes -> Int32? in
            // Unlinked/replaced sockets can retain the same path; an ambiguous listener is unknown.
            guard inodes.count == 1, let inode = inodes.first, let pids = owners[inode], pids.count == 1 else { return nil }
            return pids.first
        }
        return Snapshot(daemons: daemons)
    }

    private static func children(_ pid: Int32) -> [Int32] {
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/task/\(pid)/children", encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    }

    private static func row(_ pid: Int32) -> ZmxDaemonLeader.Row? {
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else { return nil }
        return row(pid: pid, stat: text)
    }

    static func row(pid: Int32, stat text: String) -> ZmxDaemonLeader.Row? {
        guard let close = text.lastIndex(of: ")") else { return nil }
        let fields = text[text.index(after: close)...].split(whereSeparator: \.isWhitespace)
        guard fields.count > 5, let parent = Int32(fields[1]), let session = Int32(fields[3]),
              let tty = Int64(fields[4]), let foreground = Int32(fields[5]) else { return nil }
        return ZmxDaemonLeader.Row(parent: parent, ownsTerminal: session == pid && tty != 0, foreground: max(0, foreground))
    }
}
