import Foundation
import agtermCore

enum LinuxProcessStandardIO: Sendable, Equatable {
    case null
    case stderrFile(String)
}

struct LinuxProcessLaunchRequest: Sendable, Equatable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryPath: String?
    let standardIO: LinuxProcessStandardIO
}

enum LinuxCommandPath {
    private static let systemDefault = "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

    static var bundledCLIDirectory: String? {
        let executable = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        return resolvedExecutableDirectory(executable)
    }

    static func resolvedExecutableDirectory(_ executable: String?) -> String? {
        guard let executable, executable.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: executable).standardizedFileURL.deletingLastPathComponent().path
    }

    static func widened(
        _ path: String?, bundledCLIDirectory: String?, homeDirectory: String
    ) -> String {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ entry: String) {
            guard !entry.isEmpty, seen.insert(entry).inserted else { return }
            result.append(entry)
        }
        bundledCLIDirectory.map(add)
        let base = path.flatMap { $0.isEmpty ? nil : $0 } ?? systemDefault
        base
            .split(separator: ":", omittingEmptySubsequences: true).forEach { add(String($0)) }
        add((homeDirectory as NSString).appendingPathComponent(".local/bin"))
        systemDefault.split(separator: ":").forEach { add(String($0)) }
        return result.joined(separator: ":")
    }
}

protocol LinuxProcessLaunching: Sendable {
    func launch(
        _ request: LinuxProcessLaunchRequest,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws
}

struct FoundationLinuxProcessLauncher: LinuxProcessLaunching {
    func launch(
        _ request: LinuxProcessLaunchRequest,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        process.environment = request.environment
        if let path = request.currentDirectoryPath {
            process.currentDirectoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        switch request.standardIO {
        case .null:
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        case .stderrFile(let path):
            let stderr = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? stderr.close() }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr
            process.terminationHandler = { onTermination($0.terminationStatus) }
            try process.run()
            return
        }
        process.terminationHandler = { onTermination($0.terminationStatus) }
        try process.run()
    }
}

enum LinuxCustomCommandFailure: Sendable, Equatable {
    case launch(String)
    case exit(Int32, String?)

    var reason: String {
        switch self {
        case .launch(let detail): detail
        case .exit(let status, _): "exit \(status)"
        }
    }

    var detail: String? {
        if case .exit(_, let detail) = self { return detail }
        return nil
    }

    func toast(commandName: String) -> String {
        switch self {
        case .launch(let detail): "command failed to launch: \(commandName) — \(detail)"
        case .exit(let status, _): "command failed (exit \(status)): \(commandName)"
        }
    }
}

enum LinuxCustomCommandProcess {
    /// The environment-assembly choke point for custom commands, which is why the GDK restore is applied
    /// here rather than at a caller or in a replaceable default argument. It must WIN over the assembled
    /// environment (`restoringChildEnvironment`): the base is normally a copy of agterm's own already-
    /// mutated process environment, so losing to the caller would hand the child the overrides straight
    /// back.
    static func request(
        command: CustomCommand, context: CommandContext, baseEnvironment: [String: String],
        stderrPath: String? = nil, localWorkingDirectory: String? = nil
    ) -> LinuxProcessLaunchRequest {
        var environment = baseEnvironment.merging(context.environment()) { _, commandValue in commandValue }
        let home = baseEnvironment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = LinuxCommandPath.widened(
            baseEnvironment["PATH"], bundledCLIDirectory: LinuxCommandPath.bundledCLIDirectory,
            homeDirectory: home)
        environment = gdkEnvironment.restoringChildEnvironment(environment)
        return LinuxProcessLaunchRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", context.expand(command.command)],
            environment: environment,
            currentDirectoryPath: (localWorkingDirectory ?? context.sessionPWD).isEmpty
                ? nil : (localWorkingDirectory ?? context.sessionPWD),
            standardIO: stderrPath.map(LinuxProcessStandardIO.stderrFile) ?? .null)
    }

    static func launch(
        command: CustomCommand,
        context: CommandContext,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        localWorkingDirectory: String? = nil,
        launcher: any LinuxProcessLaunching,
        onFailure: @escaping @Sendable (LinuxCustomCommandFailure) -> Void
    ) {
        let capture = command.errorHud ? LinuxCommandStderrCapture() : nil
        let request = request(command: command, context: context, baseEnvironment: baseEnvironment,
                              stderrPath: capture?.path, localWorkingDirectory: localWorkingDirectory)
        do {
            try launcher.launch(request) { status in
                let detail = capture?.consume()
                if status != 0 { onFailure(.exit(status, detail)) }
            }
        } catch {
            _ = capture?.consume()
            onFailure(.launch(error.localizedDescription))
        }
    }
}

/// A file lets a command's descendants keep stderr after the app exits without inheriting a broken pipe.
/// Read only the bounded tail on completion, then unlink it even after a successful command.
private final class LinuxCommandStderrCapture: @unchecked Sendable {
    let path: String

    init?() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-command-\(UUID().uuidString).err").path
        guard FileManager.default.createFile(atPath: path, contents: nil) else { return nil }
        self.path = path
    }

    func consume() -> String? {
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let reader = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? reader.close() }
        let size = (try? reader.seekToEnd()) ?? 0
        let wanted = min(size, UInt64(CommandFailure.tailLimit))
        try? reader.seek(toOffset: size - wanted)
        return CommandFailure.detail(fromTail: [UInt8]((try? reader.read(upToCount: Int(wanted))) ?? Data()))
    }
}

/// A per-controller generation token. Closing a window invalidates this instance; reopening the same
/// persisted window id creates a different token, so an old process completion cannot reach the new UI.
@MainActor
final class LinuxCustomCommandOrigin {
    let launcher: any LinuxProcessLaunching
    private(set) var isActive = true

    init(launcher: any LinuxProcessLaunching = FoundationLinuxProcessLauncher()) {
        self.launcher = launcher
    }

    func invalidate() { isActive = false }

    func deliverIfActive(_ action: () -> Void) {
        guard isActive else { return }
        action()
    }
}
