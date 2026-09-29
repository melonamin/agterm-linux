import Foundation
import agtermCore

extension IntegrationService {
    func launcherOwnershipContents(launcher: URL, target: URL) -> String {
        "agterm-cli-launcher-v1\n\(launcher.standardizedFileURL.path)\n\(target.standardizedFileURL.path)\n"
    }

    func launcherOwnershipMatches(launcher: URL, target: URL) -> Bool {
        guard let contents = try? String(contentsOf: environment.launcherOwnershipFile, encoding: .utf8)
        else { return false }
        return contents == launcherOwnershipContents(launcher: launcher, target: target)
    }

    /// The durable CLI path written into installed lifecycle wrappers.
    /// Native and extracted builds can use their bundled sibling. AppImage/Flatpak executable paths are
    /// ephemeral or sandbox-local, so those builds may install hooks only when a separate persistent CLI
    /// is already available on PATH, in a known package location, or through an existing owned launcher.
    func hooksCommandLineTool() -> URL? {
        if environment.portableLauncherAllowed, let bundled = environment.bundledCLI() { return bundled }
        if let cli = environment.pathCLI() {
            if let bundled = environment.bundledCLI(),
               cli.resolvingSymlinksInPath() == bundled.resolvingSymlinksInPath() {
                return nil
            }
            return cli
        }
        if let cli = environment.packageCLI() { return cli }
        let launcher = environment.userBinDirectory.appendingPathComponent("agtermctl")
        guard FileManager.default.isExecutableFile(atPath: launcher.path), ownedLauncher(launcher) else {
            return nil
        }
        return launcher
    }
}

public extension IntegrationService {
    func planCommandLineTool() throws -> IntegrationPlan {
        let status = cliStatus()
        let launcher = environment.userBinDirectory.appendingPathComponent("agtermctl")
        if status.state == .installed, status.path != launcher.path {
            return emptyPlan(.commandLineTool)
        }
        guard environment.portableLauncherAllowed else {
            throw IntegrationServiceError.invalidResource(
                "Sandboxed AppImage and Flatpak builds cannot own a persistent host ~/.local/bin launcher."
            )
        }
        guard let tool = environment.bundledCLI() else {
            throw IntegrationServiceError.invalidResource("The bundled agtermctl executable is unavailable.")
        }
        // scripts/install-linux.sh installs the real CLI at this exact path. Replacing that executable
        // with a symlink to itself would destroy it, so an in-place personal install is already complete.
        if tool.standardizedFileURL == launcher.standardizedFileURL {
            return emptyPlan(.commandLineTool)
        }
        if status.state == .installed, launcherOwnershipMatches(launcher: launcher, target: tool) {
            return emptyPlan(.commandLineTool)
        }
        if status.state == .conflict {
            return IntegrationPlan(kind: .commandLineTool, steps: [],
                                   conflicts: ["\(launcher.path) is not an agterm-owned launcher."], operations: [])
        }
        let ownership = environment.launcherOwnershipFile
        let ownershipFingerprint = IntegrationFilesystem.fingerprint(ownership)
        let managedOwnership = ownershipFingerprint.value.hasPrefix("file:")
            && ((try? String(contentsOf: ownership, encoding: .utf8))?
                .hasPrefix("agterm-cli-launcher-v1\n") == true)
        if ownershipFingerprint.value != "missing", !managedOwnership {
            return IntegrationPlan(
                kind: .commandLineTool, steps: [],
                conflicts: ["\(ownership.path) is not an agterm-owned launcher record."], operations: [])
        }
        let link = IntegrationOperation.symlink(
            path: launcher.path,
            target: tool.path,
            expectedPath: IntegrationFilesystem.fingerprint(launcher),
            expectedTarget: IntegrationFilesystem.fingerprint(tool)
        )
        let record = IntegrationOperation.writeText(
            path: ownership.path,
            target: ownership.path,
            contents: launcherOwnershipContents(launcher: launcher, target: tool),
            backup: false,
            expectedPath: ownershipFingerprint,
            expectedTarget: ownershipFingerprint,
            expectedBackup: nil
        )
        return IntegrationPlan(kind: .commandLineTool,
                               steps: [
                                   IntegrationPlanStep(action: "Record", path: ownership.path,
                                                       detail: "Record ownership for safe future repairs."),
                                   IntegrationPlanStep(action: "Link", path: launcher.path,
                                                       detail: "Point to \(tool.path)"),
                               ],
                               warnings: ["Ensure ~/.local/bin is present on PATH."],
                               operations: [record, link])
    }

