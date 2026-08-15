import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux custom-command process launching")
struct LinuxCustomCommandProcessTests {
    @Test("requests preserve expansion, environment, cwd, pane, and null stdio")
    func requestPolicy() {
        let command = CustomCommand(
            name: "inspect", command: "printf '%s' \"$AGT_PANE\"; echo {AGT_PANE}:{AGT_SELECTION}",
            shortcut: "")
        for pane in [CommandContext.Pane.left, .right, .scratch] {
            let context = CommandContext(
                sessionID: "session", sessionName: "name", sessionPWD: "/tmp/work",
                workspaceID: "workspace", workspaceName: "work", windowID: "window",
                windowName: "main", pane: pane, selection: "selected", socket: "/tmp/agterm.sock")
            let request = LinuxCustomCommandProcess.request(
                command: command, context: context,
                baseEnvironment: ["KEEP": "yes", "AGT_PANE": "stale"])

            #expect(request.executablePath == "/bin/sh")
            #expect(request.arguments == [
                "-c", "printf '%s' \"$AGT_PANE\"; echo \(pane.rawValue):selected"
            ])
            #expect(request.environment["KEEP"] == "yes")
            #expect(request.environment["AGT_PANE"] == pane.rawValue)
            #expect(request.environment["AGT_SELECTION"] == "selected")
            #expect(request.currentDirectoryPath == "/tmp/work")
            #expect(request.standardIO == .null)
            #expect(request.environment["PATH"]?.contains("/.local/bin") == true)
        }
    }

    @Test("custom command PATH is Linux-native, bundled-first, stable, and deduplicated")
    func commandPath() {
        let path = LinuxCommandPath.widened(
            "/custom/bin:/usr/bin:/custom/bin", bundledCLIDirectory: "/app/bin",
            homeDirectory: "/home/test")
        #expect(path.split(separator: ":").map(String.init) == [
            "/app/bin", "/custom/bin", "/usr/bin", "/home/test/.local/bin",
            "/usr/local/bin", "/bin", "/usr/local/sbin", "/usr/sbin", "/sbin"
        ])
        #expect(!path.contains("homebrew"))
    }

    @Test("bundled CLI directory requires the resolved absolute executable path")
    func bundledCLIPath() {
        #expect(LinuxCommandPath.resolvedExecutableDirectory("agterm-linux") == nil)
        #expect(LinuxCommandPath.resolvedExecutableDirectory("/opt/agterm/bin/agterm-linux.bin")
                == "/opt/agterm/bin")
        #expect(LinuxCommandPath.bundledCLIDirectory?.hasPrefix("/") == true)
    }

    @Test("empty cwd is omitted")
    func emptyCwd() {
        let command = CustomCommand(name: "noop", command: "true", shortcut: "")
        let request = LinuxCustomCommandProcess.request(
            command: command, context: CommandContext(), baseEnvironment: [:])
        #expect(request.currentDirectoryPath == nil)
    }

    @Test("spawn errors and non-zero exits report while successful exits stay silent")
    func failureRouting() {
        let command = CustomCommand(name: "failure", command: "exit 19", shortcut: "")
        let context = CommandContext(sessionPWD: "/tmp", pane: .right)
        let failures = LockedValue<[LinuxCustomCommandFailure]>([])

        let throwing = RecordingProcessLauncher()
        throwing.error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        LinuxCustomCommandProcess.launch(
            command: command, context: context, baseEnvironment: [:], launcher: throwing
        ) { failure in failures.withValue { $0.append(failure) } }
        #expect(failures.value.count == 1)
        if case .launch(let detail) = failures.value[0] {
            #expect(!detail.isEmpty)
        } else {
            Issue.record("spawn error was not classified as a launch failure")
        }

        let running = RecordingProcessLauncher()
        LinuxCustomCommandProcess.launch(
            command: command, context: context, baseEnvironment: [:], launcher: running
        ) { failure in failures.withValue { $0.append(failure) } }
        running.finish(status: 0)
        #expect(failures.value.count == 1)

        LinuxCustomCommandProcess.launch(
            command: command, context: context, baseEnvironment: [:], launcher: running
        ) { failure in failures.withValue { $0.append(failure) } }
        running.finish(status: 19)
        #expect(failures.value.last == .exit(19))
    }

    @Test("Foundation launcher rejects a missing executable")
    func missingExecutable() {
        let launcher = FoundationLinuxProcessLauncher()
        let request = LinuxProcessLaunchRequest(
            executablePath: "/definitely/missing/agterm-command",
            arguments: [], environment: [:], currentDirectoryPath: nil, standardIO: .null)
        do {
            try launcher.launch(request) { _ in }
            Issue.record("missing executable unexpectedly launched")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test("Foundation launcher rejects an invalid working directory")
    func invalidWorkingDirectory() {
        let launcher = FoundationLinuxProcessLauncher()
        let request = LinuxProcessLaunchRequest(
            executablePath: "/bin/sh", arguments: ["-c", "true"], environment: [:],
            currentDirectoryPath: "/definitely/missing/agterm-cwd", standardIO: .null)
        do {
            try launcher.launch(request) { _ in }
            Issue.record("invalid working directory unexpectedly launched")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test("Foundation launcher reports successful and non-zero termination")
    func realTermination() async {
        let launcher = FoundationLinuxProcessLauncher()
        for (line, expected) in [("true", Int32(0)), ("exit 23", Int32(23))] {
            await confirmation { confirmed in
                let request = LinuxProcessLaunchRequest(
                    executablePath: "/bin/sh", arguments: ["-c", line], environment: [:],
                    currentDirectoryPath: "/tmp", standardIO: .null)
                do {
                    try launcher.launch(request) { status in
                        #expect(status == expected)
                        confirmed()
                    }
                } catch {
                    Issue.record("shell launch failed: \(error.localizedDescription)")
                    confirmed()
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    @Test("closing and reopening the same window id cannot reactivate an old origin")
    @MainActor
    func controllerIncarnation() async {
        let oldOrigin = LinuxCustomCommandOrigin()
        let launcher = RecordingProcessLauncher()
        let deliveries = LockedValue<[LinuxCustomCommandFailure]>([])
        let command = CustomCommand(name: "slow", command: "exit 29", shortcut: "")
        LinuxCustomCommandProcess.launch(
            command: command, context: CommandContext(), baseEnvironment: [:], launcher: launcher
        ) { [weak oldOrigin] failure in
            Task { @MainActor in
                oldOrigin?.deliverIfActive { deliveries.withValue { $0.append(failure) } }
            }
        }
        oldOrigin.invalidate()
        let reopenedOrigin = LinuxCustomCommandOrigin()
        launcher.finish(status: 29)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(deliveries.value.isEmpty)
        #expect(!oldOrigin.isActive)
        #expect(reopenedOrigin.isActive)
        #expect(oldOrigin !== reopenedOrigin)
    }
}

private final class RecordingProcessLauncher: LinuxProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    var error: (any Error)?
    private var completions: [@Sendable (Int32) -> Void] = []

    func launch(
        _: LinuxProcessLaunchRequest,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        completions.append(onTermination)
    }

    func finish(status: Int32) {
        lock.lock()
        let completion = completions.removeFirst()
        lock.unlock()
        completion(status)
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
