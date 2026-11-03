import Foundation
import agtermCore

enum IntegrationFilesystem {
    static func validate(_ operation: IntegrationOperation) throws {
        switch operation {
        case .validate(let path, let expected):
            try check(URL(fileURLWithPath: path), expected: expected)
        case .replaceDirectory(let source, let destination, let displayPath, let expectedSource,
                               let expectedDestination, let expectedDisplayPath, _):
            try check(URL(fileURLWithPath: source, isDirectory: true), expected: expectedSource)
            try check(URL(fileURLWithPath: destination, isDirectory: true), expected: expectedDestination)
            try check(URL(fileURLWithPath: displayPath, isDirectory: true), expected: expectedDisplayPath)
        case .writeText(let path, let target, _, _, let expectedPath, let expectedTarget,
                        let expectedBackup):
            try check(URL(fileURLWithPath: path), expected: expectedPath)
            try check(URL(fileURLWithPath: target), expected: expectedTarget)
            if let expectedBackup {
                try check(backupURL(forTarget: target), expected: expectedBackup)
            }
        case .copyFile(let source, let path, let target, let expectedSource, let expectedPath,
                       let expectedTarget):
            try check(URL(fileURLWithPath: source), expected: expectedSource)
            try check(URL(fileURLWithPath: path), expected: expectedPath)
            try check(URL(fileURLWithPath: target), expected: expectedTarget)
        case .symlink(let path, let target, let expectedPath, let expectedTarget):
            try check(URL(fileURLWithPath: path), expected: expectedPath)
            try check(URL(fileURLWithPath: target), expected: expectedTarget)
        }
    }