    func planHooks() throws -> IntegrationPlan {
        guard let source = environment.resource(named: "agent-status") else {
            throw IntegrationServiceError.invalidResource("The bundled agent-status scripts are unavailable.")
        }
        guard let hooksCLI = hooksCommandLineTool() else {
            throw IntegrationServiceError.invalidResource(
                "A persistent agtermctl installation is required before lifecycle hooks can be installed."
            )
        }
        var steps: [IntegrationPlanStep] = []
        var warnings: [String] = []
        var conflicts: [String] = []
        var operations: [IntegrationOperation] = []
        let displayDestination = environment.hooksDirectory
        let destination = IntegrationFilesystem.resolvedDirectoryTarget(displayDestination)
        let bakedCLI = hooksCLI.path

        if hookDirectoryIsSafe(source: source, destination: destination) {
            if !IntegrationFilesystem.directoryMatches(source: source, destination: destination,
                                                       bakedCLI: bakedCLI) {
                let exists = FileManager.default.fileExists(atPath: destination.path)
                let action = exists ? "Replace" : "Install"
                operations.append(.replaceDirectory(
                    source: source.path,
                    destination: destination.path,
                    displayPath: displayDestination.path,
                    expectedSource: IntegrationFilesystem.fingerprint(source),
                    expectedDestination: IntegrationFilesystem.fingerprint(destination),
                    expectedDisplayPath: IntegrationFilesystem.fingerprint(displayDestination),
                    bakedCLI: bakedCLI
                ))
                var detail = "Copy the bundled lifecycle scripts from \(source.path)."
                if displayDestination.path != destination.path {
                    detail += " Preserve the symlink and update its target at \(destination.path)."
                }
                steps.append(IntegrationPlanStep(action: action, path: displayDestination.path,
                                                 detail: detail))
                steps.append(IntegrationPlanStep(action: "Configure", path: displayDestination.path,
                                                 detail: "Use the durable agtermctl at \(bakedCLI)."))
            }
        } else {
            conflicts.append("\(displayDestination.path) exists but is not an agterm-managed hooks directory.")
            // Every generated agent and shell entry invokes a script in this directory. They are not
            // independently safe when the scripts cannot be installed, so do not write dangling hook
            // configuration merely because those destination files themselves are unprotected.
            return IntegrationPlan(kind: .hooks, steps: steps, warnings: warnings,
                                   conflicts: conflicts, operations: operations)
        }

        appendClaudePlan(steps: &steps, conflicts: &conflicts, operations: &operations)
        appendShellPlans(steps: &steps, conflicts: &conflicts, operations: &operations)
        appendCodexPlan(steps: &steps, warnings: &warnings, conflicts: &conflicts, operations: &operations)
        try appendPiPlan(source: source, steps: &steps, warnings: &warnings,
                         conflicts: &conflicts, operations: &operations)
        try appendOpenCodePlan(source: source, steps: &steps, warnings: &warnings,
                               conflicts: &conflicts, operations: &operations)

        if operations.contains(where: \.changesFilesystem) {
            // The preview established both assets as dependencies even when the installed hooks directory
            // was already current. Reject the whole transaction if either changes before confirmation.
            operations.insert(.validate(path: hooksCLI.path,
                                        expected: IntegrationFilesystem.fingerprint(hooksCLI)), at: 0)
            operations.insert(.validate(path: source.path,
                                        expected: IntegrationFilesystem.fingerprint(source)), at: 0)
        }

        return IntegrationPlan(kind: .hooks, steps: steps, warnings: warnings,
                               conflicts: conflicts, operations: operations)
    }

