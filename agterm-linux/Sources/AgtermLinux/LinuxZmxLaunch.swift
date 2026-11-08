import Foundation
import agtermCore
#if canImport(Glibc)
import Glibc
#endif

enum LinuxZmxLaunch {
    /// Latched once for the app run: reloading config cannot rename a running daemon's shell.
    static let liveCommandShell: String? = {
        let settings = linuxSettingsStore().load(), env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = ConfigPaths.configDirectory(setting: settings.configDirectory, stateDir: env["AGTERM_STATE_DIR"], home: home)
        var paths: [String] = []
        if settings.inheritGlobalGhosttyConfig == true {
            let configHome = env["XDG_CONFIG_HOME"] ?? home.appendingPathComponent(".config").path
            let folder = URL(fileURLWithPath: configHome).appendingPathComponent("ghostty")
            paths += [folder.appendingPathComponent("config").path, folder.appendingPathComponent("config.ghostty").path]
        }
        paths.append(ConfigPaths.ghosttyConfigPath(configDirectory: directory).path)
        let pairs = GhosttyConfigText.keyValues(loading: paths, home: home.path) {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }
        guard case .value(let value) = GhosttyConfigText.lastSetting(of: "command", in: pairs, parse: { $0 }) else { return nil }
        return ZmxSupport.commandShell(fromCommand: value)
    }()

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

    static func configuration(paneIdentity: UUID, baseEnvironment: [String: String],
                              lead: ZmxLeadAttachment? = nil)
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
            inheritedZdotdir: environment["ZDOTDIR"], lead: lead, commandShell: liveCommandShell
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
