import Foundation
import agtermCore
#if canImport(Glibc)
import Glibc
#endif

struct OpenCodeDetection {
    var version: AgentHooksInstall.OpenCode.Version?
    let configurationDirectory: URL?
}

public extension IntegrationService {
    var openCodeConfigurationDirectory: URL? { resolveOpenCode().configurationDirectory }

    func detectedOpenCodeVersion() -> AgentHooksInstall.OpenCode.Version? { resolveOpenCode().version }

    var needsOpenCodeVersionChoice: Bool {
        guard !skipOpenCode else { return false }
        let detection = resolveOpenCode()
        guard detection.version == nil else { return false }
        let legacy = environment.homeDirectory.appendingPathComponent(".config/opencode")
        return [legacy, detection.configurationDirectory].compactMap { $0 }
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}

extension IntegrationService {
    func resolveOpenCode() -> OpenCodeDetection {
        let legacy = environment.homeDirectory.appendingPathComponent(".config/opencode")
        if openCodeVersion == .v1 { return OpenCodeDetection(version: .v1, configurationDirectory: legacy) }
        let probe = probeOpenCode()
        let fallback = AgentHooksInstall.OpenCode.configurationDirectory(
            home: environment.homeDirectory.path, opencodeConfigDirectory: environment.openCodeConfigDirectory,
            xdgConfigHome: environment.xdgConfigHome, workingDirectory: FileManager.default.currentDirectoryPath)
            .map { URL(fileURLWithPath: $0) }
        let v2Directory = probe?.configurationDirectory ?? (probe == nil ? fallback : nil)
        var version = openCodeVersion ?? probe?.version
        if version == nil {
            // An existing managed entrypoint proves its loader when the CLI is unavailable.
            for major in AgentHooksInstall.OpenCode.Version.allCases {
                guard let base = major == .v1 ? legacy : v2Directory else { continue }
                let path = AgentHooksInstall.OpenCode.pluginPath(configurationDirectory: base.path, version: major)
                if let text = try? String(contentsOfFile: path, encoding: .utf8),
                   text.contains(AgentHooksInstall.OpenCode.marker(version: major)) { version = major; break }
            }
        }
        return OpenCodeDetection(version: version, configurationDirectory: version == .v1 ? legacy : v2Directory)
    }

    private func probeOpenCode() -> OpenCodeDetection? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-opencode-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { return nil }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: file) }
        var childEnvironment = environment.probeEnvironment.filter { !$0.key.hasPrefix("AGTERM_") }
        childEnvironment["PATH"] = (environment.pathDirectories + [environment.userBinDirectory])
            .map(\.path).joined(separator: ":") + ":/usr/local/bin:/usr/bin:/bin"
        if let value = environment.openCodeConfigDirectory { childEnvironment["OPENCODE_CONFIG_DIR"] = value }
        if let value = environment.xdgConfigHome { childEnvironment["XDG_CONFIG_HOME"] = value }
        let marker = "agterm-opencode-\(UUID().uuidString)"
        // The POSIX hop reads exported values even when the login shell is fish.
        let command = "/usr/bin/printf '\\n\(marker)\\n%s\\000%s\\000%s\\000%s\\000%s\\000' "
            + "\"$HOME\" \"$PWD\" \"${OPENCODE_CONFIG_DIR+x}\" \"${OPENCODE_CONFIG_DIR-}\" \"${XDG_CONFIG_HOME-}\"; "
            + "exec /usr/bin/env opencode --version"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: childEnvironment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh")
        process.arguments = ["-ilc", "exec /bin/sh -c " + CommandRestore.shellQuotedLine([command])]
        process.environment = childEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return nil }
        let timedOut = ended.wait(timeout: .now() + 3) == .timedOut
        if timedOut {
            process.terminate()
            if ended.wait(timeout: .now() + 0.25) == .timedOut { _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        guard let input = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? input.close() }
        guard let data = try? input.read(upToCount: 65_536) else { return nil }
        let output = String(decoding: data, as: UTF8.self)
        guard let boundary = output.range(of: "\n\(marker)\n") else { return nil }
        let fields = output[boundary.upperBound...].split(separator: "\0", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 6 else { return nil }
        let path = AgentHooksInstall.OpenCode.configurationDirectory(
            home: fields[0], opencodeConfigDirectory: fields[2].isEmpty ? nil : fields[3],
            xdgConfigHome: fields[4], workingDirectory: fields[1])
        return OpenCodeDetection(
            version: !timedOut && process.terminationStatus == 0 ? AgentHooksInstall.OpenCode.Version(versionOutput: fields[5]) : nil,
            configurationDirectory: path.map { URL(fileURLWithPath: $0) })
    }
}
