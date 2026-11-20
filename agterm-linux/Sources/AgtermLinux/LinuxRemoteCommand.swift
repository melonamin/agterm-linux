import Foundation
import agtermCore
#if canImport(Glibc)
import Glibc
#endif

enum LinuxRemoteCommand {
    static let treeDeadline: TimeInterval = 8
    private static let terminationGrace: TimeInterval = 0.25

    static func run(_ argv: [String], deadline: TimeInterval,
                    input: Data? = nil) -> RemoteCommandResult {
        guard !argv.isEmpty else {
            return RemoteCommandResult(status: 127, stdout: "", stderr: "no command to run")
        }
        let output = TemporaryOutput()
        let errors = TemporaryOutput()
        let inputFile = input.flatMap(TemporaryInput.init)
        guard let output, let errors else {
            return RemoteCommandResult(status: 1, stdout: "", stderr: "could not create command output files")
        }
        if input != nil, inputFile == nil {
            return RemoteCommandResult(status: 1, stdout: "", stderr: "could not create command input file")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.environment = gdkEnvironment.restoringChildEnvironment(ProcessInfo.processInfo.environment)
        process.standardOutput = output.handle
        process.standardError = errors.handle
        if let inputFile { process.standardInput = inputFile.handle }
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

}

private final class TemporaryInput {
    let path: String
    let handle: FileHandle

    init?(data: Data) {
        var template = Array("/tmp/agterm-input-XXXXXX".utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { return nil }
        path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard data.withUnsafeBytes({ raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let count = Glibc.write(descriptor, base + offset, data.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }) else {
            Glibc.close(descriptor)
            unlink(path)
            return nil
        }
        _ = lseek(descriptor, 0, SEEK_SET)
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(atPath: path)
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
