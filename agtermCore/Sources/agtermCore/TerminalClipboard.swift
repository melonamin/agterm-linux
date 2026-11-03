import Foundation

/// TerminalClipboard prints an OSC 52 clipboard write into the caller's pane through its zmx daemon, so
/// the write reaches every terminal attached to the pane, including one on another Mac.
public enum TerminalClipboard {
    /// maxEncodedBytes stays under the 8 MiB above which libghostty drops an OSC whole; the margin covers
    /// the `52;c;` prefix and the terminator.
    public static let maxEncodedBytes = 8 * 1024 * 1024 - 64

    public enum Failure: Error, Equatable {
        case emptyText
        case tooLarge(encodedBytes: Int)
        /// notLivePane means the environment names no agterm zmx daemon. A scratch, quick or overlay
        /// terminal has none.
        case notLivePane
        /// zmxNotFound carries where zmx was expected, nil when the CLI's own path is unknown.
        case zmxNotFound(path: String?)
        case printFailed(status: Int32, stderr: String)
    }

    static func sequence(for text: Data) throws -> Data {
        guard !text.isEmpty else { throw Failure.emptyText }
        let encoded = text.base64EncodedData()
        guard encoded.count <= maxEncodedBytes else { throw Failure.tooLarge(encodedBytes: encoded.count) }
        return Data("\u{1b}]52;c;".utf8) + encoded + Data([0x07])
    }

    /// daemon is the pane's zmx daemon name. Only a name agterm would have created is accepted, so a
    /// `ZMX_SESSION` inherited from an unrelated zmx session is never printed into. `ZMX_DIR` must be
    /// set because zmx reads it from the environment `copy` passes on.
    static func daemon(environment: [String: String]) throws -> String {
        guard let session = environment["ZMX_SESSION"], ZmxSupport.isDaemonName(session),
              let directory = environment["ZMX_DIR"], !directory.isEmpty else { throw Failure.notLivePane }
        return session
    }

    /// zmxPath is the zmx beside the CLI in `Contents/MacOS`; `clientPath` is the CLI's resolved real
    /// path. PATH is not searched: only the bundled zmx is known to match this build.
    static func zmxPath(clientPath: String?, fileManager: FileManager = .default) throws -> String {
        guard let clientPath else { throw Failure.zmxNotFound(path: nil) }
        let path = ((clientPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("zmx")
        guard fileManager.isExecutableFile(atPath: path) else { throw Failure.zmxNotFound(path: path) }
        return path
    }

    /// copy returns once `zmx print` exits zero. That confirms neither that the daemon received the
    /// write nor that a terminal applied it: zmx reads no reply, and each terminal applies its own
    /// clipboard-write policy.
    public static func copy(_ text: Data, clientPath: String?, environment: [String: String],
                            zmx: String? = nil) throws {
        let sequence = try sequence(for: text)
        let daemon = try daemon(environment: environment)
        let executable = try zmx ?? zmxPath(clientPath: clientPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["print", daemon]
        // empty is unset to zmx; an inherited prefix would resolve a name agterm never created
        process.environment = environment.merging(["ZMX_SESSION": "", "ZMX_SESSION_PREFIX": ""]) { _, new in new }
        let input = try inputHandles()
        defer {
            try? input.read.close()
            try? input.write.close()
        }
        let stderr = Pipe()
        process.standardInput = input.read
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        try? input.read.close()
        // a zmx that exits before reading everything must surface as its status, not kill this process
        #if canImport(Darwin)
        _ = fcntl(input.write.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? input.write.write(contentsOf: sequence)
        #else
        sequence.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Glibc.send(input.write.fileDescriptor, bytes.baseAddress! + offset,
                                       bytes.count - offset, Int32(MSG_NOSIGNAL))
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                offset += count
            }
        }
        #endif
        try? input.write.close()
        let diagnostics = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.printFailed(status: process.terminationStatus,
                                      stderr: String(decoding: diagnostics, as: UTF8.self))
        }
    }

    private static func inputHandles() throws -> (read: FileHandle, write: FileHandle) {
        #if canImport(Darwin)
        let pipe = Pipe()
        return (pipe.fileHandleForReading, pipe.fileHandleForWriting)
        #else
        // A socket pair supports per-write SIGPIPE suppression without changing process signal policy.
        var descriptors: [Int32] = [-1, -1]
        let type = Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
        guard socketpair(AF_UNIX, type, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
                FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true))
        #endif
    }
}
