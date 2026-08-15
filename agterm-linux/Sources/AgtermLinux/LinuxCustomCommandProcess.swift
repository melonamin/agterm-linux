import Foundation
import agtermCore

enum LinuxProcessStandardIO: Sendable, Equatable {
    case null
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
        }
        process.terminationHandler = { onTermination($0.terminationStatus) }
        try process.run()
    }
}

enum LinuxCustomCommandFailure: Sendable, Equatable {
    case launch(String)
    case exit(Int32)

    func toast(commandName: String) -> String {
        switch self {
        case .launch(let detail): "command failed to launch: \(commandName) — \(detail)"
        case .exit(let status): "command failed (exit \(status)): \(commandName)"
        }
    }
}

enum LinuxCustomCommandProcess {
    static func request(
        command: CustomCommand, context: CommandContext, baseEnvironment: [String: String]
    ) -> LinuxProcessLaunchRequest {
        var environment = baseEnvironment.merging(context.environment()) { _, commandValue in commandValue }
        let home = baseEnvironment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = LinuxCommandPath.widened(
            baseEnvironment["PATH"], bundledCLIDirectory: LinuxCommandPath.bundledCLIDirectory,
            homeDirectory: home)
        return LinuxProcessLaunchRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", context.expand(command.command)],
            environment: environment,
            currentDirectoryPath: context.sessionPWD.isEmpty ? nil : context.sessionPWD,
            standardIO: .null)
    }

    static func launch(
        command: CustomCommand,
        context: CommandContext,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        launcher: any LinuxProcessLaunching,
        onFailure: @escaping @Sendable (LinuxCustomCommandFailure) -> Void
    ) {
        let request = request(command: command, context: context, baseEnvironment: baseEnvironment)
        do {
            try launcher.launch(request) { status in
                if status != 0 { onFailure(.exit(status)) }
            }
        } catch {
            onFailure(.launch(error.localizedDescription))
        }
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
