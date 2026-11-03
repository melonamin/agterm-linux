import Foundation
import Glibc
import Testing
import agtermCore

@Suite("agtermctl shared command executable")
struct SharedCommandProcessTests {
    @Test("help combines the shared catalog with Linux integration")
    func sharedHelp() throws {
        let result = try runCLI(["--help"])
        #expect(result.status == 0)
        #expect(result.output.contains("Drive agterm and manage local integrations."))
        #expect(result.output.contains("theme"))
        #expect(result.output.contains("integration"))
    }

    @Test("theme light and dark options use the shared request parser")
    func themeSetSlots() throws {
        let light = try runWithServer(["theme", "set", "--light", "Builtin Light"]) { request in
            #expect(request.cmd == .themeSet)
            #expect(request.args?.light == "Builtin Light")
            #expect(request.args?.dark == nil)
        }
        #expect(light.output == "ok\n")

        let dark = try runWithServer(["theme", "set", "--dark", "Nord"]) { request in
            #expect(request.cmd == .themeSet)
            #expect(request.args?.light == nil)
            #expect(request.args?.dark == "Nord")
        }
        #expect(dark.output == "ok\n")
    }

    @Test("theme list and affected results use shared human formatting")
    func sharedFormatting() throws {
        let themeResponse = ControlResponse(ok: true, result: ControlResult(
            theme: nil, themes: ["agterm", "Builtin Light", "Nord"],
            sync: true, light: "Builtin Light", dark: "agterm"))
        let themes = try runWithServer(["theme", "list"], response: themeResponse)
        #expect(themes.output.contains(
            "syncing with macOS appearance — light: Builtin Light, dark: agterm"))
        #expect(themes.output.contains("* agterm\n"))
        #expect(themes.output.contains("* Builtin Light\n"))
        #expect(themes.output.contains("  Nord\n"))

        let affectedResponse = ControlResponse(ok: true, result: ControlResult(affected: 2))
        let affected = try runWithServer([
            "session", "close", "--target", "one", "--target", "two",
        ], response: affectedResponse) { request in
            #expect(request.cmd == .sessionClose)
            #expect(request.args?.targets == ["one", "two"])
        }
        #expect(affected.output == "2 sessions\n")
    }

    @Test("stable pane tokens reach the shared session status request")
    func statusPaneID() throws {
        _ = try runWithServer([
            "session", "status", "blocked", "--pane", "right", "--pane-id", "token-123",
        ]) { request in
            #expect(request.cmd == .sessionStatus)
            #expect(request.args?.pane == "right")
            #expect(request.args?.paneID == "token-123")
        }
    }

    @Test("socket precedence is flag then state directory then Linux XDG application support")
    func socketPrecedence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agterm-cli-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let explicit = root.appendingPathComponent("explicit.sock").path
        let explicitServer = try OneShotControlServer(path: explicit)
        explicitServer.start()
        let explicitResult = try runCLI([
            "tree", "--socket", explicit,
        ], environment: ["AGTERM_STATE_DIR": root.appendingPathComponent("ignored-state").path])
        explicitServer.stop()
        #expect(explicitResult.status == 0)

        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let stateServer = try OneShotControlServer(path: state.appendingPathComponent("agterm.sock").path)
        stateServer.start()
        let stateResult = try runCLI(["tree"], environment: [
            "AGTERM_STATE_DIR": state.path,
            "XDG_DATA_HOME": root.appendingPathComponent("ignored-xdg").path,
        ])
        stateServer.stop()
        #expect(stateResult.status == 0)

        let xdg = root.appendingPathComponent("xdg", isDirectory: true)
        let appSupport = xdg.appendingPathComponent("agterm", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let xdgServer = try OneShotControlServer(path: appSupport.appendingPathComponent("agterm.sock").path)
        xdgServer.start()
        let xdgResult = try runCLI(["tree"], environment: ["XDG_DATA_HOME": xdg.path])
        xdgServer.stop()
        #expect(xdgResult.status == 0)
    }
}

private struct CLIResult {
    let status: Int32
    let output: String
    let error: String
}

private func runWithServer(
    _ arguments: [String],
    response: ControlResponse = ControlResponse(ok: true),
    inspect: (ControlRequest) -> Void = { _ in }
) throws -> CLIResult {
    let server = try OneShotControlServer(response: response)
    server.start()
    let result = try runCLI(arguments + ["--socket", server.path])
    server.stop()
    inspect(try #require(server.received))
    #expect(result.status == 0)
    return result
}

private func runCLI(_ arguments: [String], environment overrides: [String: String] = [:]) throws -> CLIResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent().appendingPathComponent("agtermctl-linux")
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "AGTERM_STATE_DIR")
    environment.removeValue(forKey: "XDG_DATA_HOME")
    for (key, value) in overrides { environment[key] = value }
    process.environment = environment
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    return CLIResult(
        status: process.terminationStatus,
        output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        error: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

private enum TestServerError: Error {
    case pathTooLong
}

private final class OneShotControlServer: @unchecked Sendable {
    let path: String
    private let response: ControlResponse
    private let queue = DispatchQueue(label: "agtermctl-linux-test-server")
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var receivedStorage: ControlRequest?

    var received: ControlRequest? {
        lock.lock()
        defer { lock.unlock() }
        return receivedStorage
    }

    init(path: String? = nil, response: ControlResponse = ControlResponse(ok: true)) throws {
        self.path = path ?? (NSTemporaryDirectory() + "agterm-cli-\(UUID().uuidString.prefix(8)).sock")
        self.response = response
        guard self.path.utf8CString.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw TestServerError.pathTooLong
        }
    }

    func start() {
        listenFD = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        precondition(listenFD >= 0)
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            destination.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buffer in
                bytes.withUnsafeBufferPointer { source in
                    buffer.update(from: source.baseAddress!, count: source.count)
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(result == 0)
        precondition(listen(listenFD, 1) == 0)
        queue.async { [self] in
            serve()
            finished.signal()
        }
    }

    private func serve() {
        let connection = Glibc.accept(listenFD, nil, nil)
        guard connection >= 0 else { return }
        defer { close(connection) }
        var requestData = Data()
        var byte: UInt8 = 0
        while read(connection, &byte, 1) == 1, byte != UInt8(ascii: "\n") {
            requestData.append(byte)
        }
        let request = try? JSONDecoder().decode(ControlRequest.self, from: requestData)
        lock.lock()
        receivedStorage = request
        lock.unlock()
        guard var responseData = try? JSONEncoder().encode(response) else { return }
        responseData.append(UInt8(ascii: "\n"))
        responseData.withUnsafeBytes { bytes in
            _ = write(connection, bytes.baseAddress, bytes.count)
        }
    }

    func stop() {
        _ = finished.wait(timeout: .now() + 3)
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }
}
