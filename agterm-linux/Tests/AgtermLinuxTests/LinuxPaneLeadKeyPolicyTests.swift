import Foundation
import Testing
@testable import agtermCore
@testable import AgtermLinux

@Suite("Pane lead key policy")
@MainActor
struct LinuxPaneLeadKeyPolicyTests {
    nonisolated static let keyA: (keyval: UInt32, keycode: UInt32) = (0x61, 38)
    nonisolated static let keyB: (keyval: UInt32, keycode: UInt32) = (0x62, 56)
    nonisolated static let tab: (keyval: UInt32, keycode: UInt32) = (0xFF09, 23)
    nonisolated static let digit1: (keyval: UInt32, keycode: UInt32) = (0x31, 10)
    nonisolated static let controlL: (keyval: UInt32, keycode: UInt32) = (0xFFE3, 37)
    nonisolated static let superL: (keyval: UInt32, keycode: UInt32) = (0xFFEB, 133)

    let book = ZmxLeadBook()
    let policy: LinuxPaneLeadKeyPolicy
    let pane = UUID()

    init() {
        policy = LinuxPaneLeadKeyPolicy(book: book)
    }

    private func attach(role: ZmxLeadRole?, reattaching: Bool = false) {
        let attachment = ZmxLeadAttachment(claim: reattaching)
        book.begin(attachment, pane: pane, reattaching: reattaching)
        if let role, let notice = ZmxLeadNotice(title: "zmx-role;\(attachment.nonce):\(role.rawValue):1") {
            _ = book.apply(notice, pane: pane)
        }
    }

    private func press(_ key: (keyval: UInt32, keycode: UInt32), state: UInt32 = 0) -> LinuxPaneLeadKeyPolicy.Press {
        policy.press(keyval: key.keyval, keycode: key.keycode, state: state, pane: pane)
    }

    private func cover(_ key: (keyval: UInt32, keycode: UInt32), state: UInt32 = 0,
                       keymap: Bool) -> LinuxPaneLeadKeyPolicy.Press {
        policy.route(keyval: key.keyval, keycode: key.keycode, state: state, pane: pane) { keymap }
    }

    @Test(arguments: [
        (tab, ModifierKeyMods.controlBit),
        (digit1, ModifierKeyMods.controlBit),
        (keyA, ModifierKeyMods.controlBit),
        (keyB, UInt32(0)),
    ])
    func keymapChordOnCoveredFollowerStaysTheKeymaps(key: (keyval: UInt32, keycode: UInt32), state: UInt32) {
        attach(role: .follower)
        #expect(cover(key, state: state, keymap: true) == .keymap)
        #expect(policy.takeoverKeycode == nil)
    }

    @Test func keymapRunsBeforeARecordedTakeoverKey() {
        attach(role: .follower)
        var consulted = false
        _ = policy.route(keyval: Self.keyA.keyval, keycode: Self.keyA.keycode, state: 0, pane: pane) {
            consulted = true
            return false
        }
        #expect(consulted)
        #expect(cover(Self.keyA, keymap: true) == .keymap)
        #expect(policy.takeoverKeycode == Self.keyA.keycode)
    }

    @Test func superAndModifierOnlyNeverTakeTheLead() {
        attach(role: .follower)
        #expect(press(Self.keyA, state: ModifierKeyMods.superBit) == .consume)
        #expect(press(Self.superL) == .consume)
        #expect(press(Self.controlL) == .consume)
        #expect(policy.takeoverKeycode == nil)
    }

    @Test func takeoverKeyTakesTheLeadOnceAndOtherKeysAreConsumed() {
        attach(role: .follower)
        #expect(press(Self.keyA) == .takeover)
        #expect(press(Self.keyA) == .consume)
        #expect(press(Self.keyB) == .consume)
        #expect(policy.takeoverKeycode == Self.keyA.keycode)
    }