    static func fingerprint(_ url: URL) -> FileFingerprint {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            return FileFingerprint(value: "missing")
        }
        let type = attrs[.type] as? FileAttributeType
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if type == .typeSymbolicLink {
            let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "unreadable"
            return FileFingerprint(value: "link:\(target)")
        }
        if type == .typeDirectory {
            let entries = (try? fm.subpathsOfDirectory(atPath: url.path))?.sorted() ?? []
            var digest = StableDigest()
            digest.add("directory:\(mode)")
            for entry in entries {
                digest.add(entry)
                digest.add(fingerprint(url.appendingPathComponent(entry)).value)
            }
            return FileFingerprint(value: "dir:\(digest.hex)")
        }
        guard let data = try? Data(contentsOf: url) else {
            return FileFingerprint(value: "unreadable")
        }
        var digest = StableDigest()
        digest.add("file:\(mode)")
        digest.add(data)
        return FileFingerprint(value: "file:\(digest.hex)")
    }

    static func isDanglingSymbolicLink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
            && !FileManager.default.fileExists(atPath: url.path)
    }

    static func resolvedWriteTarget(_ url: URL) -> URL {
        resolvingExistingAncestors(of: url)
    }

    static func resolvedDirectoryTarget(_ url: URL) -> URL {
        resolvingExistingAncestors(of: url)
    }

    /// A stable lexical path to validate when a missing destination is reached through a symlinked
    /// ancestor. Validating the missing leaf again after its shared target was installed would turn a
    /// deliberate alias into a false stale-plan failure; the existing alias anchor itself is the state
    /// whose identity must remain unchanged.
    static func validationAnchor(for url: URL) -> URL {
        nearestExistingAncestor(of: url)
    }

    /// `URL.resolvingSymlinksInPath()` leaves the whole path lexical when its leaf does not exist.
    /// Resolve the nearest existing ancestor first, then restore the missing suffix so aliases such as
    /// `~/.claude -> shared-agent-home` deduplicate new descendants before a plan is applied.
    private static func resolvingExistingAncestors(of url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        let existing = nearestExistingAncestor(of: ancestor)
        while ancestor != existing {
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in suffix { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL
    }

    private static func nearestExistingAncestor(of url: URL) -> URL {
        let fm = FileManager.default
        var ancestor = url.standardizedFileURL
        while (try? fm.attributesOfItem(atPath: ancestor.path)) == nil,
              ancestor.path != "/" {
            ancestor.deleteLastPathComponent()
        }
        return ancestor
    }

    static func directoryMatches(source: URL, destination: URL, bakedCLI: String?) -> Bool {
        let fm = FileManager.default
        guard itemType(source) == .typeDirectory, itemType(destination) == .typeDirectory,
              let sourceEntries = try? fm.subpathsOfDirectory(atPath: source.path).sorted(),
              let destinationEntries = try? fm.subpathsOfDirectory(atPath: destination.path).sorted(),
              sourceEntries == destinationEntries else { return false }

        for relative in sourceEntries {
            let sourceItem = source.appendingPathComponent(relative)
            let destinationItem = destination.appendingPathComponent(relative)
            guard itemType(sourceItem) == itemType(destinationItem),
                  mode(sourceItem) == mode(destinationItem) else { return false }
            switch itemType(sourceItem) {
            case .typeDirectory:
                continue
            case .typeSymbolicLink:
                let sourceTarget = try? fm.destinationOfSymbolicLink(atPath: sourceItem.path)
                let destinationTarget = try? fm.destinationOfSymbolicLink(atPath: destinationItem.path)
                guard sourceTarget == destinationTarget else { return false }
            default:
                guard let sourceData = preparedData(at: sourceItem, relative: relative, bakedCLI: bakedCLI),
                      let destinationData = try? Data(contentsOf: destinationItem),
                      sourceData == destinationData else { return false }
            }
        }
        return true
    }

    static func hookDirectoryIsManaged(source: URL, destination: URL) -> Bool {
        let fm = FileManager.default
        guard itemType(destination) == .typeDirectory,
              let sourceEntries = try? fm.subpathsOfDirectory(atPath: source.path),
              let destinationEntries = try? fm.subpathsOfDirectory(atPath: destination.path) else {
            return false
        }
        if destinationEntries.isEmpty { return true }
        let allowed = Set(sourceEntries)
        for relative in destinationEntries {
            let item = destination.appendingPathComponent(relative)
            if !allowed.contains(relative) {
                // Older agterm releases may leave a retired script behind (for example v0.11's
                // codex-notify.sh). Accept only regular text files carrying the durable package marker;
                // arbitrary extra content still makes the directory a protected conflict.
                guard itemType(item) == .typeRegular,
                      let text = try? String(contentsOf: item, encoding: .utf8),
                      text.localizedCaseInsensitiveContains("agterm-agent-status") else { return false }
                continue
            }
            if itemType(item) == .typeDirectory { continue }
            guard itemType(item) == .typeRegular,
                  let text = try? String(contentsOf: item, encoding: .utf8),
                  text.localizedCaseInsensitiveContains("agterm") else { return false }
        }
        return true
    }

    static func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Recursively copy a bundled resource without ever preserving ownership.
    ///
    /// `FileManager.copyItem` applies the source's owner/group to each copied *directory* on Linux and
    /// turns the resulting `EPERM` into a fatal Cocoa 513 error, so a system-wide install
    /// (`/opt/agterm-linux`, root-owned) can never be copied into an unprivileged user's home: the
    /// recursive copy dies at the first subdirectory with "You don't have permission." Directories are
    /// therefore created by hand and only their `.posixPermissions` are applied — owner and group are
    /// never read and never written, which is what Darwin's `copyItem` degrades to for an unprivileged
    /// caller. (macOS is unaffected either way: its installers still use `copyItem` and were not
    /// changed here.)
    ///
    /// Everything else (regular files, symlinks including dangling ones, exotic types) still goes
    /// through per-item `copyItem`, which is ownership-safe: verified from a genuinely root-owned source
    /// as an unprivileged user, a regular file keeps its mode and a symlink is recreated as a symlink
    /// rather than resolved, both landing owned by the copying user. The bundled resource trees hold no
    /// symlinks today, so that leg is defensive.
    ///
    /// `applyMode` is an injectable seam so tests can pin both the ownership invariant and the
    /// mode-after-children ordering; production callers use the default. The mode is applied *after* the
    /// children are copied so a read-only source directory mode cannot block its own population.
    static func installCopy(
        from source: URL,
        to destination: URL,
        applyMode: (NSNumber, String) throws -> Void = { mode, path in
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
    ) throws {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            try fm.copyItem(at: source, to: destination)
            return
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        // `contentsOfDirectory(atPath:)` has no `.skipsHiddenFiles` option, so dotfiles cannot be
        // silently dropped the way the URL-returning overload could.
        for child in try fm.contentsOfDirectory(atPath: source.path).sorted() {
            try installCopy(from: source.appendingPathComponent(child),
                            to: destination.appendingPathComponent(child),
                            applyMode: applyMode)
        }
        guard let mode = attributes[.posixPermissions] as? NSNumber else {
            // Unreachable for a successfully stat'ed path on Linux; failing loudly beats silently
            // leaving the copy on the umask-derived `createDirectory` default.
            throw IntegrationServiceError.invalidResource(
                "The bundled resource directory reports no permissions: \(source.path)"
            )
        }
        try applyMode(mode, destination.path)
    }

    /// `copyTree` is the injectable staging-copy seam, mirroring `moveItem`; the default routes both
    /// staging copies through `installCopy` so neither arm can preserve source ownership. Both seams are
    /// defaulted closures of the same type, so pass either one as a *labeled* argument — an unlabeled
    /// trailing closure binds by declaration order, and the compiler warns about neither choice.
    static func apply(
        _ operation: IntegrationOperation,
        moveItem: (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        },
        copyTree: (URL, URL) throws -> Void = { source, destination in
            try IntegrationFilesystem.installCopy(from: source, to: destination)
        }
    ) throws -> IntegrationOperationResult {
        switch operation {
        case .validate(let path, let expected):
            try check(URL(fileURLWithPath: path), expected: expected)
            return IntegrationOperationResult(action: "Verify", path: path, success: true,
                                              message: "previewed path is unchanged")
        case .replaceDirectory(let sourcePath, let destinationPath, let displayPath, let expectedSource,
                               let expectedDestination, let expectedDisplayPath, let bakedCLI):
            let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
            let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
            try check(source, expected: expectedSource)
            try check(destination, expected: expectedDestination)
            try check(URL(fileURLWithPath: displayPath, isDirectory: true), expected: expectedDisplayPath)
            let fm = FileManager.default
            let parent = destination.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let token = UUID().uuidString
            let staged = parent.appendingPathComponent(".\(destination.lastPathComponent).agterm-new-\(token)")
            let previous = parent.appendingPathComponent(".\(destination.lastPathComponent).agterm-old-\(token)")
            var preservePrevious = false
            defer {
                if itemExists(staged) { try? fm.removeItem(at: staged) }
                if !preservePrevious, itemExists(previous) { try? fm.removeItem(at: previous) }
            }
            try copyTree(source, staged)
            if let bakedCLI { try bakeCLIPath(bakedCLI, in: staged) }
            let hadPrevious = itemExists(destination)
            if hadPrevious { try moveItem(destination, previous) }
            do {
                try moveItem(staged, destination)
            } catch let installError {
                if hadPrevious {
                    do {
                        try moveItem(previous, destination)
                    } catch let rollbackError {
                        preservePrevious = true
                        throw IntegrationServiceError.rollbackFailed(
                            destination: destination.path,
                            backup: previous.path,
                            detail: "install failed: \(installError.localizedDescription); "
                                + "rollback failed: \(rollbackError.localizedDescription)"
                        )
                    }
                }
                throw installError
            }
            if hadPrevious { try? fm.removeItem(at: previous) }
            return IntegrationOperationResult(action: "Copy", path: destinationPath, success: true,
                                              message: "installed bundled resources")

        case .writeText(let path, let target, let contents, let backup,
                        let expectedPath, let expectedTarget, let expectedBackup):
            let displayURL = URL(fileURLWithPath: path)
            let url = URL(fileURLWithPath: target)
            try check(displayURL, expected: expectedPath)
            try check(url, expected: expectedTarget)
            if let expectedBackup {
                try check(backupURL(forTarget: target), expected: expectedBackup)
            }
            let existing = try read(url)
            if backup, let existing {
                let backup = backupURL(forTarget: target)
                try AgentHooksInstall.writeFile(existing, toPath: backup.path,
                                                posixMode: AgentHooksInstall.posixMode(ofFile: url.path))
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try AgentHooksInstall.writeFile(contents, toPath: url.path,
                                            posixMode: AgentHooksInstall.posixMode(ofFile: url.path))
            return IntegrationOperationResult(action: "Write", path: path, success: true,
                                              message: backup && existing != nil ? "updated with backup" : "updated")

        case .copyFile(let sourcePath, let path, let targetPath, let expectedSource,
                       let expectedPath, let expectedTarget):
            let source = URL(fileURLWithPath: sourcePath)
            let displayURL = URL(fileURLWithPath: path)
            let target = URL(fileURLWithPath: targetPath)
            try check(source, expected: expectedSource)
            try check(displayURL, expected: expectedPath)
            try check(target, expected: expectedTarget)
            guard itemType(source) == .typeRegular else {
                throw IntegrationServiceError.invalidResource(
                    "The bundled Pi extension is not a regular file: \(source.path)"
                )
            }
            let fm = FileManager.default
            let parent = target.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let token = UUID().uuidString
            let staged = parent.appendingPathComponent(".\(target.lastPathComponent).agterm-new-\(token)")
            let previous = parent.appendingPathComponent(".\(target.lastPathComponent).agterm-old-\(token)")
            var preservePrevious = false
            defer {
                if itemExists(staged) { try? fm.removeItem(at: staged) }
                if !preservePrevious, itemExists(previous) { try? fm.removeItem(at: previous) }
            }
            try copyTree(source, staged)
            let hadPrevious = itemExists(target)
            if hadPrevious { try moveItem(target, previous) }
            do {
                try moveItem(staged, target)
            } catch let installError {
                if hadPrevious {
                    do {
                        try moveItem(previous, target)
                    } catch let rollbackError {
                        preservePrevious = true
                        throw IntegrationServiceError.rollbackFailed(
                            destination: path,
                            backup: previous.path,
                            detail: "install failed: \(installError.localizedDescription); "
                                + "rollback failed: \(rollbackError.localizedDescription)"
                        )
                    }
                }
                throw installError
            }
            if hadPrevious { try? fm.removeItem(at: previous) }
            return IntegrationOperationResult(action: "Copy", path: path, success: true,
                                              message: "installed bundled Pi extension")

        case .symlink(let path, let target, let expectedPath, let expectedTarget):
            let url = URL(fileURLWithPath: path)
            try check(url, expected: expectedPath)
            try check(URL(fileURLWithPath: target), expected: expectedTarget)
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if itemExists(url) { try fm.removeItem(at: url) }
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
            return IntegrationOperationResult(action: "Link", path: path, success: true,
                                              message: "linked to \(target)")
        }
    }

    private static func check(_ url: URL, expected: FileFingerprint) throws {
        guard fingerprint(url) == expected else { throw IntegrationServiceError.stalePlan(url.path) }
    }

    private static func backupURL(forTarget target: String) -> URL {
        URL(fileURLWithPath: AgentHooksInstall.backupPath(for: target))
    }

    private static func itemExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func itemType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType
    }

    private static func mode(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    private static func preparedData(at url: URL, relative: String, bakedCLI: String?) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let wrappers = [AgentHooksInstall.wrapperName, AgentHooksInstall.codexWrapperName]
        guard wrappers.contains(relative), let bakedCLI,
              let text = String(data: data, encoding: .utf8) else { return data }
        return Data(bakedCLIContents(bakedCLI, text: text).utf8)
    }

    private static func bakeCLIPath(_ tool: String, in destination: URL) throws {
        for name in [AgentHooksInstall.wrapperName, AgentHooksInstall.codexWrapperName] {
            let url = destination.appendingPathComponent(name)
            let text = try String(contentsOf: url, encoding: .utf8)
            try AgentHooksInstall.writeFile(bakedCLIContents(tool, text: text), toPath: url.path,
                                            posixMode: AgentHooksInstall.posixMode(ofFile: url.path))
        }
    }

    private static func bakedCLIContents(_ tool: String, text: String) -> String {
        let marker = "# >>> agterm agtermctl path (installer-baked) >>>"
        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(of: marker) {
            lines.remove(at: index)
            if index < lines.count { lines.remove(at: index) }
        }
        let index = lines.first?.hasPrefix("#!") == true ? 1 : 0
        lines.insert("[ -n \"${AGTERMCTL:-}\" ] || AGTERMCTL=\(AgentHooksInstall.shellQuote(tool))", at: index)
        lines.insert(marker, at: index)
        return lines.joined(separator: "\n")
    }
}

private struct StableDigest {
    private var value: UInt64 = 14_695_981_039_346_656_037

    mutating func add(_ string: String) { add(Data(string.utf8)) }

    mutating func add(_ data: Data) {
        for byte in data {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
    }

    var hex: String { String(value, radix: 16) }
}