    func planSkill() throws -> IntegrationPlan {
        guard let source = environment.resource(named: "agent-skill") else {
            throw IntegrationServiceError.invalidResource("The bundled agent skill is unavailable.")
        }
        let fm = FileManager.default
        let home = environment.homeDirectory.path
        let targets = SkillInstall.installTargets(
            home: home,
            claudeExists: fm.fileExists(atPath: home + "/.claude"),
            codexExists: fm.fileExists(atPath: home + "/.codex")
        )
        var steps: [IntegrationPlanStep] = []
        var conflicts: [String] = []
        var operations: [IntegrationOperation] = []
        var currentTargetValidations: [IntegrationOperation] = []
        var plannedDestinations: Set<String> = []
        for target in targets {
            let displayDestination = URL(fileURLWithPath: target.skillDirectory, isDirectory: true)
            let destination = IntegrationFilesystem.resolvedDirectoryTarget(displayDestination)
            if IntegrationFilesystem.isDanglingSymbolicLink(displayDestination) {
                conflicts.append(
                    "\(target.agent): \(displayDestination.path) is a dangling user-owned symlink."
                )
                continue
            }
            let exists = fm.fileExists(atPath: destination.path)
            let skill = try? String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8)
            guard SkillInstall.mayOverwrite(directoryExists: exists, existingSKILL: skill) else {
                conflicts.append("\(target.agent): \(displayDestination.path) contains an unrelated skill.")
                continue
            }
            if exists, IntegrationFilesystem.directoryMatches(source: source, destination: destination,
                                                              bakedCLI: nil) {
                currentTargetValidations.append(.validate(
                    path: displayDestination.path,
                    expected: IntegrationFilesystem.fingerprint(displayDestination)
                ))
                if displayDestination.standardizedFileURL != destination.standardizedFileURL {
                    currentTargetValidations.append(.validate(
                        path: destination.path,
                        expected: IntegrationFilesystem.fingerprint(destination)
                    ))
                }
                continue
            }
            guard plannedDestinations.insert(destination.standardizedFileURL.path).inserted else {
                let validationPath = IntegrationFilesystem.validationAnchor(for: displayDestination)
                operations.append(.validate(
                    path: validationPath.path,
                    expected: IntegrationFilesystem.fingerprint(validationPath)
                ))
                steps.append(IntegrationPlanStep(
                    action: "Share", path: displayDestination.path,
                    detail: "Uses the same resolved managed skill directory as another detected agent."
                ))
                continue
            }
            operations.append(.replaceDirectory(
                source: source.path,
                destination: destination.path,
                displayPath: displayDestination.path,
                expectedSource: IntegrationFilesystem.fingerprint(source),
                expectedDestination: IntegrationFilesystem.fingerprint(destination),
                expectedDisplayPath: IntegrationFilesystem.fingerprint(displayDestination),
                bakedCLI: nil
            ))
            var detail = "Install the bundled skill for \(target.agent) from \(source.path)."
            if displayDestination.path != destination.path {
                detail += " Preserve the symlink and update its target at \(destination.path)."
            }
            steps.append(IntegrationPlanStep(action: exists ? "Update" : "Install",
                                             path: displayDestination.path, detail: detail))
        }
        if operations.contains(where: \.changesFilesystem) {
            operations.insert(contentsOf: currentTargetValidations, at: 0)
        }
        return IntegrationPlan(kind: .skill, steps: steps, conflicts: conflicts, operations: operations)
    }
}

private extension IntegrationOperation {
    var changesFilesystem: Bool {
        if case .validate = self { return false }
        return true
    }
}

