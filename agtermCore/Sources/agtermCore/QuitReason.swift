import Foundation

public enum QuitReason {
    private static let shutDown = fourCharacterCode("shut")
    private static let restart = fourCharacterCode("rest")
    private static let reallyLogOut = fourCharacterCode("rlgo")

    /// Whether a quit reason identifies a system shutdown, restart, or logout rather than a user request.
    /// A missing reason and scripted quits answer false, so the host keeps its confirmation.
    public static func isSystemQuit(reasonTypeCode: UInt32?) -> Bool {
        guard let reasonTypeCode else { return false }
        return skipsConfirmation(typeCode: reasonTypeCode)
    }

    static func skipsConfirmation(typeCode: UInt32) -> Bool {
        typeCode == shutDown || typeCode == restart || typeCode == reallyLogOut
    }

    private static func fourCharacterCode(_ value: String) -> UInt32 {
        precondition(value.utf8.count == 4)
        return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
