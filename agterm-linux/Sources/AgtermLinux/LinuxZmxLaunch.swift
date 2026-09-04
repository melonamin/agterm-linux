import Foundation
import agtermCore
#if canImport(Glibc)
import Glibc
#endif

enum LinuxZmxLaunch {
    static func executablePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["AGTERM_ZMX_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL.path
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .standardizedFileURL.resolvingSymlinksInPath()
        let installed = executable.deletingLastPathComponent().appendingPathComponent("zmx").path
        if FileManager.default.isExecutableFile(atPath: installed) { return installed }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/zmx/zmx").path
    }

    static func liveUnavailableReason() -> String? {
        switch configuration(paneIdentity: UUID(), baseEnvironment: [:]) {
        case .success: nil
        case .failure(let rejection): rejection.message
        }
    }

    static func configuration(paneIdentity: UUID, baseEnvironment: [String: String])
        -> Result<ZmxSupport.Configuration, ZmxSupport.Rejection> {
        let environment = ProcessInfo.processInfo.environment
        let resources = GhosttyResourceResolver(
            candidates: ghosttyResourceCandidates(),
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        ).resolve()
        return ZmxSupport.configuration(for: .init(
            zmxExecutablePath: executablePath(environment: environment),
            passwordDatabaseShell: passwordDatabaseLoginShell(),
            resourcesDirectory: resources,
            stateDirectory: linuxStateDirectory().path,
            paneIdentity: paneIdentity,
            baseEnvironment: baseEnvironment,
            inheritedZdotdir: environment["ZDOTDIR"]
        ))
    }

    static func passwordDatabaseLoginShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let value = String(cString: shell)
        return value.isEmpty ? nil : value
    }
}

@MainActor var gRestoreLaunchDecision = RestoreMode.none.launchDecision(liveUnavailableReason: nil)
@MainActor var gZmxClient: LinuxZmxClient?
@MainActor var gZmxRunningNames: Set<String>?