private extension IntegrationService {
    func emptyPlan(_ kind: IntegrationPlanKind) -> IntegrationPlan {
        IntegrationPlan(kind: kind, steps: [], operations: [])
    }

    func hookDirectoryIsSafe(source: URL, destination: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else { return true }
        return IntegrationFilesystem.hookDirectoryIsManaged(source: source, destination: destination)
    }

    func appendClaudePlan(steps: inout [IntegrationPlanStep], conflicts: inout [String],
                          operations: inout [IntegrationOperation]) {
        let path = environment.homeDirectory.appendingPathComponent(".claude/settings.json")
        do {
            let existing = try IntegrationFilesystem.read(path)
            let merged = try AgentHooksInstall.mergeClaudeSettings(existing: existing,
                                                                    scriptDir: environment.hooksDirectory.path)
            guard merged.changed else { return }
            let target = IntegrationFilesystem.resolvedWriteTarget(path)
            operations.append(.writeText(
                path: path.path, target: target.path, contents: merged.json, backup: existing != nil,
                expectedPath: IntegrationFilesystem.fingerprint(path),
                expectedTarget: IntegrationFilesystem.fingerprint(target),
                expectedBackup: existing == nil ? nil : backupFingerprint(for: target)
            ))
            if existing != nil {
                steps.append(IntegrationPlanStep(action: "Backup",
                                                 path: AgentHooksInstall.backupPath(for: target.path),
                                                 detail: "Save the existing Claude Code settings."))
            }
            steps.append(IntegrationPlanStep(action: existing == nil ? "Create" : "Merge", path: path.path,
                                             detail: "Configure Claude Code lifecycle hooks safely."))
        } catch AgentHooksInstall.MergeError.malformedExistingSettings {
            conflicts.append("\(path.path) is invalid JSON and will not be changed.")
        } catch {
            conflicts.append("\(path.path) could not be read and will not be changed.")
        }
    }

    func appendShellPlans(steps: inout [IntegrationPlanStep], conflicts: inout [String],
                          operations: inout [IntegrationOperation]) {
        let fm = FileManager.default
        typealias ShellEntry = (path: URL, existing: String?)
        typealias ShellGroup = (target: URL, contents: String, entries: [ShellEntry])
        var groups: [String: ShellGroup] = [:]
        var groupOrder: [String] = []
        var incompatibleTargets: Set<String> = []
        for relative in [".zshrc", ".bashrc", ".config/fish/config.fish"] {
            let path = environment.homeDirectory.appendingPathComponent(relative)
            if relative.hasSuffix("config.fish"),
               !fm.fileExists(atPath: path.deletingLastPathComponent().path) { continue }
            do {
                let existing = try IntegrationFilesystem.read(path)
                let script = relative.hasSuffix("config.fish")
                    ? AgentHooksInstall.fishIntegrationRelativePath : AgentHooksInstall.integrationRelativePath
                let state = IntegrationManagedMarkers.shellRCState(
                    existing: existing ?? "", scriptDir: environment.hooksDirectory.path,
                    scriptName: script
                )
                if state == .malformed {
                    conflicts.append("\(path.path) contains an incomplete agterm-managed block.")
                    continue
                }
                let merged = AgentHooksInstall.appendShellRC(existing: existing ?? "",
                                                             scriptDir: environment.hooksDirectory.path,
                                                             scriptName: script)
                guard merged.changed else { continue }
                let target = IntegrationFilesystem.resolvedWriteTarget(path)
                let targetKey = target.standardizedFileURL.path
                if var group = groups[targetKey] {
                    if group.contents == merged.contents {
                        group.entries.append((path, existing))
                        groups[targetKey] = group
                    } else {
                        incompatibleTargets.insert(targetKey)
                        conflicts.append(
                            "\(path.path) resolves to \(target.path), which also serves a shell requiring different syntax."
                        )
                    }
                    continue
                }
                groups[targetKey] = (target, merged.contents, [(path, existing)])
                groupOrder.append(targetKey)
            } catch {
                conflicts.append("\(path.path) could not be read and will not be changed.")
            }
        }

        for key in groupOrder where !incompatibleTargets.contains(key) {
            guard let group = groups[key], let primary = group.entries.first else { continue }
            operations.append(.writeText(
                path: primary.path.path, target: group.target.path, contents: group.contents, backup: false,
                expectedPath: IntegrationFilesystem.fingerprint(primary.path),
                expectedTarget: IntegrationFilesystem.fingerprint(group.target),
                expectedBackup: nil
            ))
            steps.append(IntegrationPlanStep(
                action: primary.existing == nil ? "Create" : "Append", path: primary.path.path,
                detail: "Load agterm shell integration in new terminals."
            ))
            for alias in group.entries.dropFirst() {
                operations.append(.validate(
                    path: alias.path.path, expected: IntegrationFilesystem.fingerprint(alias.path)
                ))
                steps.append(IntegrationPlanStep(
                    action: "Share", path: alias.path.path,
                    detail: "Uses the same resolved shell startup file as another detected shell."
                ))
            }
        }
    }

