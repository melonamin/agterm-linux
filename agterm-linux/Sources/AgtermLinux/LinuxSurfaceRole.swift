import agtermCore

/// The Linux host's concrete terminal surfaces. Notification identity is explicit because `isSplitPane`
/// cannot distinguish overlays, scratch terminals, or the window-level quick terminal.
enum LinuxSurfaceRole: Sendable, Equatable {
    case main
    case split
    case overlay
    case scratch
    case quick

    var notificationPane: PaneRole? {
        switch self {
        case .main: .main
        case .split: .split
        case .overlay, .scratch: .overlay
        case .quick: nil
        }
    }

    func notificationPane(liveOverlayPane: OverlayPane?) -> PaneRole? {
        switch liveOverlayPane {
        case .left: .main
        case .right: .split
        case nil: notificationPane
        }
    }

    var statusPane: StatusPane? {
        switch self {
        case .main: .left
        case .split: .right
        case .scratch: .scratch
        case .overlay, .quick: nil
        }
    }
}
