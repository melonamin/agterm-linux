import Foundation
import agtermCore
#if canImport(Glibc)
import Glibc
#endif

enum LinuxRemoteCommand {
    static let treeDeadline: TimeInterval = 8
    private static let terminationGrace: TimeInterval = 0.25

    static func run(_ argv: [String], deadline: TimeInterval) -> RemoteCommandResult {
        guard let command = argv.first, let executable = resolveExecutable(command) else {
            return RemoteCommandResult(status: 127, stdout: "", stderr: "command not found: \(argv.first ?? "")")
        }
        let output = TemporaryOutput()
        let errors = TemporaryOutput()
        guard let output, let errors else {
            return RemoteCommandResult(status: 1, stdout: "", stderr: "could not create command output files")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = output.handle
        process.standardError = errors.handle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return RemoteCommandResult(status: 1, stdout: "", stderr: String(describing: error))
        }
        if finished.wait(timeout: .now() + deadline) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + terminationGrace) == .timedOut {
                _ = Glibc.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            output.closeForReading()
            errors.closeForReading()
            return RemoteCommandResult(status: 124, stdout: output.read(), stderr: "remote command timed out")
        }
        output.closeForReading()
        errors.closeForReading()
        return RemoteCommandResult(status: process.terminationStatus,
                                   stdout: output.read(), stderr: errors.read())
    }

    private static func resolveExecutable(_ command: String) -> String? {
        if command.hasPrefix("/") { return command }
        for directory in ["/usr/bin", "/bin", "/usr/local/bin"] {
            let candidate = directory + "/" + command
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

private final class TemporaryOutput {
    let path: String
    let handle: FileHandle

    init?() {
        var template = Array("/tmp/agterm-remote-XXXXXX".utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { return nil }
        path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    func closeForReading() {
        try? handle.synchronize()
        try? handle.close()
    }

    func read() -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
