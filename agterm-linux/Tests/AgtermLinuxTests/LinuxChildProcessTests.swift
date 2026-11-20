import Foundation
import Glibc
import Testing
@testable import AgtermLinux

@Suite(.serialized)
struct LinuxChildProcessTests {
    @Test func childDoesNotInheritItsOwnInputWriter() throws {
        let input = Pipe()
        let null = try FileHandle(forUpdating: URL(fileURLWithPath: "/dev/null"))
        defer { try? null.close() }
        let child = try LinuxChildProcess(argv: ["/bin/sh", "-c", "IFS= read -r ignored"],
                                         environment: ProcessInfo.processInfo.environment,
                                         input: input.fileHandleForReading.fileDescriptor,
                                         output: null.fileDescriptor, errors: null.fileDescriptor)
        defer { child.terminate(signal: SIGKILL); _ = child.wait(until: Date().addingTimeInterval(2)) }
        try input.fileHandleForReading.close()
        try input.fileHandleForWriting.close()
        #expect(child.wait(until: Date().addingTimeInterval(2)) == 1)
    }

    @Test func descriptorClosingChildDoesNotBlockFoundationProcessCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("close-fds")
        let source = """
        #include <unistd.h>
        int main(void) {
            for (int fd = 3; fd < 1024; ++fd) close(fd);
            write(1, "ready", 5);
            for (;;) pause();
        }
        """
        let built = LinuxRemoteCommand.run(["cc", "-x", "c", "-o", executable.path, "-"], deadline: 10, input: Data(source.utf8))
        #expect(built.status == 0, Comment(rawValue: built.stderr))
        let output = Pipe()
        let null = try FileHandle(forUpdating: URL(fileURLWithPath: "/dev/null"))
        defer { try? null.close() }
        let child = try LinuxChildProcess(argv: [executable.path], environment: ProcessInfo.processInfo.environment,
                                         input: null.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor,
                                         errors: null.fileDescriptor)
        defer { child.terminate(signal: SIGKILL); _ = child.wait(until: Date().addingTimeInterval(2)) }
        try output.fileHandleForWriting.close()
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        #expect(poll(&descriptor, 1, 2_000) == 1)
        #expect(try output.fileHandleForReading.read(upToCount: 5) == Data("ready".utf8))
        #expect(child.wait(until: Date().addingTimeInterval(0.01)) == nil)
        let other = LinuxRemoteCommand.run(["/bin/sh", "-c", "exit 7"], deadline: 2)
        #expect(other.status == 7)
        child.terminate()
        #expect(child.wait(until: Date().addingTimeInterval(2)) == 128 + SIGTERM)
        try output.fileHandleForReading.close()
    }
}
