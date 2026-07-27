import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux keymap compatibility")
struct LinuxKeymapTests {
    @Test("dropping a reserved override does not restore a shadowed Linux default")
    func reservedOverrideRestoresDefault() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        map ctrl+, new_session
        map ctrl+shift+t toggle_split
        """.write(to: directory.appendingPathComponent("keymap.conf"), atomically: true, encoding: .utf8)

        let loaded = loadLinuxKeymap(configDirectory: directory)

        #expect(loaded.keymap.builtinOverrides[.newSession] == nil)
        #expect(loaded.keymap.builtinOverrides[.toggleSplit] == nil)
        #expect(loaded.diagnostics.contains { $0.message.contains("new_session map skipped") })
        #expect(loaded.diagnostics.contains { $0.message.contains("toggle_split map skipped") })
    }

    @Test("restoring Open Directory cannot collide with another Linux default")
    func reservedOpenDirectoryRestoresUniqueDefault() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "map ctrl+, open_directory\n".write(
            to: directory.appendingPathComponent("keymap.conf"), atomically: true, encoding: .utf8)

        let loaded = loadLinuxKeymap(configDirectory: directory)
        let openDirectory = Chord(mods: [.control, .shift], key: "o")

        #expect(loaded.keymap.builtinOverrides[.openDirectory] == nil)
        #expect(BuiltinAction.openDirectory.linuxDefaultChord == openDirectory)
        #expect(BuiltinAction.customCommandPalette.linuxDefaultChord == nil)
        #expect(loaded.diagnostics.contains { $0.message.contains("open_directory map skipped") })
        let activeDefaults = BuiltinAction.allCases.compactMap(\.linuxDefaultChord)
        #expect(Set(activeDefaults).count == activeDefaults.count)
    }

    /// The AT-SPI suite seeds this exact keymap and then asserts one palette row renders
    /// `Chorded Demo | custom | ctrl+shift+e`. That only holds if Linux validation leaves the chord
    /// alone, so pin the whole keymap→row path here — the GUI gate cannot run on every box.
    @Test("a chorded custom command survives Linux validation and reaches its palette row verbatim")
    func chordedCustomCommandReachesItsRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        command "Launch Failure" true
        command "Chorded Demo" ctrl+shift+e true
        """.write(to: directory.appendingPathComponent("keymap.conf"), atomically: true, encoding: .utf8)

        let loaded = loadLinuxKeymap(configDirectory: directory)
        let rows = loaded.keymap.commands.map(LinuxPaletteRow.custom)

        #expect(rows == [LinuxPaletteRow(title: "Launch Failure", badge: "custom"),
                         LinuxPaletteRow(title: "Chorded Demo", shortcut: "ctrl+shift+e", badge: "custom")])
        #expect(!loaded.diagnostics.contains { $0.message.contains("Chorded Demo") })
    }
}
