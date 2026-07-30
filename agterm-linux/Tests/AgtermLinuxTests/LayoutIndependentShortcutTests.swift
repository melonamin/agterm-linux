import CGtk
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Layout-independent Linux shortcuts")
struct LayoutIndependentShortcutTests {
    private let control: UInt32 = 1 << 2
    private let shift: UInt32 = 1 << 0

    private func keyval(_ scalar: Unicode.Scalar) -> UInt32 {
        gdk_unicode_to_keyval(scalar.value)
    }

    private func context(
        group: Int = 0,
        isASCIICapable: Bool,
        entries: [ShortcutKeyMapEntry]
    ) -> ShortcutKeyContext {
        ShortcutKeyContext(
            activeGroup: group,
            layoutIsASCIICapable: isASCIICapable,
            entries: entries
        )
    }

    @Test("Russian layout resolves the physical J position")
    func russianLayoutUsesPhysicalPosition() throws {
        let mapping = context(group: 1, isASCIICapable: false, entries: [
            .init(group: 0, level: 0, keyval: keyval("j")),
            .init(group: 1, level: 0, keyval: keyval("о")),
        ])

        let result = try #require(shortcutChord(
            fromKeyval: keyval("О"), keycode: 44, state: control | shift, context: mapping))

        #expect(result == Chord(mods: [.control, .shift], key: "j"))
    }

    @Test("Russian-only configuration still resolves physical positions")
    func soleRussianLayoutUsesPhysicalPosition() throws {
        let mapping = context(isASCIICapable: false, entries: [
            .init(group: 0, level: 0, keyval: keyval("о")),
        ])

        let result = try #require(shortcutChord(
            fromKeyval: keyval("о"), keycode: 44, state: control, context: mapping))

        #expect(result == Chord(mods: [.control], key: "j"))
    }

    @Test("Greek punctuation keys resolve by physical position")
    func greekPunctuationUsesPhysicalPosition() throws {
        let mapping = context(isASCIICapable: false, entries: [
            .init(group: 0, level: 0, keyval: keyval(";")),
        ])

        let result = try #require(shortcutChord(
            fromKeyval: keyval(";"), keycode: 24, state: control, context: mapping))

        #expect(result == Chord(mods: [.control], key: "q"))
    }

    @Test("Hebrew punctuation keys resolve by physical position")
    func hebrewPunctuationUsesPhysicalPosition() throws {
        let mapping = context(isASCIICapable: false, entries: [
            .init(group: 0, level: 0, keyval: keyval("/")),
        ])

        let result = try #require(shortcutChord(
            fromKeyval: keyval("/"), keycode: 24, state: control, context: mapping))

        #expect(result == Chord(mods: [.control], key: "q"))
    }

    @Test("Dvorak keeps the character produced by its ASCII-capable layout")
    func dvorakKeepsSemanticKey() throws {
        let mapping = context(isASCIICapable: true, entries: [
            .init(group: 0, level: 0, keyval: keyval("j")),
        ])

        let result = try #require(shortcutChord(
            fromKeyval: keyval("j"), keycode: 54, state: control, context: mapping))

        #expect(result == Chord(mods: [.control], key: "j"))
    }

    @Test("ASCII-capable layouts use the active unshifted punctuation")
    func shiftedPunctuationUsesActiveBase() throws {
        let mapping = context(isASCIICapable: true, entries: [
            .init(group: 0, level: 0, keyval: keyval("&")),
            .init(group: 0, level: 1, keyval: keyval("1")),
        ])

        let result = try #require(shortcutChord(
            fromKeyval: keyval("1"), keycode: 10, state: shift, context: mapping))

        #expect(result == Chord(mods: [.shift], key: "&"))
    }

    @Test("AltGr symbols use the layout's unmodified base")
    func altGrUsesUnmodifiedBase() throws {
        let mapping = context(isASCIICapable: true, entries: [
            .init(group: 0, level: 0, keyval: keyval("e")),
            .init(group: 0, level: 2, keyval: keyval("€")),
        ])

        let result = try #require(shortcutChord(
            fromKeyval: keyval("€"), keycode: 26, state: control, context: mapping))

        #expect(result == Chord(mods: [.control], key: "e"))
    }

    @Test("GTK ISO Left Tab and keypad Tab normalize to tab")
    func gtkTabVariantsNormalize() throws {
        let iso = try #require(shortcutChord(
            fromKeyval: 0xFE20, keycode: 23, state: control | shift, context: nil))
        let keypad = try #require(shortcutChord(
            fromKeyval: 0xFF89, keycode: 90, state: control, context: nil))

        #expect(iso == Chord(mods: [.control, .shift], key: "tab"))
        #expect(keypad == Chord(mods: [.control], key: "tab"))
    }

    @Test("fixed shortcuts require their exact modifiers")
    func fixedShortcutsUseExactModifiers() {
        #expect(linuxFixedShortcut(for: Chord(mods: [.control], key: ",")) == .preferences)
        #expect(linuxFixedShortcut(for: Chord(mods: [.control, .option], key: ",")) == nil)
        #expect(linuxFixedShortcut(for: Chord(mods: [.control, .shift], key: "=")) == .fontIncrease)
        #expect(linuxFixedShortcut(
            for: Chord(mods: [.control, .shift, .option], key: "=")) == nil)
        #expect(linuxFixedShortcut(for: Chord(mods: [.control, .shift], key: "tab"))
            == .sessionSwitch(reverse: true))
        #expect(linuxFixedShortcut(for: Chord(mods: [.control], key: "+")) == .fontIncrease)
        #expect(linuxFixedShortcut(for: Chord(mods: [.control], key: "_")) == .fontDecrease)
        #expect(linuxFixedShortcut(for: Chord(mods: [.control], key: "1"))
            == .focusPane(left: true))
    }

    @Test("keymap lookup stays off the plain typing path")
    func keymapLookupIsLazy() {
        #expect(!needsShortcutKeyContext(state: 0, leaderArmed: false))
        #expect(needsShortcutKeyContext(state: shift, leaderArmed: false))
        #expect(needsShortcutKeyContext(state: 0, leaderArmed: true))
    }

    @Test("non-ASCII layouts resolve every key by physical position")
    func nonASCIILayoutUsesPhysicalPosition() {
        #expect(linuxShortcutKey(keycode: 24, produced: ";", layoutIsASCIICapable: false) == "q")
        #expect(linuxShortcutKey(keycode: 24, produced: "/", layoutIsASCIICapable: false) == "q")
        #expect(linuxShortcutKey(keycode: 44, produced: "о", layoutIsASCIICapable: false) == "j")
    }

    @Test("ASCII-capable layouts preserve their produced character")
    func ASCIILayoutStaysSemantic() {
        #expect(linuxShortcutKey(keycode: 54, produced: "j", layoutIsASCIICapable: true) == "j")
        #expect(linuxShortcutKey(keycode: 24, produced: "é", layoutIsASCIICapable: true) == "é")
    }

    @Test("non-ASCII layouts reject the ISO section key")
    func nonASCIILayoutRejectsISOSectionKey() {
        #expect(linuxShortcutKey(keycode: 94, produced: "\\", layoutIsASCIICapable: false) == nil)
    }

    @Test("layout capability requires the complete ASCII alphabet")
    func layoutCapabilityUsesFullAlphabet() {
        let alphabet = (Unicode.Scalar("a").value...Unicode.Scalar("z").value).compactMap(Unicode.Scalar.init)
        let keycodes: [UInt32] = Array(24...33) + Array(38...46) + Array(52...58)
        let mapping = Dictionary(uniqueKeysWithValues: zip(keycodes, alphabet))
        #expect(isASCIICapableShortcutLayout(activeGroup: 0) { keycode in
            mapping[keycode].map { [.init(group: 0, level: 0, keyval: keyval($0))] } ?? []
        })
        #expect(!isASCIICapableShortcutLayout(activeGroup: 0) { _ in
            [.init(group: 0, level: 0, keyval: keyval("α"))]
        })
    }

    @Test("Dvorak is ASCII-capable when letters occupy ANSI punctuation positions")
    func dvorakLayoutCapabilityScansANSIPositions() {
        let rows: [(ClosedRange<UInt32>, String)] = [
            (27...33, "pyfgcrl"),
            (38...47, "aoeuidhtns"),
            (53...61, "qjkxbmwvz"),
        ]
        let mapping = Dictionary(uniqueKeysWithValues: rows.flatMap { keycodes, letters in
            zip(keycodes, letters.unicodeScalars).map { ($0, $1) }
        })

        #expect(isASCIICapableShortcutLayout(activeGroup: 0) { keycode in
            mapping[keycode].map { [.init(group: 0, level: 0, keyval: keyval($0))] } ?? []
        })
    }

    @Test("Hebrew Latin shift levels do not make the layout ASCII-capable")
    func hebrewShiftLevelsStayPhysical() {
        let alphabet = (Unicode.Scalar("a").value...Unicode.Scalar("z").value).compactMap(Unicode.Scalar.init)
        let keycodes: [UInt32] = Array(24...33) + Array(38...46) + Array(52...58)
        let latinByKeycode = Dictionary(uniqueKeysWithValues: zip(keycodes, alphabet))

        #expect(!isASCIICapableShortcutLayout(activeGroup: 0) { keycode in
            guard let latin = latinByKeycode[keycode] else { return [] }
            return [
                .init(group: 0, level: 0, keyval: keyval("ש")),
                .init(group: 0, level: 1, keyval: keyval(latin)),
            ]
        })
    }
}
