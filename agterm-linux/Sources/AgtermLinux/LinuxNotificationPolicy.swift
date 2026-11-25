import Foundation
import agtermCore

struct NotificationDelivery: Sendable, Equatable {
    let title: String
    let body: String
    let identity: String
}

struct TerminalNotificationRecord: Sendable, Equatable {
    let sessionID: UUID
    let windowID: UUID
    let pane: PaneRole
    let title: String
    let body: String
    let firingIsFocused: Bool
    let appActive: Bool
}

struct LinuxTerminalNotificationOrigin: Sendable, Equatable {
    let windowID: UUID
    let sessionID: UUID
    let pane: PaneRole
    let firingIsFocused: Bool
    let appActive: Bool
}

enum LinuxNotificationRevealFocus: Sendable, Equatable {
    case primary
    case split
    case overlay

    static func resolve(
        pane: PaneRole, sessionExists: Bool, hasSplit: Bool, coverActive: Bool
    ) -> LinuxNotificationRevealFocus? {
        guard sessionExists else { return nil }
        switch pane {
        case .split where hasSplit: return .split
        case .overlay where coverActive: return .overlay
        default: return .primary
        }
    }
}

extension AppStore {
    @discardableResult
    func recordTerminalNotification(_ record: TerminalNotificationRecord) -> NotificationDelivery? {
        guard let session = session(withID: record.sessionID) else { return nil }
        guard TerminalNotification.shouldDeliver(
            firingIsFocused: record.firingIsFocused,
            appActive: record.appActive
        ) else { return nil }
        session.unseenCount += 1
        return NotificationDelivery(
            title: record.title,
            body: record.body,
            identity: TerminalNotification.identity(
                windowID: record.windowID,
                sessionID: record.sessionID,
                pane: record.pane
            )
        )
    }
}
