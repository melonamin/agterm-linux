import Foundation
import agtermCore

enum ShellRCManagedState: Equatable, Sendable {
    case absent
    case installed
    case malformed
}

/// Linux installer safeguards layered around the upstream hook merge helpers.
///
/// The shared merger intentionally treats any begin marker as already managed. The Linux settings UI
/// needs a stricter preflight so it can distinguish a complete block from truncated or foreign content
/// before offering to write user configuration.
enum IntegrationManagedMarkers {
    static func shellRCState(
        existing: String,
        scriptDir: String,
        scriptName: String = AgentHooksInstall.integrationRelativePath
    ) -> ShellRCManagedState {
        let lines = existing.components(separatedBy: "\n")
        let expected = [
            AgentHooksInstall.rcMarkerBegin,
            "source \(AgentHooksInstall.shellQuote(scriptDir + "/" + scriptName))",
            AgentHooksInstall.rcMarkerEnd,
        ]
        if lines.count >= expected.count {
            for index in 0...(lines.count - expected.count)
            where Array(lines[index..<(index + expected.count)]) == expected {
                return .installed
            }
        }
        let carriesManagedText = existing.contains(AgentHooksInstall.rcMarkerBegin)
            || existing.contains(AgentHooksInstall.rcMarkerEnd)
            || existing.contains(expected[1])
        return carriesManagedText ? .malformed : .absent
    }

    static func codexBlockIsCurrent(existing: String, scriptDir: String) -> Bool {
        let expectedWrapper = AgentHooksInstall.shellQuote(
            scriptDir + "/" + AgentHooksInstall.codexWrapperName)
        let lines = existing.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == AgentHooksInstall.rcMarkerBegin
        }), let end = lines.indices.dropFirst(begin + 1).first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == AgentHooksInstall.rcMarkerEnd
        }) else { return false }
        let body = lines[(begin + 1)..<end].joined(separator: "\n")
        guard body.contains(expectedWrapper) else { return false }
        return AgentHooksInstall.mergeCodexConfig(
            existing: existing,
            scriptDir: scriptDir
        ) == .unchanged
    }
}
