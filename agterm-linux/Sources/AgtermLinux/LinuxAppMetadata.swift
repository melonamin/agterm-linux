import Foundation
import agtermCore

enum LinuxAppMetadata {
    /// Linux application identity used by GApplication, desktop integration, notifications, and packaging.
    /// Keep this owned by the Linux fork; the upstream macOS bundle retains its own identifier.
    static let applicationID = "io.github.melonamin.agterm"

    static let version: String = {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["AGTERM_VERSION"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !value.isEmpty {
            return value
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let installed = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/agterm/VERSION")
        if let value = try? String(contentsOf: installed, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return "dev"
    }()

    static let commit: String? = {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["AGTERM_COMMIT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty, value != "unknown" {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "AGTermGitCommit") as? String,
           !value.isEmpty, value != "unknown" {
            return value
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let installed = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/agterm/COMMIT")
        if let value = try? String(contentsOf: installed, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value != "unknown" {
            return value
        }
        return nil
    }()

    static let identity = AppIdentity(version: version, commit: commit)
}
