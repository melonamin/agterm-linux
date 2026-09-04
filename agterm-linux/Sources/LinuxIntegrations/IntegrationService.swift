import Foundation
import agtermCore

public struct IntegrationService: Sendable {
    public let environment: IntegrationEnvironment

    public init(environment: IntegrationEnvironment = .process()) {
        self.environment = environment
    }

    public func status() -> IntegrationSnapshot {
        IntegrationSnapshot(items: [
            cliStatus(), claudeHooksStatus(), codexHooksStatus(), piHooksStatus(),
            opencodePluginStatus(), skillStatus(),
        ])
    }

    public func apply(_ plan: IntegrationPlan) throws -> IntegrationApplyResult {
        guard !plan.operations.isEmpty else {
            if !plan.conflicts.isEmpty { throw IntegrationServiceError.conflicts(plan.conflicts) }
            throw IntegrationServiceError.nothingToDo
        }
        for operation in plan.operations { try IntegrationFilesystem.validate(operation) }

        var results: [IntegrationOperationResult] = []
        for (index, operation) in plan.operations.enumerated() {
            do {
                results.append(try IntegrationFilesystem.apply(operation))
            } catch {
                results.append(operation.failureResult(error.localizedDescription))
                for skipped in plan.operations.dropFirst(index + 1) {
                    results.append(skipped.failureResult("skipped after an earlier operation failed"))
                }
                break
            }
        }
        return IntegrationApplyResult(kind: plan.kind, results: results, conflicts: plan.conflicts)
    }
}

private extension IntegrationOperation {
    var actionAndPath: (String, String) {
        switch self {
        case .validate(let path, _): return ("Verify", path)
        case .replaceDirectory(_, let destination, _, _, _, _, _): return ("Copy", destination)
        case .writeText(let path, _, _, _, _, _, _): return ("Write", path)
        case .copyFile(_, let path, _, _, _, _): return ("Copy", path)
        case .symlink(let path, _, _, _): return ("Link", path)
        }
    }

    func failureResult(_ message: String) -> IntegrationOperationResult {
        let (action, path) = actionAndPath
        return IntegrationOperationResult(action: action, path: path, success: false, message: message)
    }
}
