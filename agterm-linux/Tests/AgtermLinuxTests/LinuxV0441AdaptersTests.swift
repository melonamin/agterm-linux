import Foundation
import Glibc
import Testing
import agtermCore
@testable import AgtermLinux

@Suite struct LinuxV0441AdaptersTests {
    @Test func openerRunsVerbatimWithPathInEnvironment() {
        let line = "printf '%s' \"${AGT_PATH}\"; echo '{AGT_SESSION_NAME}'"
        let command = CustomCommand(name: "*.txt", command: line, shortcut: "")
        let context = CommandContext(sessionID: "session", sessionName: "expanded", sessionPWD: "/remote/project", pane: .right)
        let path = "/cache/file with 'quotes'.txt"
        let request = LinuxCustomCommandProcess.request(command: command, context: context,
            baseEnvironment: ["HOME": "/local/home"], localWorkingDirectory: "/local/home", openerPath: path)
        #expect(request.arguments == ["-c", line])
        #expect(request.environment["AGT_PATH"] == path)
        #expect(request.environment["AGT_PANE"] == "right")
        #expect(request.currentDirectoryPath == "/local/home")
    }

    @Test func uriDropsKeepFilesDistinctFromLiteralText() {
        let offer = LinuxPasteClipboard.dropOffer("# files\nfile:///home/user/a%20b\nhttps://example.com/x\n")
        #expect(offer.fileURLs.map(\.path) == ["/home/user/a b"])
        #expect(offer.route(onOrigin: true) == .sendToOrigin)
        #expect(offer.insertText(filePaths: ["/origin/copy"]) == "/origin/copy https://example.com/x")
        #expect(LinuxPasteClipboard.dropOffer("ordinary text").fileURLs.isEmpty)
    }

    @Test func processRowsRequireATerminalSessionLeader() {
        #expect(LinuxZmxDaemonForeground.row(pid: 10, stat: "10 (shell (nested)) S 9 10 10 34816 11 0") ==
            ZmxDaemonLeader.Row(parent: 9, ownsTerminal: true, foreground: 11))
        #expect(LinuxZmxDaemonForeground.row(pid: 10, stat: "10 (worker) S 9 10 9 0 -1 0") ==
            ZmxDaemonLeader.Row(parent: 9, ownsTerminal: false, foreground: 0))
    }

    @Test func kernelCaptureFindsARealStoppedDaemonWithoutAListing() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent("vendor/zmx/zmx")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zk-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func invoke(_ arguments: [String]) throws {
            var environment = ProcessInfo.processInfo.environment
            environment["ZMX_DIR"] = directory.path
            environment["ZMX_SESSION"] = nil
            environment["ZMX_SESSION_PREFIX"] = nil
            let descriptor = Glibc.open("/dev/null", O_RDWR | O_CLOEXEC)
            defer { _ = Glibc.close(descriptor) }
            let process = try LinuxChildProcess(argv: [executable.path] + arguments, environment: environment,
                                                input: descriptor, output: descriptor, errors: descriptor)
            let status = process.wait(until: Date().addingTimeInterval(5))
            if status == nil { process.terminate(signal: SIGKILL) }
            #expect(status == 0)
        }
        try invoke(["attach", "--detached", "capture", "/bin/sh", "-c", "exec sleep 300"])
        defer { try? invoke(["kill", "capture", "--force"]) }
        let snapshot = LinuxZmxDaemonForeground.snapshot(directory: directory.path)
        let daemon = try #require(snapshot.daemons["capture"])
        let leader = try #require(snapshot.leader(name: "capture"))
        #expect(snapshot.foreground(name: "capture") == leader)
        #expect(kill(daemon, SIGSTOP) == 0)
        defer { _ = kill(daemon, SIGCONT) }
        let started = Date()
        let stopped = LinuxZmxDaemonForeground.snapshot(directory: directory.path)
        #expect(stopped.leader(name: "capture") == leader)
        #expect(stopped.foreground(name: "capture") == leader)
        #expect(Date().timeIntervalSince(started) < 0.5)
    }
}