    func appendCodexPlan(steps: inout [IntegrationPlanStep], warnings: inout [String],
                         conflicts: inout [String], operations: inout [IntegrationOperation]) {
        let base = environment.homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else {
            warnings.append("No ~/.codex directory was detected; Codex hooks will be skipped.")
            return
        }
        let path = base.appendingPathComponent("config.toml")
        do {
            let existing = try IntegrationFilesystem.read(path) ?? ""
            switch AgentHooksInstall.mergeCodexConfig(existing: existing,
                                                       scriptDir: environment.hooksDirectory.path) {
            case .merged(let contents):
                let target = IntegrationFilesystem.resolvedWriteTarget(path)
                operations.append(.writeText(
                    path: path.path, target: target.path, contents: contents, backup: !existing.isEmpty,
                    expectedPath: IntegrationFilesystem.fingerprint(path),
                    expectedTarget: IntegrationFilesystem.fingerprint(target),
                    expectedBackup: existing.isEmpty ? nil : backupFingerprint(for: target)
                ))
                if !existing.isEmpty {
                    steps.append(IntegrationPlanStep(action: "Backup",
                                                     path: AgentHooksInstall.backupPath(for: target.path),
                                                     detail: "Save the existing Codex configuration."))
                }
                steps.append(IntegrationPlanStep(action: existing.isEmpty ? "Create" : "Merge", path: path.path,
                                                 detail: "Configure Codex lifecycle hooks safely."))
                warnings.append("Review new or updated Codex hooks with /hooks before trusting them.")
            case .unchanged:
                if !IntegrationManagedMarkers.codexBlockIsCurrent(
                    existing: existing, scriptDir: environment.hooksDirectory.path
                ) {
                    conflicts.append("\(path.path) contains an unrecognized agterm marker block.")
                }
            case .hooksExist:
                conflicts.append("\(path.path) already defines custom Codex hooks.")
            case .unparseable:
                conflicts.append("\(path.path) is invalid TOML and will not be changed.")
            }
        } catch {
            conflicts.append("\(path.path) could not be read and will not be changed.")
        }
    }

