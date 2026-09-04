import ArgumentParser
import Foundation
import LinuxIntegrations

struct Integration: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect or install local agterm integrations (no running app required).",
        subcommands: [Status.self, Install.self]
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show CLI, hooks, and skill status.")

        @Flag(name: .long, help: "Print a stable JSON status object.")
        var json = false

        @Option(name: .long, help: "Ignored compatibility option; integrations do not use the control socket.")
        var socket: String?

        func run() throws {
            let snapshot = IntegrationService().status()
            if json {
                try printJSON(snapshot)
                return
            }
            for item in snapshot.items {
                let path = item.path.map { " (\($0))" } ?? ""
                print("\(item.kind.title): \(item.state.label)\(path)")
                print("  \(item.detail)")
            }
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install or update hooks or the bundled agent skill."
        )

        @Argument(help: "Integration to install: hooks or skill.")
        var integration: String

        @Flag(name: .long, help: "Print the exact plan without changing files.")
        var dryRun = false

        @Flag(name: .long, help: "Print the plan or result as JSON.")
        var json = false

        @Option(name: .long, help: "Ignored compatibility option; integrations do not use the control socket.")
        var socket: String?

        func validate() throws {
            guard ["hooks", "skill"].contains(integration) else {
                throw ValidationError("integration must be hooks or skill")
            }
        }

        func run() throws {
            let service = IntegrationService()
            let plan = try integration == "hooks" ? service.planHooks() : service.planSkill()
            if dryRun {
                if json { try printJSON(PlanPreview(plan)) } else { print(plan.summary) }
                if !plan.conflicts.isEmpty { throw ExitCode(rawValue: 2) }
                return
            }
            if !plan.canApply {
                if !plan.conflicts.isEmpty {
                    if json { try printJSON(PlanPreview(plan)) } else { writeError(plan.summary) }
                    throw ExitCode(rawValue: 2)
                }
                if json { try printJSON(PlanPreview(plan)) } else { print("No changes are needed.") }
                return
            }
            let result = try service.apply(plan)
            if json {
                try printJSON(result)
            } else {
                for operation in result.results {
                    print("\(operation.success ? "OK" : "FAILED") \(operation.action): \(operation.path)")
                    print("  \(operation.message)")
                }
                for conflict in result.conflicts { print("SKIPPED conflict: \(conflict)") }
            }
            if !result.results.allSatisfy(\.success) { throw ExitCode(rawValue: 4) }
            if !result.conflicts.isEmpty { throw ExitCode(rawValue: 2) }
        }
    }
}

private struct PlanPreview: Codable {
    let kind: IntegrationPlanKind
    let steps: [IntegrationPlanStep]
    let warnings: [String]
    let conflicts: [String]
    let canApply: Bool

    init(_ plan: IntegrationPlan) {
        kind = plan.kind
        steps = plan.steps
        warnings = plan.warnings
        conflicts = plan.conflicts
        canApply = plan.canApply
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard let text = String(data: data, encoding: .utf8) else { return }
    print(text)
}

private func writeError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}
