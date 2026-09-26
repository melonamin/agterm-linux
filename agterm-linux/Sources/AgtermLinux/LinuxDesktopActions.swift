/// Static freedesktop launcher actions declared by the Linux `.desktop` entry.
///
/// Desktop Entry Actions cannot carry dynamic session identities, so the recent and attention entries open
/// their live GTK palettes after the invocation reaches the primary `GApplication` instance.
enum LinuxDesktopAction: String, CaseIterable, Equatable, Sendable {
    case newSession = "new-session"
    case newWindow = "new-window"
    case quickTerminal = "quick-terminal"
    case dashboard
    case recentSessions = "recent-sessions"
    case attention

    /// Whether this action can run against a window in its current modal state. New Window is app-scoped;
    /// Dashboard is the one window action whose open grid doubles as its own escape hatch.
    func isEnabled(in context: LinuxDesktopActionContext) -> Bool {
        switch self {
        case .newWindow:
            return true
        case .dashboard:
            return !context.terminalZoomActive && !context.pickerActive
        default:
            return !context.modalActive
        }
    }
}

/// The three window-local covers desktop launcher actions must recheck at invocation time.
struct LinuxDesktopActionContext: Equatable, Sendable {
    let terminalZoomActive: Bool
    let dashboardOpen: Bool
    let pickerActive: Bool

    var modalActive: Bool { terminalZoomActive || dashboardOpen || pickerActive }
}

/// Pure command-line classification for the `GApplication::command-line` adapter.
///
/// `G_APPLICATION_HANDLES_COMMAND_LINE` forwards the complete invocation to the primary process. Keeping the
/// parser host-free makes cold/warm launcher behavior testable without a display or a session bus.
enum LinuxApplicationInvocation: Equatable, Sendable {
    case activate
    case open([String])
    case desktopAction(LinuxDesktopAction)
    case invalid(String)

    static let desktopActionPrefix = "--desktop-action="

    static func parse(arguments: [String]) -> Self {
        guard !arguments.isEmpty else { return .activate }
        if arguments.first == "--" {
            let paths = Array(arguments.dropFirst())
            return paths.isEmpty ? .activate : .open(paths)
        }
        if arguments.count == 1, let first = arguments.first,
           first.hasPrefix(desktopActionPrefix) {
            let value = String(first.dropFirst(desktopActionPrefix.count))
            guard let action = LinuxDesktopAction(rawValue: value) else {
                return .invalid("unknown desktop action: \(value)")
            }
            return .desktopAction(action)
        }
        if arguments.contains(where: { $0.hasPrefix(desktopActionPrefix) }) {
            return .invalid("--desktop-action must be used alone")
        }
        if let option = arguments.first(where: { $0.hasPrefix("-") }) {
            return .invalid("unknown option: \(option)")
        }
        return .open(arguments)
    }
}
