import Foundation
import Testing
@testable import AgtermLinux

@Suite("Linux HUD body storage")
struct LinuxHudBodyStorageTests {
    @Test("new and replacement bodies are owner-only")
    func ownerOnly() throws {
        let path = try #require(LinuxHudBodyStorage.path(for: UUID()))
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(LinuxHudBodyStorage.write(Data("first".utf8), to: path))
        #expect(try mode(path) == 0o600)
        #expect(LinuxHudBodyStorage.write(Data("replacement".utf8), to: path))
        #expect(try mode(path) == 0o600)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("replacement".utf8))
    }

    private func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try #require(attributes[.posixPermissions] as? Int) & 0o777
    }
}
