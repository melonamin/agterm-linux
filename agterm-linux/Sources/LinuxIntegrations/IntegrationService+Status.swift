import Foundation
import agtermCore

extension IntegrationService {
    func cliStatus() -> IntegrationItemStatus {
        let launcher = environment.userBinDirectory.appendingPathComponent("agtermctl")
        if let cli = environment.pathCLI() {
            let packaged = isKnownPackageTool(cli)
            if packaged {
                return IntegrationItemStatus(
                    kind: .commandLineTool,
                    state: .installed,
                    path: cli.path,
                    version: environment.version(for: cli),
                    detail: "Installed by the system package; update it with the package manager."
                )
            }
            if let bundled = environment.bundledCLI(),
               cli.resolvingSymlinksInPath() == bundled.resolvingSymlinksInPath() {
                guard environment.portableLauncherAllowed else { return sandboxedCLIStatus() }
                if cli.standardizedFileURL == launcher.standardizedFileURL {
                    if bundled.standardizedFileURL == launcher.standardizedFileURL {
                        return IntegrationItemStatus(
                            kind: .commandLineTool,
                            state: .installed,
                            path: cli.path,
                            version: environment.version(for: cli),
                            detail: "Installed directly in ~/.local/bin by the personal installer."
                        )
                    }
                    return ownedLauncherStatus(cli, visibleOnPath: true)
                }
                return IntegrationItemStatus(
                    kind: .commandLineTool,
                    state: .installed,
                    path: cli.path,
                    version: environment.version(for: cli),
                    detail: "Installed with this agterm build."
                )
            }
            if cli.standardizedFileURL == launcher.standardizedFileURL, !ownedLauncher(cli) {
                return IntegrationItemStatus(kind: .commandLineTool, state: .conflict,
                                             path: launcher.path,
                                             detail: "An unrelated launcher already occupies ~/.local/bin/agtermctl.")
            }
            if ownedLauncher(cli) {
                return ownedLauncherStatus(cli, visibleOnPath: true)
            }
            return IntegrationItemStatus(
                kind: .commandLineTool,
                state: .installed,
                path: cli.path,
                version: environment.version(for: cli),
                detail: "Available on PATH as \(cli.resolvingSymlinksInPath().path)."
            )
        }

        if let cli = environment.packageCLI() {
            return IntegrationItemStatus(
                kind: .commandLineTool,
                state: .installed,
                path: cli.path,
                version: environment.version(for: cli),
                detail: "A system-package installation was detected outside the current PATH; update it with the package manager."
            )
        }

        if IntegrationFilesystem.fingerprint(launcher).value != "missing" {
            let launcherType = (try? FileManager.default.attributesOfItem(atPath: launcher.path)[.type])
                as? FileAttributeType
            if launcherType == .typeRegular, let bundled = environment.bundledCLI(),
               bundled.standardizedFileURL == launcher.standardizedFileURL {
                return IntegrationItemStatus(
                    kind: .commandLineTool,
                    state: .installed,
                    path: launcher.path,
                    version: environment.version(for: launcher),
                    detail: "Installed directly in ~/.local/bin by the personal installer; ~/.local/bin is not on PATH."
                )
            }
            guard ownedLauncher(launcher) else {
                return IntegrationItemStatus(kind: .commandLineTool, state: .conflict,
                                             path: launcher.path,
                                             detail: "An unrelated file already occupies the launcher path.")
            }
            return ownedLauncherStatus(launcher, visibleOnPath: false)
        }

        guard environment.portableLauncherAllowed else {
            return sandboxedCLIStatus()
        }

        guard let bundled = environment.bundledCLI() else {
            return IntegrationItemStatus(kind: .commandLineTool, state: .unavailable,
                                         detail: "This build does not contain a bundled agtermctl executable.")
        }
        return IntegrationItemStatus(kind: .commandLineTool, state: .notInstalled,
                                     path: launcher.path, version: environment.version(for: bundled),
                                     detail: "A portable-build launcher can be installed in ~/.local/bin.")
    }

    func claudeHooksStatus() -> IntegrationItemStatus {
        combinedHookStatus(configuration: claudeConfigurationStatus(), assets: hookAssetsStatus(),
                           shell: shellRCStatus())
    }

    func codexHooksStatus() -> IntegrationItemStatus {
        let configuration = codexConfigurationStatus()
        guard configuration.state != .unavailable else { return configuration }
        return combinedHookStatus(configuration: configuration, assets: hookAssetsStatus(),
                                  shell: shellRCStatus())
    }

