import Foundation
import Testing
@testable import LinuxIntegrations

/// `installCopy` is the ownership-agnostic replacement for `FileManager.copyItem` on the integration
/// staging path. The genuinely root-owned case cannot be reproduced unprivileged (a chown to self never
/// fails, and CI runs as root, where it never fails either), so the invariant is pinned structurally:
/// `applyMode` cannot express owner or group, and the recorder tests pin that every directory's mode
/// goes through it, after that directory's children. The production routing is pinned separately —
/// `applyDefaultsToInstallCopy` fails if `apply`'s `copyTree` default reverts to `copyItem`, and the two
/// arm tests fail if either staging site stops using the seam.
@Suite("Linux integration install copy")
struct IntegrationFilesystemCopyTests {
    @Test("copies dotfiles, empty directories, modes and both kinds of symlink")
    func treeFidelity() throws {
        let fixture = try Fixture()
        defer { destroy(fixture.root) }
        let scratch = fixture.root
        let source = scratch.appendingPathComponent("src", isDirectory: true)
        try makeDirectory(source)
        try makeDirectory(source.appendingPathComponent("empty", isDirectory: true))
        try makeDirectory(source.appendingPathComponent("nested", isDirectory: true))
        try makeDirectory(source.appendingPathComponent("nested/deep", isDirectory: true))
        try fixture.write("dot\n", to: source.appendingPathComponent(".hidden"), mode: 0o644)
        try fixture.write("leaf\n", to: source.appendingPathComponent("nested/deep/leaf.txt"), mode: 0o644)
        try fixture.write("#!/bin/sh\n", to: source.appendingPathComponent("nested/run.sh"), mode: 0o755)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path,
                                                   withDestinationPath: "nested/run.sh")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("broken").path,
                                                   withDestinationPath: "nowhere/absent")
        // A link *to a directory* pins the lstat-based type dispatch: any symlink-following check
        // (`fileExists(atPath:isDirectory:)`, `hasDirectoryPath`, `resolvingSymlinksInPath`) would
        // expand it into a real recursive copy and every other assertion here would still pass.
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("dirlink").path,
                                                   withDestinationPath: "nested")

        let destination = scratch.appendingPathComponent("dst", isDirectory: true)
        try IntegrationFilesystem.installCopy(from: source, to: destination)

        #expect(try entries(of: destination)
            == [".hidden", "broken", "dirlink", "empty", "link", "nested"])
        #expect(try linkTarget(of: destination.appendingPathComponent("dirlink")) == "nested")
        #expect(try entries(of: destination.appendingPathComponent("empty")) == [])
        #expect(try entries(of: destination.appendingPathComponent("nested")) == ["deep", "run.sh"])
        #expect(try contents(of: destination.appendingPathComponent(".hidden")) == "dot\n")
        #expect(try contents(of: destination.appendingPathComponent("nested/deep/leaf.txt")) == "leaf\n")
        #expect(try mode(of: destination.appendingPathComponent(".hidden")) == 0o644)
        #expect(try mode(of: destination.appendingPathComponent("nested/deep/leaf.txt")) == 0o644)
        #expect(try mode(of: destination.appendingPathComponent("nested/run.sh")) == 0o755)
        #expect(try linkTarget(of: destination.appendingPathComponent("link")) == "nested/run.sh")
        #expect(try linkTarget(of: destination.appendingPathComponent("broken")) == "nowhere/absent")
    }

    @Test("directory modes umask cannot produce survive the copy")
    func directoryModes() throws {
        let fixture = try Fixture()
        defer { destroy(fixture.root) }
        let scratch = fixture.root
        let source = scratch.appendingPathComponent("src", isDirectory: true)
        try makeDirectory(source)
        try makeDirectory(source.appendingPathComponent("group", isDirectory: true))
        try makeDirectory(source.appendingPathComponent("group/exec-only", isDirectory: true))
        try fixture.write("x\n", to: source.appendingPathComponent("group/exec-only/file.txt"), mode: 0o600)
        try chmod(source.appendingPathComponent("group/exec-only"), 0o701)
        try chmod(source.appendingPathComponent("group"), 0o750)

        let destination = scratch.appendingPathComponent("dst", isDirectory: true)
        try IntegrationFilesystem.installCopy(from: source, to: destination)

        #expect(try mode(of: destination.appendingPathComponent("group")) == 0o750)
        #expect(try mode(of: destination.appendingPathComponent("group/exec-only")) == 0o701)
        #expect(try mode(of: destination.appendingPathComponent("group/exec-only/file.txt")) == 0o600)
    }

    /// The mode assertions alone only discriminate unprivileged (root ignores a 0500 directory), so the
    /// ordering itself is pinned through the `applyMode` seam: each directory's children are captured at
    /// the moment its mode is applied, which fails deterministically at any uid if the mode application
    /// ever moves ahead of the recursion.
    @Test("a read-only source directory is populated before its mode is applied")
    func populateThenRestrict() throws {
        let fixture = try Fixture()
        defer { destroy(fixture.root) }
        let scratch = fixture.root
        let source = scratch.appendingPathComponent("src", isDirectory: true)
        try makeDirectory(source)
        let locked = source.appendingPathComponent("locked", isDirectory: true)
        try makeDirectory(locked)
        try fixture.write("one\n", to: locked.appendingPathComponent("one.txt"), mode: 0o644)
        try makeDirectory(locked.appendingPathComponent("inner", isDirectory: true))
        try fixture.write("two\n", to: locked.appendingPathComponent("inner/two.txt"), mode: 0o644)
        try chmod(locked.appendingPathComponent("inner"), 0o500)
        try chmod(locked, 0o500)

        let destination = scratch.appendingPathComponent("dst", isDirectory: true)
        var childrenAtModeTime: [String: [String]] = [:]
        try IntegrationFilesystem.installCopy(from: source, to: destination) { mode, path in
            childrenAtModeTime[path] = (try? FileManager.default.contentsOfDirectory(atPath: path))?
                .sorted() ?? []
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }

        let copied = destination.appendingPathComponent("locked")
        #expect(childrenAtModeTime[copied.path] == ["inner", "one.txt"])
        #expect(childrenAtModeTime[copied.appendingPathComponent("inner").path] == ["two.txt"])
        #expect(try entries(of: copied) == ["inner", "one.txt"])
        #expect(try contents(of: copied.appendingPathComponent("one.txt")) == "one\n")
        #expect(try contents(of: copied.appendingPathComponent("inner/two.txt")) == "two\n")
        #expect(try mode(of: copied) == 0o500)
        #expect(try mode(of: copied.appendingPathComponent("inner")) == 0o500)
    }

    /// Verifies the seam, not the syscall: a regression that set `.ownerAccountID` directly, bypassing
    /// `applyMode`, would still pass. What it does pin is that every directory — dotdirs included, files
    /// and symlinks excluded — has its mode applied exactly once, through the one seam whose signature
    /// cannot express owner or group.
    @Test("every directory's mode is applied exactly once through the mode seam")
    func directoryModeSeamUsage() throws {
        let fixture = try Fixture()
        defer { destroy(fixture.root) }
        let scratch = fixture.root
        let source = scratch.appendingPathComponent("src", isDirectory: true)
        try makeDirectory(source)
        try makeDirectory(source.appendingPathComponent(".dotdir", isDirectory: true))
        try makeDirectory(source.appendingPathComponent("plain", isDirectory: true))
        try fixture.write("f\n", to: source.appendingPathComponent("plain/file.txt"), mode: 0o644)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("plain/link").path,
                                                   withDestinationPath: "file.txt")
        try chmod(source.appendingPathComponent(".dotdir"), 0o755)
        try chmod(source.appendingPathComponent("plain"), 0o750)
        try chmod(source, 0o700)

        let destination = scratch.appendingPathComponent("dst", isDirectory: true)
        var recorded: [(path: String, mode: Int)] = []
        try IntegrationFilesystem.installCopy(from: source, to: destination) { mode, path in
            recorded.append((path, mode.intValue & 0o7777))
        }

        #expect(recorded.map(\.path).sorted() == [
            destination.path,
            destination.appendingPathComponent(".dotdir").path,
            destination.appendingPathComponent("plain").path,
        ].sorted())
        let byPath = Dictionary(uniqueKeysWithValues: recorded.map { ($0.path, $0.mode) })
        #expect(byPath[destination.path] == 0o700)
        #expect(byPath[destination.appendingPathComponent(".dotdir").path] == 0o755)
        #expect(byPath[destination.appendingPathComponent("plain").path] == 0o750)
    }

    /// Pins the call-site routing: reverting the `.replaceDirectory` arm to a bare `FileManager.copyItem`
    /// makes this fail. It proves the arm calls *the parameter*; that the parameter's production default
    /// is `installCopy` is pinned separately by `applyDefaultsToInstallCopy`.
    @Test("the directory install arm routes its staging copy through the copyTree seam")
    func replaceDirectoryRoutesThroughCopyTree() throws {
        let fixture = try Fixture()
        defer { destroy(fixture.root) }
        let scratch = fixture.root
        let source = scratch.appendingPathComponent("src", isDirectory: true)
        try makeDirectory(source.appendingPathComponent("nested", isDirectory: true))
        try fixture.write("payload\n", to: source.appendingPathComponent("nested/file.txt"), mode: 0o644)
        let destination = scratch.appendingPathComponent("dst", isDirectory: true)
        let operation = replaceDirectory(from: source, to: destination)

        let recorder = CopyRecorder()
        let result = try IntegrationFilesystem.apply(operation, copyTree: recorder.copy)

        #expect(result.success)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.from == source.path)
        let stagingPrefix = scratch.appendingPathComponent(".dst.agterm-new-").path
        #expect(recorder.calls.first?.to.hasPrefix(stagingPrefix) == true)
        #expect(try contents(of: destination.appendingPathComponent("nested/file.txt")) == "payload\n")
    }

    /// Pins the routing of the single-file arm, which stages a regular file rather than a tree but must
    /// still go through the one primitive.
    @Test("the single-file install arm routes its staging copy through the copyTree seam")
    func copyFileRoutesThroughCopyTree() throws {
        let fixture = try Fixture()
        defer { destroy(fixture.root) }
        let scratch = fixture.root
        let source = scratch.appendingPathComponent("extension.js")
        try fixture.write("// pi\n", to: source, mode: 0o644)
        let destination = scratch.appendingPathComponent("installed/extension.js")
        let operation = IntegrationOperation.copyFile(
            source: source.path,
            path: destination.path,
            target: destination.path,
            expectedSource: IntegrationFilesystem.fingerprint(source),
            expectedPath: IntegrationFilesystem.fingerprint(destination),
            expectedTarget: IntegrationFilesystem.fingerprint(destination)
        )

        let recorder = CopyRecorder()
        let result = try IntegrationFilesystem.apply(operation, copyTree: recorder.copy)

        #expect(result.success)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.from == source.path)
        let stagingPrefix = scratch.appendingPathComponent("installed/.extension.js.agterm-new-").path
        #expect(recorder.calls.first?.to.hasPrefix(stagingPrefix) == true)
        #expect(try contents(of: destination) == "// pi\n")
    }

    /// The two arm tests above inject `copyTree`, so they only prove the arms call *the parameter*. This
    /// one calls `apply` with no injection at all and discriminates on a side effect only the default
    /// can produce: `FileManager.copyItem` carries a directory's modification date across, while
    /// `installCopy`'s `createDirectory` stamps a fresh one. Reverting the default to `copyItem` fails
    /// here and nowhere else. (`fingerprint` and `directoryMatches` both ignore mtime, so nothing in
    /// production depends on the distinction.)
    ///
    /// The control leg keeps that discriminator honest: it copies the same source with `copyItem`
    /// directly, so a future swift-foundation that stops preserving a directory's modification date
    /// fails *here*, loudly, instead of leaving the assertion above to pass vacuously and silently
    /// un-pin the default.
    @Test("apply's staging copy defaults to installCopy, not FileManager.copyItem")
    func applyDefaultsToInstallCopy() throws {
        let fixture = try Fixture()
        defer { destroy(fixture.root) }
        let scratch = fixture.root
        let source = scratch.appendingPathComponent("src", isDirectory: true)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try makeDirectory(nested)
        try fixture.write("payload\n", to: nested.appendingPathComponent("file.txt"), mode: 0o644)
        let backdated = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: backdated], ofItemAtPath: nested.path)

        let destination = scratch.appendingPathComponent("dst", isDirectory: true)
        let result = try IntegrationFilesystem.apply(replaceDirectory(from: source, to: destination))

        #expect(result.success)
        #expect(try contents(of: destination.appendingPathComponent("nested/file.txt")) == "payload\n")
        let copied = destination.appendingPathComponent("nested")
        let attributes = try FileManager.default.attributesOfItem(atPath: copied.path)
        let stamp = try #require(attributes[.modificationDate] as? Date)
        #expect(stamp.timeIntervalSince(backdated) > 1)

        let control = scratch.appendingPathComponent("control", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: control)
        let controlAttributes = try FileManager.default
            .attributesOfItem(atPath: control.appendingPathComponent("nested").path)
        let controlStamp = try #require(controlAttributes[.modificationDate] as? Date)
        #expect(abs(controlStamp.timeIntervalSince(backdated)) < 1)
    }

    @Test("a failing staging copy leaves neither a destination nor staging residue")
    func stagingCopyFailureLeavesNoResidue() throws {
        struct StageFailure: Error {}

        let fixture = try Fixture()
        defer { destroy(fixture.root) }
        let scratch = fixture.root
        let source = scratch.appendingPathComponent("src", isDirectory: true)
        try makeDirectory(source.appendingPathComponent("nested", isDirectory: true))
        try fixture.write("payload\n", to: source.appendingPathComponent("nested/file.txt"), mode: 0o644)
        let destination = scratch.appendingPathComponent("dst", isDirectory: true)

        #expect(throws: StageFailure.self) {
            // Stage fully first, so the transaction's cleanup has something real to remove.
            try IntegrationFilesystem.apply(replaceDirectory(from: source, to: destination),
                                            copyTree: { from, to in
                try IntegrationFilesystem.installCopy(from: from, to: to)
                throw StageFailure()
            })
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try entries(of: scratch).filter { $0.contains(".agterm-") } == [])
    }

    @Test("a missing source propagates its error without creating a destination")
    func missingSourceThrows() throws {
        let fixture = try Fixture()
        defer { destroy(fixture.root) }
        let scratch = fixture.root
        let source = scratch.appendingPathComponent("absent", isDirectory: true)
        let destination = scratch.appendingPathComponent("dst", isDirectory: true)

        #expect(throws: CocoaError.self) {
            try IntegrationFilesystem.installCopy(from: source, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    private func replaceDirectory(from source: URL, to destination: URL) -> IntegrationOperation {
        .replaceDirectory(
            source: source.path,
            destination: destination.path,
            displayPath: destination.path,
            expectedSource: IntegrationFilesystem.fingerprint(source),
            expectedDestination: IntegrationFilesystem.fingerprint(destination),
            expectedDisplayPath: IntegrationFilesystem.fingerprint(destination),
            bakedCLI: nil
        )
    }
}

// MARK: - fixture helpers

/// A `copyTree` injection for the arm-pin tests: it records the staging copy and then performs it.
/// Delegating is not optional — a recorder that swallowed the copy would leave the staging slot absent
/// and the transaction's following `moveItem` would fail for an unrelated reason, so the test would
/// pass or fail for the wrong cause.
private final class CopyRecorder {
    private(set) var calls: [(from: String, to: String)] = []

    func copy(_ from: URL, _ to: URL) throws {
        calls.append((from.path, to.path))
        try IntegrationFilesystem.installCopy(from: from, to: to)
    }
}

/// Teardown for the shared `Fixture` root. `Fixture.deinit`'s `try? removeItem` is not enough here: these
/// fixtures deliberately create 0500 directories, whose children an unprivileged user cannot delete, so
/// re-open every directory on the way down before deleting.
private func destroy(_ url: URL) {
    let fm = FileManager.default
    if let attributes = try? fm.attributesOfItem(atPath: url.path),
       attributes[.type] as? FileAttributeType == .typeDirectory {
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.path)
        for child in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] {
            destroy(url.appendingPathComponent(child))
        }
    }
    try? fm.removeItem(at: url)
}

private func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

private func chmod(_ url: URL, _ mode: Int) throws {
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)],
                                          ofItemAtPath: url.path)
}

private func entries(of url: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
}

private func contents(of url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

private func mode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o7777
}

/// Throws when the copy produced anything other than a symlink — the regression these assertions guard
/// against.
private func linkTarget(of url: URL) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
}