    func appendPiPlan(source package: URL, steps: inout [IntegrationPlanStep],
                      warnings: inout [String], conflicts: inout [String],
                      operations: inout [IntegrationOperation]) throws {
        let home = environment.homeDirectory.path
        let base = environment.homeDirectory.appendingPathComponent(".pi/agent", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) else {
            warnings.append("No ~/.pi/agent directory was detected; the Pi extension will be skipped.")
            return
        }
        guard isDirectory.boolValue else {
            conflicts.append("\(base.path) exists but is not a directory.")
            return
        }
        let source = package.appendingPathComponent(AgentHooksInstall.piExtensionRelativePath)
        guard let bundled = try? String(contentsOf: source, encoding: .utf8),
              bundled.contains(AgentHooksInstall.piExtensionMarker) else {
            throw IntegrationServiceError.invalidResource(
                "The bundled Pi extension is missing or invalid: \(source.path)"
            )
        }
        let path = URL(fileURLWithPath: AgentHooksInstall.piExtensionPath(home: home))
        let pathFingerprint = IntegrationFilesystem.fingerprint(path)
        let exists = pathFingerprint.value != "missing"
        let existing: String?
        do {
            existing = try IntegrationFilesystem.read(path)
        } catch {
            conflicts.append("\(path.path) could not be read and will not be changed.")
            return
        }
        guard AgentHooksInstall.mayOverwritePiExtension(
            fileExists: exists, existingContents: existing
        ) else {
            conflicts.append("\(path.path) is user-owned and will not be changed.")
            return
        }
        guard existing != bundled else { return }
        let target = IntegrationFilesystem.resolvedWriteTarget(path)
        operations.append(.copyFile(
            source: source.path,
            path: path.path,
            target: target.path,
            expectedSource: IntegrationFilesystem.fingerprint(source),
            expectedPath: pathFingerprint,
            expectedTarget: IntegrationFilesystem.fingerprint(target)
        ))
        steps.append(IntegrationPlanStep(
            action: exists ? "Update" : "Install",
            path: path.path,
            detail: "Copy the managed Pi lifecycle extension without a backup."
        ))
        warnings.append("Restart Pi or run /reload after installing or updating its extension.")
    }

    func appendOpenCodePlan(
        source package: URL, steps: inout [IntegrationPlanStep],
        warnings: inout [String], conflicts: inout [String],
        operations: inout [IntegrationOperation]
    ) throws {
        let home = environment.homeDirectory.path
        let base = environment.homeDirectory.appendingPathComponent(
            ".config/opencode", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory) else {
            warnings.append(
                "No ~/.config/opencode directory was detected; the OpenCode plugin will be skipped.")
            return
        }
        guard isDirectory.boolValue else {
            conflicts.append("\(base.path) exists but is not a directory.")
            return
        }
        let source = package.appendingPathComponent(AgentHooksInstall.opencodePluginRelativePath)
        guard let bundled = try? String(contentsOf: source, encoding: .utf8),
              bundled.contains(AgentHooksInstall.opencodePluginMarker) else {
            throw IntegrationServiceError.invalidResource(
                "The bundled OpenCode plugin is missing or invalid: \(source.path)"
            )
        }
        let path = URL(fileURLWithPath: AgentHooksInstall.opencodePluginPath(home: home))
        let pathFingerprint = IntegrationFilesystem.fingerprint(path)
        let exists = pathFingerprint.value != "missing"
        let existing: String?
        do {
            existing = try IntegrationFilesystem.read(path)
        } catch {
            conflicts.append("\(path.path) could not be read and will not be changed.")
            return
        }
        guard AgentHooksInstall.mayOverwriteOpenCodePlugin(
            fileExists: exists, existingContents: existing
        ) else {
            conflicts.append("\(path.path) is user-owned and will not be changed.")
            return
        }
        guard existing != bundled else { return }
        let target = IntegrationFilesystem.resolvedWriteTarget(path)
        operations.append(.copyFile(
            source: source.path,
            path: path.path,
            target: target.path,
            expectedSource: IntegrationFilesystem.fingerprint(source),
            expectedPath: pathFingerprint,
            expectedTarget: IntegrationFilesystem.fingerprint(target)
        ))
        steps.append(IntegrationPlanStep(
            action: exists ? "Update" : "Install",
            path: path.path,
            detail: "Copy the managed OpenCode lifecycle plugin without a backup."
        ))
        warnings.append("Restart OpenCode after installing or updating its lifecycle plugin.")
    }

    func backupFingerprint(for target: URL) -> FileFingerprint {
        IntegrationFilesystem.fingerprint(
            URL(fileURLWithPath: AgentHooksInstall.backupPath(for: target.path)))
    }
}