    @Test(arguments: [ZmxLeadRole?.none, .leader])
    func uncoveredPaneKeysPass(role: ZmxLeadRole?) {
        attach(role: role)
        #expect(press(Self.keyA) == .pass)
        #expect(press(Self.controlL) == .pass)
        #expect(policy.takeoverKeycode == nil)
    }

    @Test func takeoverRepeatsAreConsumedAcrossTheReattachUntilRelease() {
        attach(role: .follower)
        #expect(press(Self.keyA) == .takeover)
        attach(role: nil, reattaching: true)
        #expect(press(Self.keyA) == .consume)
        #expect(press(Self.keyB) == .consume)
        attach(role: .leader)
        #expect(press(Self.keyA) == .consume)
        #expect(press(Self.keyB) == .pass)
        #expect(policy.release(keycode: Self.keyA.keycode))
        #expect(press(Self.keyA) == .pass)
        #expect(policy.takeoverKeycode == nil)
    }

    @Test func onlyTheTakeoverReleaseClearsIt() {
        attach(role: .follower)
        #expect(press(Self.keyA) == .takeover)
        #expect(!policy.release(keycode: Self.keyB.keycode))
        #expect(!policy.release(keycode: Self.controlL.keycode))
        #expect(policy.takeoverKeycode == Self.keyA.keycode)
        #expect(policy.release(keycode: Self.keyA.keycode))
        #expect(!policy.release(keycode: Self.keyA.keycode))
    }

    @Test func surfaceChangeDoesNotClearTheTakeover() {
        attach(role: .follower)
        #expect(press(Self.keyA) == .takeover)
        book.forget(pane: pane)
        #expect(policy.press(keyval: Self.keyA.keyval, keycode: Self.keyA.keycode, state: 0, pane: UUID()) == .consume)
        #expect(policy.takeoverKeycode == Self.keyA.keycode)
    }

    @Test func pressAfterASeenReleaseIsGenuine() {
        attach(role: .follower)
        #expect(press(Self.keyA) == .takeover)
        #expect(policy.release(keycode: Self.keyA.keycode))
        attach(role: .follower)
        #expect(press(Self.keyA) == .takeover)
    }

    @Test func coverPressRecordsTheKeyLikeASurfacePress() {
        attach(role: .unowned)
        #expect(cover(Self.keyA, keymap: false) == .takeover)
        #expect(policy.takeoverKeycode == Self.keyA.keycode)
        attach(role: nil, reattaching: true)
        #expect(press(Self.keyA) == .consume)
        #expect(cover(Self.keyA, keymap: false) == .consume)
    }

    private func release(_ key: (keyval: UInt32, keycode: UInt32)) -> Bool {
        policy.release(keyval: key.keyval, keycode: key.keycode, pane: pane)
    }

    @Test(arguments: [ZmxLeadRole?.none, .leader])
    func uncoveredPaneForwardsModifierReleases(role: ZmxLeadRole?) {
        attach(role: role)
        #expect(release(Self.controlL))
        #expect(release(Self.superL))
        #expect(!release(Self.keyA))
    }

    @Test func coveredPaneDropsTheModifierReleasesItsPressesConsumed() {
        attach(role: .follower)
        #expect(press(Self.controlL) == .consume)
        #expect(!release(Self.controlL))
        #expect(press(Self.superL) == .consume)
        #expect(!release(Self.superL))
    }

    @Test func nonModifierReleaseEndsTheTakeover() {
        attach(role: .follower)
        #expect(press(Self.keyA) == .takeover)
        #expect(!release(Self.keyA))
        #expect(policy.takeoverKeycode == nil)
    }

    @Test(arguments: [(true, false, true), (false, true, true), (true, true, true), (false, false, false)])
    func replacementTakesFocusFromTheSurfaceOrItsCover(surface: Bool, cover: Bool, expected: Bool) {
        #expect(LinuxPaneLeadKeyPolicy.replacementTakesFocus(surfaceFocused: surface, coverFocused: cover) == expected)
    }
}
