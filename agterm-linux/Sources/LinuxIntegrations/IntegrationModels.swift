import Foundation

public enum IntegrationKind: String, Codable, CaseIterable, Sendable {
    case commandLineTool = "cli"
    case claudeHooks = "claude-hooks"
    case codexHooks = "codex-hooks"
    case piHooks = "pi-hooks"
    case opencodePlugin = "opencode-plugin"
    case agentSkill = "agent-skill"

    public var title: String {
        switch self {
        case .commandLineTool: return "Command Line Tool"
        case .claudeHooks: return "Claude Code Hooks"
        case .codexHooks: return "Codex Hooks"
        case .piHooks: return "Pi Extension"
        case .opencodePlugin: return "OpenCode Plugin"
        case .agentSkill: return "Agent Skill"
        }
    }
}

public enum IntegrationState: String, Codable, Sendable {
    case notInstalled = "not-installed"
    case installed
    case updateAvailable = "update-available"
    case partial
    case conflict
    case unavailable

    public var label: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        case .updateAvailable: return "Update available"
        case .partial: return "Partial"
        case .conflict: return "Conflict"
        case .unavailable: return "Unavailable"
        }
    }
}

public struct IntegrationItemStatus: Codable, Equatable, Sendable {
    public let kind: IntegrationKind
    public let state: IntegrationState
    public let path: String?
    public let version: String?
    public let detail: String

    public init(kind: IntegrationKind, state: IntegrationState, path: String? = nil,
                version: String? = nil, detail: String) {
        self.kind = kind
        self.state = state
        self.path = path
        self.version = version
        self.detail = detail
    }
}

public struct IntegrationSnapshot: Codable, Equatable, Sendable {
    public let items: [IntegrationItemStatus]

    public init(items: [IntegrationItemStatus]) {
        self.items = items
    }

    public subscript(kind: IntegrationKind) -> IntegrationItemStatus? {
        items.first { $0.kind == kind }
    }
}

public enum IntegrationPlanKind: String, Codable, Sendable {
    case commandLineTool = "cli"
    case hooks
    case skill
}

public struct IntegrationPlanStep: Codable, Equatable, Sendable {
    public let action: String
    public let path: String
    public let detail: String

    public init(action: String, path: String, detail: String) {
        self.action = action
        self.path = path
        self.detail = detail
    }
}

public struct IntegrationPlan: Sendable {
    public let kind: IntegrationPlanKind
    public let steps: [IntegrationPlanStep]
    public let warnings: [String]
    public let conflicts: [String]
    let operations: [IntegrationOperation]

    init(kind: IntegrationPlanKind, steps: [IntegrationPlanStep], warnings: [String] = [],
         conflicts: [String] = [], operations: [IntegrationOperation]) {
        self.kind = kind
        self.steps = steps
        self.warnings = warnings
        self.conflicts = conflicts
        self.operations = operations
    }

    /// Safe operations remain applicable even when another independently-planned target is protected.
    /// The conflicts are carried into the apply result so callers can report a partial update.
    public var canApply: Bool { !operations.isEmpty }

    public var summary: String {
        var lines = steps.map { "\($0.action): \($0.path)\n  \($0.detail)" }
        if !warnings.isEmpty { lines += warnings.map { "Warning: \($0)" } }
        if !conflicts.isEmpty { lines += conflicts.map { "Conflict: \($0)" } }
        return lines.isEmpty ? "No changes are needed." : lines.joined(separator: "\n")
    }
}

public struct IntegrationOperationResult: Codable, Equatable, Sendable {
    public let action: String
    public let path: String
    public let success: Bool
    public let message: String

    public init(action: String, path: String, success: Bool, message: String) {
        self.action = action
        self.path = path
        self.success = success
        self.message = message
    }
}

public struct IntegrationApplyResult: Codable, Equatable, Sendable {
    public let kind: IntegrationPlanKind
    public let results: [IntegrationOperationResult]
    public let conflicts: [String]

    public init(kind: IntegrationPlanKind, results: [IntegrationOperationResult], conflicts: [String] = []) {
        self.kind = kind
        self.results = results
        self.conflicts = conflicts
    }

    public var succeeded: Bool {
        conflicts.isEmpty && !results.isEmpty && results.allSatisfy(\.success)
    }
}

public enum IntegrationServiceError: Error, CustomStringConvertible, LocalizedError {
    case conflicts([String])
    case nothingToDo
    case stalePlan(String)
    case rollbackFailed(destination: String, backup: String, detail: String)
    case invalidResource(String)

    public var description: String {
        switch self {
        case .conflicts(let conflicts): return conflicts.joined(separator: "\n")
        case .nothingToDo: return "no integration changes are needed"
        case .stalePlan(let path): return "integration state changed since preview: \(path)"
        case .rollbackFailed(let destination, let backup, let detail):
            return "could not restore \(destination); the prior installation was preserved at \(backup) (\(detail))"
        case .invalidResource(let detail): return detail
        }
    }

    public var errorDescription: String? { description }
}

enum IntegrationOperation: Sendable {
    case validate(path: String, expected: FileFingerprint)
    case replaceDirectory(source: String, destination: String, displayPath: String,
                          expectedSource: FileFingerprint, expectedDestination: FileFingerprint,
                          expectedDisplayPath: FileFingerprint, bakedCLI: String?)
    case writeText(path: String, target: String, contents: String, backup: Bool,
                   expectedPath: FileFingerprint, expectedTarget: FileFingerprint,
                   expectedBackup: FileFingerprint?)
    case copyFile(source: String, path: String, target: String,
                  expectedSource: FileFingerprint, expectedPath: FileFingerprint,
                  expectedTarget: FileFingerprint)
    case symlink(path: String, target: String, expectedPath: FileFingerprint,
                 expectedTarget: FileFingerprint)
}

struct FileFingerprint: Equatable, Sendable {
    let value: String
}
