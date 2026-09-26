import Foundation
import agtermCore
#if canImport(Glibc)
import Glibc
#endif

/// Bounded process adapter for the pinned zmx CLI. Every invocation owns its Process and pipes, so the
/// immutable client can serve local inventory and remote-control workers concurrently.
final class LinuxZmxClient: @unchecked Sendable {
    static let captureInvocationTimeout: TimeInterval = 0.1
    static let terminationGrace: TimeInterval = 0.25

    struct Invocation: Sendable {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
        let timeout: TimeInterval
        let input: Data?
    }

    enum CommandError: Error, Equatable {
        case timedOut
        case failed(Int32, String)
    }

    typealias Runner = @Sendable (Invocation) throws -> String

    let executablePath: String
    let socketDirectory: String
    private let timeout: TimeInterval
    private let runner: Runner

    init(executablePath: String, socketDirectory: String, timeout: TimeInterval = 3,
         runner: @escaping Runner = LinuxZmxClient.run) {
        self.executablePath = executablePath
        self.socketDirectory = socketDirectory
        self.timeout = timeout
        self.runner = runner
    }

    var endpoint: ControlZmxEndpoint {
        ControlZmxEndpoint(executable: executablePath, socketDirectory: socketDirectory)
    }

    struct ReapOutcome: Equatable {
        let runningNames: Set<String>?
        let killedAll: Bool
    }

    @discardableResult
    func reap(knownPaneIdentities: Set<UUID>?, launchDecision: RestoreLaunchDecision) -> ReapOutcome {
        if launchDecision.requested == .live, knownPaneIdentities == nil {
            return ReapOutcome(runningNames: nil, killedAll: true)
        }
        guard let sessions = listSessions() else {
            return ReapOutcome(runningNames: nil, killedAll: false)
        }
        let running = Set(sessions.filter { $0.clients != nil }.map(\.name))
        let knownNames = knownPaneIdentities.map { Set($0.map(ZmxSupport.daemonName(for:))) }
        guard let names = ZmxReapPolicy.namesToKill(
            sessions: sessions, requestedMode: launchDecision.requested, knownNames: knownNames
        ) else {
            return ReapOutcome(runningNames: running, killedAll: true)
        }
        return ReapOutcome(runningNames: running, killedAll: kill(names: names))
    }

    @discardableResult
    func kill(paneIdentities: [UUID]) -> Bool {
        kill(names: paneIdentities.map(ZmxSupport.daemonName(for:)))
    }

    func listSessions() -> [ZmxSessionRecord]? {
        try? ZmxListParser.parse(invoke(["list"]))
    }

    func screen(name: String, all: Bool) -> ZmxScreen? {
        guard let output = try? invoke(["screen", name] + (all ? ["--all"] : [])) else { return nil }
        return ZmxScreen(output: output)
    }

    func type(name: String, bytes: [UInt8]) -> Bool {
        (try? invoke(["type", name], input: Data(bytes))) != nil
    }

    func sessionLeaderPIDs() -> [String: Int32]? {
        listSessions().map(ZmxLeaderMap.leaders(in:))
    }

    enum KillOutcome: Equatable {
        case killed
        case staleSocket
        case failed(String)
    }

    func killObservedOrphan(names: [String]) -> [String: KillOutcome] {
        var outcomes: [String: KillOutcome] = [:]
        for name in Set(names) {
            do {
                outcomes[name] = Self.outcome(of: try invoke(["kill", name]), name: name)
            } catch {
                outcomes[name] = .failed(String(describing: error))
            }
        }
        return outcomes
    }

    func killConfirmed(name: String) -> KillOutcome {
        do {
            return Self.outcome(of: try invoke(["kill", name, "--force"]), name: name)
        } catch {
            return .failed(String(describing: error))
        }
    }

    static func outcome(of output: String, name: String) -> KillOutcome {
        let lines = output.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if lines.contains("killed session \(name)") { return .killed }
        if lines.contains("cleaned up stale session \(name)") { return .staleSocket }
        return .failed(lines.first ?? "no output")
    }

    private func kill(names: [String]) -> Bool {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return true }
        return (try? invoke(["kill"] + unique + ["--force"])) != nil
    }

    private func invoke(_ arguments: [String], timeout timeoutOverride: TimeInterval? = nil,
                        input: Data? = nil) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["ZMX_DIR"] = socketDirectory
        environment.removeValue(forKey: "ZMX_SESSION")
        environment.removeValue(forKey: "ZMX_SESSION_PREFIX")
        return try runner(.init(executablePath: executablePath, arguments: arguments,
                                environment: environment, timeout: timeoutOverride ?? timeout, input: input))
    }

    private static func run(_ invocation: Invocation) throws -> String {
        let argv = ["ZMX_DIR=" + (invocation.environment["ZMX_DIR"] ?? ""),
                    "ZMX_SESSION=", "ZMX_SESSION_PREFIX=",
                    invocation.executablePath] + invocation.arguments
        let result = LinuxRemoteCommand.run(argv, deadline: invocation.timeout, input: invocation.input)
        if result.status == 124 { throw CommandError.timedOut }
        guard result.status == 0 else {
            throw CommandError.failed(result.status, result.stdout + result.stderr)
        }
        return result.stdout
    }
}
