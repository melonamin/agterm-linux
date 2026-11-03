import Foundation
import Testing
@testable import agtermCore

struct QuitReasonTests {
    @Test(arguments: ["shut", "rest", "rlgo"])
    func systemQuitSkipsConfirmation(reason: String) {
        #expect(QuitReason.isSystemQuit(reasonTypeCode: typeCode(reason)))
    }

    @Test func scriptedQuitKeepsConfirmation() {
        #expect(!QuitReason.isSystemQuit(reasonTypeCode: typeCode("quia")))
    }

    @Test func missingReasonKeepsConfirmation() {
        #expect(!QuitReason.isSystemQuit(reasonTypeCode: nil))
    }

    @Test(arguments: ["shut", "rest", "rlgo"])
    func policyRecognizesSystemReasons(reason: String) {
        #expect(QuitReason.skipsConfirmation(typeCode: typeCode(reason)))
    }

    @Test func policyRejectsScriptedQuit() {
        #expect(!QuitReason.skipsConfirmation(typeCode: typeCode("quia")))
    }

    private func typeCode(_ reason: String) -> UInt32 {
        reason.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
