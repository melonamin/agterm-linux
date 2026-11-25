import Foundation
import Glibc
import Testing
@testable import AgtermLinux

@Suite("Linux control socket ownership")
struct ControlServerOwnershipTests {
    @Test("a second server refuses an already-owned socket without advertising it")
    func duplicateOwnerIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("agterm.sock").path

        let first = ControlServer(path: path)
        let second = ControlServer(path: path)
        defer {
            second.stop()
            first.stop()
        }

        #expect(first.resolvedSocketPath == path)
        #expect(second.resolvedSocketPath == path + ControlServer.unavailableSuffix)
        #expect(first.boundSocketPath == nil)
        #expect(second.boundSocketPath == nil)
    }

    @Test("stopping an owner releases the lock for a later server")
    func ownershipCanBeReacquired() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("agterm.sock").path

        let first = ControlServer(path: path)
        first.stop()
        let replacement = ControlServer(path: path)
        defer { replacement.stop() }

        #expect(replacement.resolvedSocketPath == path)
    }

    @Test("socket permissions are secured before listen")
    func permissionsPrecedeListen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("agterm.sock").path
        var acceptingDuringPermissionChange: Int32?

        let server = ControlServer(path: path, setSocketPermissions: { path, fd in
            acceptingDuringPermissionChange = socketAcceptingState(fd)
            return path.withCString { chmod($0, 0o600) }
        })
        defer { server.stop() }

        server.start()

        #expect(acceptingDuringPermissionChange == 0)
        #expect(server.boundSocketPath == path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test("a chmod failure removes the socket without listening")
    func permissionFailureDoesNotListen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("agterm.sock").path
        var acceptingDuringPermissionChange: Int32?

        let server = ControlServer(path: path, setSocketPermissions: { _, fd in
            acceptingDuringPermissionChange = socketAcceptingState(fd)
            errno = EACCES
            return -1
        })
        defer { server.stop() }

        server.start()

        #expect(acceptingDuringPermissionChange == 0)
        #expect(server.boundSocketPath == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

private func socketAcceptingState(_ fd: Int32) -> Int32? {
    var accepting: Int32 = -1
    var length = socklen_t(MemoryLayout.size(ofValue: accepting))
    guard getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &accepting, &length) == 0 else { return nil }
    return accepting
}
