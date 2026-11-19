#if os(Linux)
import Foundation
import Testing
@testable import agtermCore
@testable import agtermctlKit

struct LinuxServerInstallerTests {
    final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("server-install-\(UUID().uuidString)")
        var phases: [String] = []

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "0.43.0\n".write(to: directory.appendingPathComponent("UPSTREAM_VERSION"), atomically: true, encoding: .utf8)
            let hash = "a4d451ec23463726f72c43d64c710968f6b602cd653b4de8adee1b556240a829"
            try "\(hash)  agterm-server-0.43.0-linux-x86_64.tar.gz\n".write(
                to: directory.appendingPathComponent(ServerInstall.checksumFile), atomically: true, encoding: .utf8)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        var effects: ServerInstaller.Effects {
            .init(bundle: { self.directory }, capture: { _ in
                self.phases.append("probe")
                return (.exited(0), Data("x86_64\n".utf8))
            }, run: { _, input in
                switch input {
                case .file(let path):
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                    #expect(bytes == Data("release".utf8))
                    self.phases.append("unpack")
                case .nothing: self.phases.append("install")
                case .data: Issue.record("installer should pass a private snapshot file")
                }
                return .exited(0)
            }, download: { _, _, _ in Issue.record("--from must not download") }, print: { _ in })
        }
    }

    @Test func linuxMetadataAndHashPermitOnlyThePinnedArchive() throws {
        let fixture = try Fixture()
        let archive = fixture.directory.appendingPathComponent("server.tar.gz")
        try Data("release".utf8).write(to: archive)
        #expect(try ServerInstaller(effects: fixture.effects).install(.init(destination: "box"), source: archive.path) == 0)
        #expect(fixture.phases == ["probe", "unpack", "install"])
    }

    @Test func tamperedArchiveNeverReachesTheRemoteUnpacker() throws {
        let fixture = try Fixture()
        let archive = fixture.directory.appendingPathComponent("server.tar.gz")
        try Data("tampered".utf8).write(to: archive)
        #expect(throws: SocketClientError.self) {
            try ServerInstaller(effects: fixture.effects).install(.init(destination: "box"), source: archive.path)
        }
        #expect(fixture.phases == ["probe"])
    }
}
#endif
