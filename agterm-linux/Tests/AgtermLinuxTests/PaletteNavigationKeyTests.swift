import CGtk
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Palette and picker Ctrl-J/K navigation")
struct PaletteNavigationKeyTests {
    private let control: UInt32 = 1 << 2
    private let shift: UInt32 = 1 << 0
    private let down: UInt32 = 0xFF54
    private let up: UInt32 = 0xFF52
    private let escape: UInt32 = 0xFF1B

    private func keyval(_ scalar: Unicode.Scalar) -> UInt32 {
        gdk_unicode_to_keyval(scalar.value)
    }

    private func navigation(
        _ pressed: Unicode.Scalar,
        keycode: UInt32,
        group: Int = 0,
        isASCIICapable: Bool,
        entries: [(scalar: Unicode.Scalar, group: Int)]
    ) -> UInt32? {
        let mapping = ShortcutKeyContext(
            activeGroup: group,
            layoutIsASCIICapable: isASCIICapable,
            entries: entries.map { .init(group: $0.group, level: 0, keyval: keyval($0.scalar)) }
        )
        return paletteNavigation(chord: shortcutChord(
            fromKeyval: keyval(pressed), keycode: keycode, state: control, context: mapping))
    }

    @Test("US layout maps ctrl+j and ctrl+k to Down and Up")
    func usLayout() {
        #expect(navigation("j", keycode: 44, isASCIICapable: true, entries: [("j", 0)]) == down)
        #expect(navigation("k", keycode: 45, isASCIICapable: true, entries: [("k", 0)]) == up)
    }

    @Test("Russian-only layout resolves the physical J and K positions")
    func russianOnlyLayout() {
        #expect(navigation("о", keycode: 44, isASCIICapable: false, entries: [("о", 0)]) == down)
        #expect(navigation("л", keycode: 45, isASCIICapable: false, entries: [("л", 0)]) == up)
    }

    @Test("Russian as the active second group resolves the physical J and K positions")
    func russianSecondGroup() {
        #expect(navigation("о", keycode: 44, group: 1, isASCIICapable: false, entries: [("j", 0), ("о", 1)]) == down)
        #expect(navigation("л", keycode: 45, group: 1, isASCIICapable: false, entries: [("k", 0), ("л", 1)]) == up)
    }

    @Test("Dvorak navigates on its semantic J and K, not the QWERTY positions")
    func dvorakSemanticKeys() {
        #expect(navigation("j", keycode: 54, isASCIICapable: true, entries: [("j", 0)]) == down)
        #expect(navigation("k", keycode: 55, isASCIICapable: true, entries: [("k", 0)]) == up)
        #expect(navigation("h", keycode: 44, isASCIICapable: true, entries: [("h", 0)]) == nil)
        #expect(navigation("t", keycode: 45, isASCIICapable: true, entries: [("t", 0)]) == nil)
    }

    @Test("Colemak navigates on its semantic J and K, not the QWERTY positions")
    func colemakSemanticKeys() {
        #expect(navigation("j", keycode: 29, isASCIICapable: true, entries: [("j", 0)]) == down)
        #expect(navigation("k", keycode: 57, isASCIICapable: true, entries: [("k", 0)]) == up)
        #expect(navigation("n", keycode: 44, isASCIICapable: true, entries: [("n", 0)]) == nil)
        #expect(navigation("e", keycode: 45, isASCIICapable: true, entries: [("e", 0)]) == nil)
    }

    @Test("without a key context the keyval decides")
    func nilContextFallsBackToKeyval() {
        #expect(paletteNavigationKeyval(keyval: keyval("j"), keycode: 44, state: control, event: nil) == down)
        #expect(paletteNavigationKeyval(keyval: keyval("k"), keycode: 45, state: control, event: nil) == up)
        #expect(paletteNavigationKeyval(keyval: keyval("x"), keycode: 44, state: control, event: nil) == keyval("x"))
    }

    @Test("plain j and k type into the search entry")
    func plainKeysPassThrough() {
        #expect(paletteNavigationKeyval(keyval: keyval("j"), keycode: 44, state: 0, event: nil) == keyval("j"))
        #expect(paletteNavigationKeyval(keyval: keyval("k"), keycode: 45, state: 0, event: nil) == keyval("k"))
    }

    @Test("extra modifiers are not navigation")
    func exactModifiers() {
        let upperJ = keyval("J")
        #expect(paletteNavigationKeyval(keyval: upperJ, keycode: 44, state: control | shift, event: nil) == upperJ)
        #expect(paletteNavigation(chord: Chord(mods: [.control, .shift], key: "j")) == nil)
        #expect(paletteNavigation(chord: Chord(mods: [.shift], key: "j")) == nil)
    }

    @Test("other keys and a missing chord map to nothing")
    func nonNavigationChords() {
        #expect(paletteNavigation(chord: Chord(mods: [.control], key: "h")) == nil)
        #expect(paletteNavigation(chord: nil) == nil)
    }

    @Test("arrows and Escape pass through unchanged")
    func arrowsAndEscapePassThrough() {
        for key in [up, down, escape] {
            #expect(paletteNavigationKeyval(keyval: key, keycode: 0, state: 0, event: nil) == key)
            #expect(paletteNavigationKeyval(keyval: key, keycode: 0, state: control, event: nil) == key)
        }
    }
}
