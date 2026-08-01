import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux keymap compatibility")
struct LinuxKeymapTests {
    @Test("dropping a reserved override does not restore a shadowed Linux default")
    func reservedOverrideRestoresDefault() throws {
        let loaded = try loadKeymap("""
        map ctrl+, new_session
        map ctrl+shift+t toggle_split
        """)

        #expect(loaded.keymap.builtinOverrides[.newSession] == nil)
        #expect(loaded.keymap.builtinOverrides[.toggleSplit] == nil)
        #expect(loaded.diagnostics.contains { $0.message.contains("new_session map skipped") })
        #expect(loaded.diagnostics.contains { $0.message.contains("toggle_split map skipped") })
    }

    @Test("restoring Open Directory cannot collide with another Linux default")
    func reservedOpenDirectoryRestoresUniqueDefault() throws {
        let loaded = try loadKeymap("map ctrl+, open_directory\n")
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
        let loaded = try loadKeymap("""
        command "Launch Failure" true
        command "Chorded Demo" ctrl+shift+e true
        """)
        let rows = loaded.keymap.commands.map(LinuxPaletteRow.custom)

        #expect(rows == [LinuxPaletteRow(title: "Launch Failure", badge: "custom"),
                         LinuxPaletteRow(title: "Chorded Demo", shortcut: "ctrl+shift+e", badge: "custom")])
        #expect(!loaded.diagnostics.contains { $0.message.contains("Chorded Demo") })
    }

    /// `check_keymap_reload_fanout` APPENDS these two commands to the seeded keymap and then asserts the
    /// exact palette rows `Late Demo | custom | ctrl+shift+y` and `Palette Demo | custom` in both windows.
    /// Same reasoning as the test above: pin the appended keymap→row mapping host-free, so a future
    /// reserved-chord or default-table change fails with a named unit failure instead of an opaque AT-SPI
    /// timeout. `ctrl+shift+y` is bound by nothing (no Linux default, no reserved chord), and the
    /// chord-less `Palette Demo` must render with an EMPTY shortcut column.
    @Test("the appended fan-out commands reach their palette rows verbatim")
    func appendedFanoutCommandsReachTheirRows() throws {
        let loaded = try loadKeymap(atspiFanoutKeymap)
        let rows = loaded.keymap.commands.map(LinuxPaletteRow.custom)

        #expect(rows.contains(LinuxPaletteRow(title: "Late Demo", shortcut: "ctrl+shift+y", badge: "custom")))
        #expect(rows.contains(LinuxPaletteRow(title: "Palette Demo", badge: "custom")))
        #expect(loaded.diagnostics.isEmpty)
    }

    /// The ONE malformed line `check_keymap_error_banner` appends to prove the error banner still reaches
    /// a user after the toast became a caller obligation. The AT-SPI leg waits for the exact text below,
    /// so the count that produces it is pinned here rather than guessed there.
    ///
    /// What is pinned is the malformed line's DIAGNOSTIC COUNT, not the fixture it sits in: over there the
    /// line is appended to the RESTORED 4-command keymap `verify_custom_command_failures` seeded (the
    /// fan-out check restores it before this one runs), while here it is appended to the 6-command
    /// `atspiFanoutKeymap`. Both yield exactly 1, because the two extra fan-out commands parse cleanly —
    /// which the test above asserts via `loaded.diagnostics.isEmpty`.
    @Test("the error-banner check's malformed line yields exactly the toast the AT-SPI leg waits for")
    func malformedErrorBannerLineYieldsOneErrorToast() throws {
        let loaded = try loadKeymap(atspiFanoutKeymap + "map ctrl+, new_session\n")

        #expect(loaded.diagnostics.count == 1)
        #expect(keymapReloadToast(count: loaded.diagnostics.count) == "keymap.conf: 1 error — bad line ignored")
    }

    /// An icon-only GtkButton exposes its tooltip as its AT-SPI accessible NAME, and the e2e scenarios
    /// look buttons up by exact text — so these seven strings are contract. Pinning every one here means
    /// a changed `linuxDefaultChord` fails the build instead of silently renaming a widget the harness
    /// depends on.
    @Test("every title-bar tooltip renders its exact accessible name")
    func chromeTooltipsRenderExactNames() {
        #expect(LinuxChromeTooltip.text("Quick Terminal", .quickTerminal) == "Quick Terminal (Ctrl+`)")
        #expect(LinuxChromeTooltip.text("Dashboard", .dashboard) == "Dashboard (Ctrl+Shift+M)")
        #expect(LinuxChromeTooltip.text("Toggle Split", .toggleSplit) == "Toggle Split (Ctrl+Shift+D)")
        #expect(LinuxChromeTooltip.text("Scratch Terminal", .toggleScratch) == "Scratch Terminal (Ctrl+Shift+J)")
        #expect(LinuxChromeTooltip.text("Show sessions that need attention", .showAttention)
                == "Show sessions that need attention (Ctrl+Shift+I)")
        // Ctrl+Tab is a reserved monitor chord, so Recent Sessions goes through the `shortcut:` overload.
        #expect(LinuxChromeTooltip.text("Recent Sessions", shortcut: "Ctrl+Tab") == "Recent Sessions (Ctrl+Tab)")
        // The one string that CHANGES: the button shipped a stale (Ctrl+Shift+B) hardcoded literal.
        #expect(LinuxChromeTooltip.text("Toggle Sidebar", .toggleSidebar) == "Toggle Sidebar (Ctrl+Shift+S)")
    }

    @Test("chord labels name Linux modifiers, uppercase single keys, and capitalize named keys")
    func chromeTooltipLabelsRenderReachableShapes() {
        #expect(LinuxChromeTooltip.label(Chord(mods: [.control, .shift], key: "s")) == "Ctrl+Shift+S")
        #expect(LinuxChromeTooltip.label(Chord(mods: [.control], key: "`")) == "Ctrl+`")
        // Modifier order mirrors Chord.displayString (ctrl+cmd+opt+shift); on Linux .command is the Super
        // key and .option is Alt. Neither is reachable from today's seven callers, but the switch is total.
        #expect(LinuxChromeTooltip.label(Chord(mods: [.control, .command, .option, .shift], key: "p"))
                == "Ctrl+Super+Alt+Shift+P")
        // A named key CAPITALIZES so a future named default agrees with the hand-written `Ctrl+Tab`
        // literal the Recent Sessions button renders through the `shortcut:` overload.
        #expect(LinuxChromeTooltip.label(Chord(mods: [.control], key: "space")) == "Ctrl+Space")
        #expect(LinuxChromeTooltip.label(Chord(mods: [.control], key: "tab")) == "Ctrl+Tab")
    }

    @Test("an action with no Linux default chord renders a bare tooltip")
    func chromeTooltipFallsBackToBareTitle() {
        #expect(BuiltinAction.customCommandPalette.linuxDefaultChord == nil)
        #expect(LinuxChromeTooltip.text("Custom Commands", .customCommandPalette) == "Custom Commands")
    }

    /// The keymap `verify_custom_command_failures` seeds, plus the two lines the fan-out check appends.
    private var atspiFanoutKeymap: String {
        """
        command "Launch Failure" true
        command "Exit Failure" exit 23
        command "Slow Failure" sleep 1; exit 29
        command "Chorded Demo" ctrl+shift+e true
        command "Late Demo" ctrl+shift+y true
        command "Palette Demo" true

        """
    }

    /// Parse `contents` as a `keymap.conf` in a throwaway config directory — every test here goes through
    /// this, so a fixture reads as its keymap text rather than as temp-directory bookkeeping.
    private func loadKeymap(_ contents: String) throws -> (keymap: Keymap, diagnostics: [KeymapDiagnostic]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: directory.appendingPathComponent("keymap.conf"), atomically: true, encoding: .utf8)
        return loadLinuxKeymap(configDirectory: directory)
    }
}

/// The host-free half of the app-wide reload seam. The seam itself fans out over live GTK controllers and
/// cannot be constructed here, so the one piece of policy it carries — the wording, and the decision to
/// stay silent on a clean load — is a free function and is pinned here instead.
@Suite("Linux keymap reload toast")
struct LinuxKeymapReloadToastTests {
    /// Silence on success is the contract that keeps `agtermctl keymap reload` (a scripted surface) from
    /// bannering the frontmost window on every invocation, and startup from bannering every window open.
    @Test("a clean load stays silent")
    func cleanLoadIsSilent() {
        #expect(keymapReloadToast(count: 0) == nil)
    }

    @Test("one diagnostic names the error count in the singular")
    func singularError() {
        #expect(keymapReloadToast(count: 1) == "keymap.conf: 1 error — bad line ignored")
    }

    @Test("several diagnostics name the error count in the plural")
    func pluralErrors() {
        #expect(keymapReloadToast(count: 2) == "keymap.conf: 2 errors — bad lines ignored")
    }
}