    func piHooksStatus() -> IntegrationItemStatus {
        let home = environment.homeDirectory.path
        let base = environment.homeDirectory.appendingPathComponent(".pi/agent", isDirectory: true)
        let path = URL(fileURLWithPath: AgentHooksInstall.piExtensionPath(home: home))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return IntegrationItemStatus(
                kind: .piHooks, state: .unavailable, path: path.path,
                detail: "No ~/.pi/agent directory was detected."
            )
        }
        guard let package = environment.resource(named: "agent-status") else {
            return IntegrationItemStatus(kind: .piHooks, state: .unavailable, path: path.path,
                                         detail: "The bundled Pi extension is unavailable.")
        }
        let source = package.appendingPathComponent(AgentHooksInstall.piExtensionRelativePath)
        guard let bundled = try? String(contentsOf: source, encoding: .utf8),
              bundled.contains(AgentHooksInstall.piExtensionMarker) else {
            return IntegrationItemStatus(kind: .piHooks, state: .unavailable, path: path.path,
                                         detail: "The bundled Pi extension is invalid.")
        }
        let exists = IntegrationFilesystem.fingerprint(path).value != "missing"
        guard exists else {
            return IntegrationItemStatus(kind: .piHooks, state: .notInstalled, path: path.path,
                                         detail: "Pi's agterm extension is not installed.")
        }
        let existing: String
        do {
            existing = try IntegrationFilesystem.read(path) ?? ""
        } catch {
            return IntegrationItemStatus(kind: .piHooks, state: .conflict, path: path.path,
                                         detail: "The Pi extension could not be read.")
        }
        guard AgentHooksInstall.mayOverwritePiExtension(
            fileExists: true, existingContents: existing
        ) else {
            return IntegrationItemStatus(kind: .piHooks, state: .conflict, path: path.path,
                                         detail: "A user-owned Pi extension already uses this path.")
        }
        let state: IntegrationState = bundled == existing ? .installed : .updateAvailable
        return IntegrationItemStatus(
            kind: .piHooks, state: state, path: path.path,
            detail: state == .installed
                ? "Pi's agterm extension is installed and current."
                : "Pi's managed agterm extension can be updated."
        )
    }

    func opencodePluginStatus() -> IntegrationItemStatus {
        let home = environment.homeDirectory.path
        let base = environment.homeDirectory.appendingPathComponent(".config/opencode", isDirectory: true)
        let path = URL(fileURLWithPath: AgentHooksInstall.opencodePluginPath(home: home))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return IntegrationItemStatus(
                kind: .opencodePlugin, state: .unavailable, path: path.path,
                detail: "No ~/.config/opencode directory was detected."
            )
        }
        guard let package = environment.resource(named: "agent-status") else {
            return IntegrationItemStatus(
                kind: .opencodePlugin, state: .unavailable, path: path.path,
                detail: "The bundled OpenCode plugin is unavailable."
            )
        }
        let source = package.appendingPathComponent(AgentHooksInstall.opencodePluginRelativePath)
        guard let bundled = try? String(contentsOf: source, encoding: .utf8),
              bundled.contains(AgentHooksInstall.opencodePluginMarker) else {
            return IntegrationItemStatus(
                kind: .opencodePlugin, state: .unavailable, path: path.path,
                detail: "The bundled OpenCode plugin is invalid."
            )
        }
        let exists = IntegrationFilesystem.fingerprint(path).value != "missing"
        guard exists else {
            return IntegrationItemStatus(
                kind: .opencodePlugin, state: .notInstalled, path: path.path,
                detail: "OpenCode's agterm lifecycle plugin is not installed."
            )
        }
        let existing: String
        do {
            existing = try IntegrationFilesystem.read(path) ?? ""
        } catch {
            return IntegrationItemStatus(
                kind: .opencodePlugin, state: .conflict, path: path.path,
                detail: "The OpenCode plugin could not be read."
            )
        }
        guard AgentHooksInstall.mayOverwriteOpenCodePlugin(
            fileExists: true, existingContents: existing
        ) else {
            return IntegrationItemStatus(
                kind: .opencodePlugin, state: .conflict, path: path.path,
                detail: "A user-owned OpenCode plugin already uses this path."
            )
        }
        let state: IntegrationState = bundled == existing ? .installed : .updateAvailable
        return IntegrationItemStatus(
            kind: .opencodePlugin, state: state, path: path.path,
            detail: state == .installed
                ? "OpenCode's agterm lifecycle plugin is installed and current."
                : "OpenCode's managed agterm lifecycle plugin can be updated."
        )
    }

    func skillStatus() -> IntegrationItemStatus {
        let fm = FileManager.default
        guard let source = environment.resource(named: "agent-skill") else {
            return IntegrationItemStatus(kind: .agentSkill, state: .unavailable,
                                         detail: "The bundled skill resource is unavailable.")
        }
        let home = environment.homeDirectory.path
        let targets = SkillInstall.installTargets(
            home: home,
            claudeExists: fm.fileExists(atPath: home + "/.claude"),
            codexExists: fm.fileExists(atPath: home + "/.codex")
        )
        let statuses = targets.map { skillTargetStatus($0, source: source) }
        let states = statuses.map(\.state)
        let state: IntegrationState
        if states.contains(.conflict) {
            state = .conflict
        } else if states.allSatisfy({ $0 == .installed }) {
            state = .installed
        } else if states.allSatisfy({ [.installed, .updateAvailable].contains($0) }) {
            state = .updateAvailable
        } else if states.allSatisfy({ $0 == .notInstalled }) {
            state = .notInstalled
        } else {
            state = .partial
        }
        let paths = statuses.map(\.path)
        let detail = statuses.map { "\($0.agent): \($0.state.label) at \($0.path)." }.joined(separator: " ")
        return IntegrationItemStatus(kind: .agentSkill, state: state,
                                     path: paths.count == 1 ? paths[0] : paths.joined(separator: ", "),
                                     detail: detail)
    }

    func ownedLauncher(_ url: URL) -> Bool {
        guard let target = launcherTarget(url), let bundled = environment.bundledCLI() else { return false }
        if target.resolvingSymlinksInPath() == bundled.resolvingSymlinksInPath() { return true }
        guard ["agtermctl", "agtermctl-linux", "agtermctl.bin"].contains(target.lastPathComponent)
        else { return false }
        if !FileManager.default.fileExists(atPath: target.path) {
            return launcherOwnershipMatches(launcher: url, target: target)
        }
        guard FileManager.default.isExecutableFile(atPath: target.path) else { return false }
        let directory = target.deletingLastPathComponent()
        return ["AgtermLinux", "agterm-linux", "agterm-linux.bin"].contains {
            FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path)
        }
    }

    func ownedLauncherStatus(_ launcher: URL, visibleOnPath: Bool) -> IntegrationItemStatus {
        let target = launcherTarget(launcher)
        let bundled = environment.bundledCLI()
        let targetExists = target.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        let userLauncher = environment.userBinDirectory.appendingPathComponent("agtermctl")
        let ownershipCurrent = !environment.portableLauncherAllowed
            || launcher.standardizedFileURL != userLauncher.standardizedFileURL
            || target.map { launcherOwnershipMatches(launcher: launcher, target: $0) } == true
        let current = targetExists && ownershipCurrent
            && (!environment.portableLauncherAllowed || bundled == nil
                || target?.resolvingSymlinksInPath() == bundled?.resolvingSymlinksInPath())
        return IntegrationItemStatus(
            kind: .commandLineTool,
            state: current ? .installed : .updateAvailable,
            path: launcher.path,
            version: target.flatMap(environment.version(for:)),
            detail: current
                ? (visibleOnPath
                    ? "The agterm-owned launcher is installed and current."
                    : "The agterm-owned launcher is installed, but ~/.local/bin is not on the current PATH.")
                : "The agterm-owned launcher needs an ownership record, is broken, or points to an older portable build."
        )
    }

    func sandboxedCLIStatus() -> IntegrationItemStatus {
        IntegrationItemStatus(
            kind: .commandLineTool,
            state: .unavailable,
            detail: "Sandboxed AppImage and Flatpak paths are not persistent host launchers; use a native package or tar archive for a host CLI."
        )
    }
}

