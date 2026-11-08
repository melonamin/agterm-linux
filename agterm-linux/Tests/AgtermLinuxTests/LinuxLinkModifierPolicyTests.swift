import CGtk
import Testing
@testable import AgtermLinux

@Suite("Linux file reveal pointer modifiers")
struct LinuxLinkModifierPolicyTests {
    private let reveal = ghostty_input_mods_e(rawValue: GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SHIFT.rawValue)

    @Test("reveal uses Ctrl link matching outside a mouse-reporting TUI")
    func revealMatchesLinks() {
        #expect(LinuxLinkModifierPolicy.reveals(reveal, mouseCaptured: false))
        #expect(LinuxLinkModifierPolicy.forEngine(reveal, mouseCaptured: false) == GHOSTTY_MODS_CTRL)
    }

    @Test("a mouse-reporting TUI retains Ctrl+Shift")
    func capturedModifiersStayIntact() {
        #expect(!LinuxLinkModifierPolicy.reveals(reveal, mouseCaptured: true))
        #expect(LinuxLinkModifierPolicy.forEngine(reveal, mouseCaptured: true) == reveal)
    }

    @Test("other pointer chords keep their original meaning", arguments: [
        GHOSTTY_MODS_NONE.rawValue, GHOSTTY_MODS_CTRL.rawValue, GHOSTTY_MODS_SHIFT.rawValue,
        GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_ALT.rawValue,
        GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_SUPER.rawValue
    ])
    func otherModifiersStayIntact(_ raw: UInt32) {
        let mods = ghostty_input_mods_e(rawValue: raw)
        for captured in [false, true] {
            #expect(!LinuxLinkModifierPolicy.reveals(mods, mouseCaptured: captured))
            #expect(LinuxLinkModifierPolicy.forEngine(mods, mouseCaptured: captured) == mods)
        }
    }
}