private struct HookComponentStatus {
    let state: IntegrationState
    let detail: String
}

private struct SkillTargetStatus {
    let agent: String
    let path: String
    let state: IntegrationState
}

private extension IntegrationService {
    func skillTargetStatus(_ target: SkillInstall.Target, source: URL) -> SkillTargetStatus {
        let fm = FileManager.default
        let displayDestination = URL(fileURLWithPath: target.skillDirectory, isDirectory: true)
        if IntegrationFilesystem.isDanglingSymbolicLink(displayDestination) {
            return SkillTargetStatus(agent: target.agent, path: displayDestination.path, state: .conflict)
        }
        let destination = IntegrationFilesystem.resolvedDirectoryTarget(displayDestination)
        guard fm.fileExists(atPath: destination.path) else {
            return SkillTargetStatus(agent: target.agent, path: displayDestination.path,
                                     state: .notInstalled)
        }
        let skill = try? String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8)
        guard SkillInstall.mayOverwrite(directoryExists: true, existingSKILL: skill) else {
            return SkillTargetStatus(agent: target.agent, path: displayDestination.path, state: .conflict)
        }
        let state: IntegrationState = IntegrationFilesystem.directoryMatches(
            source: source,
            destination: destination,
            bakedCLI: nil
        ) ? .installed : .updateAvailable
        return SkillTargetStatus(agent: target.agent, path: displayDestination.path, state: state)
    }

    func isKnownPackageTool(_ cli: URL) -> Bool {
        let path = cli.standardizedFileURL
        let resolved = cli.resolvingSymlinksInPath()
        return environment.knownCommandLineTools.contains {
            $0.standardizedFileURL == path || $0.resolvingSymlinksInPath() == resolved
        }
    }

    func launcherTarget(_ launcher: URL) -> URL? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: launcher.path) else {
            return nil
        }
        if destination.hasPrefix("/") { return URL(fileURLWithPath: destination) }
        return launcher.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL
    }

    func hookAssetsStatus() -> HookComponentStatus {
        guard let source = environment.resource(named: "agent-status") else {
            return HookComponentStatus(state: .unavailable, detail: "Bundled hook scripts are unavailable.")
        }
        guard let hooksCLI = hooksCommandLineTool() else {
            return HookComponentStatus(
                state: .unavailable,
                detail: "A persistent agtermctl installation is required before lifecycle hooks can run."
            )
        }
        let displayDestination = environment.hooksDirectory
        let destination = IntegrationFilesystem.resolvedDirectoryTarget(displayDestination)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return HookComponentStatus(state: .notInstalled,
                                       detail: "Hook scripts are not installed at \(displayDestination.path).")
        }
        guard IntegrationFilesystem.hookDirectoryIsManaged(source: source, destination: destination) else {
            return HookComponentStatus(state: .conflict,
                                       detail: "\(displayDestination.path) is not an agterm-managed directory.")
        }
        let bakedCLI = hooksCLI.path
        if IntegrationFilesystem.directoryMatches(source: source, destination: destination,
                                                  bakedCLI: bakedCLI) {
            return HookComponentStatus(state: .installed,
                                       detail: "Hook scripts are current at \(displayDestination.path).")
        }
        let sourceEntries = (try? FileManager.default.subpathsOfDirectory(atPath: source.path)) ?? []
        let destinationEntries = (try? FileManager.default.subpathsOfDirectory(atPath: destination.path)) ?? []
        let state: IntegrationState = Set(destinationEntries).isSuperset(of: Set(sourceEntries))
            ? .updateAvailable : .partial
        return HookComponentStatus(state: state,
                                   detail: state == .partial
                                       ? "Some managed hook scripts are missing."
                                       : "Managed hook scripts can be updated.")
    }

    func combinedHookStatus(configuration: IntegrationItemStatus,
                            assets: HookComponentStatus,
                            shell: HookComponentStatus) -> IntegrationItemStatus {
        let states = [configuration.state, assets.state, shell.state]
        let state: IntegrationState
        if states.contains(.conflict) {
            state = .conflict
        } else if assets.state == .unavailable {
            state = .unavailable
        } else if states.allSatisfy({ $0 == .installed }) {
            state = .installed
        } else if states.allSatisfy({ $0 == .notInstalled }) {
            state = .notInstalled
        } else if states.allSatisfy({ [.installed, .updateAvailable].contains($0) }) {
            state = .updateAvailable
        } else {
            state = .partial
        }
        return IntegrationItemStatus(kind: configuration.kind, state: state, path: configuration.path,
                                     detail: "\(configuration.detail) \(assets.detail) \(shell.detail)")
    }

    func shellRCStatus() -> HookComponentStatus {
        let fm = FileManager.default
        let files = [
            (".zshrc", AgentHooksInstall.integrationRelativePath),
            (".bashrc", AgentHooksInstall.integrationRelativePath),
            (".config/fish/config.fish", AgentHooksInstall.fishIntegrationRelativePath),
        ].filter { relative, _ in
            !relative.hasSuffix("config.fish") || fm.fileExists(
                atPath: environment.homeDirectory.appendingPathComponent(relative)
                    .deletingLastPathComponent().path)
        }
        var managed = 0
        var incomplete = 0
        for (relative, script) in files {
            let path = environment.homeDirectory.appendingPathComponent(relative)
            do {
                let existing = try IntegrationFilesystem.read(path) ?? ""
                switch IntegrationManagedMarkers.shellRCState(
                    existing: existing, scriptDir: environment.hooksDirectory.path, scriptName: script
                ) {
                case .installed:
                    managed += 1
                case .absent:
                    incomplete += 1
                case .malformed:
                    return HookComponentStatus(
                        state: .conflict,
                        detail: "\(path.path) contains an incomplete agterm-managed block."
                    )
                }
            } catch {
                return HookComponentStatus(state: .conflict,
                                           detail: "\(path.path) could not be read.")
            }
        }
        if incomplete == 0 {
            return HookComponentStatus(state: .installed,
                                       detail: "Shell startup integration is configured.")
        }
        return HookComponentStatus(
            state: managed == 0 ? .notInstalled : .partial,
            detail: managed == 0
                ? "Shell startup integration is not configured."
                : "Some shell startup integration needs repair."
        )
    }

    func claudeConfigurationStatus() -> IntegrationItemStatus {
        let path = environment.homeDirectory.appendingPathComponent(".claude/settings.json")
        do {
            let existing = try IntegrationFilesystem.read(path)
            let merge = try AgentHooksInstall.mergeClaudeSettings(existing: existing,
                                                                   scriptDir: environment.hooksDirectory.path)
            if !merge.changed {
                return IntegrationItemStatus(kind: .claudeHooks, state: .installed,
                                             path: path.path, detail: "Claude Code hooks are configured.")
            }
            let current = existing ?? ""
            let hasAgterm = current.contains(AgentHooksInstall.wrapperName)
            return IntegrationItemStatus(kind: .claudeHooks, state: hasAgterm ? .partial : .notInstalled,
                                         path: path.path,
                                         detail: hasAgterm ? "Some Claude Code hooks need repair."
                                                           : "Claude Code hooks are not configured.")
        } catch AgentHooksInstall.MergeError.malformedExistingSettings {
            return IntegrationItemStatus(kind: .claudeHooks, state: .conflict, path: path.path,
                                         detail: "settings.json is not a valid JSON object.")
        } catch {
            return IntegrationItemStatus(kind: .claudeHooks, state: .conflict, path: path.path,
                                         detail: "settings.json could not be read.")
        }
    }

    func codexConfigurationStatus() -> IntegrationItemStatus {
        let base = environment.homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let path = base.appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: base.path) else {
            return IntegrationItemStatus(kind: .codexHooks, state: .unavailable, path: path.path,
                                         detail: "No ~/.codex directory was detected.")
        }
        do {
            let existing = try IntegrationFilesystem.read(path) ?? ""
            switch AgentHooksInstall.mergeCodexConfig(existing: existing,
                                                       scriptDir: environment.hooksDirectory.path) {
            case .unchanged:
                guard IntegrationManagedMarkers.codexBlockIsCurrent(
                    existing: existing, scriptDir: environment.hooksDirectory.path
                ) else {
                    return IntegrationItemStatus(
                        kind: .codexHooks, state: .conflict, path: path.path,
                        detail: "The agterm marker block is incomplete or belongs to another installation."
                    )
                }
                return IntegrationItemStatus(kind: .codexHooks, state: .installed, path: path.path,
                                             detail: "Codex hooks are configured.")
            case .merged:
                let state: IntegrationState = existing.contains(AgentHooksInstall.rcMarkerBegin)
                    ? .updateAvailable : .notInstalled
                return IntegrationItemStatus(kind: .codexHooks, state: state, path: path.path,
                                             detail: state == .updateAvailable
                                                ? "Managed Codex hooks can be updated."
                                                : "Codex hooks are not configured.")
            case .hooksExist:
                return IntegrationItemStatus(kind: .codexHooks, state: .conflict, path: path.path,
                                             detail: "Codex already defines custom hooks.")
            case .unparseable:
                return IntegrationItemStatus(kind: .codexHooks, state: .conflict, path: path.path,
                                             detail: "config.toml is invalid.")
            }
        } catch {
            return IntegrationItemStatus(kind: .codexHooks, state: .conflict, path: path.path,
                                         detail: "config.toml could not be read.")
        }
    }
}
