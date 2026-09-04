import Testing
@testable import AgtermLinux

@Suite("Linux desktop launcher actions")
struct LinuxDesktopActionsTests {
    @Test("all declared launcher action arguments reach the matching action")
    func actionArguments() {
        for action in LinuxDesktopAction.allCases {
            #expect(LinuxApplicationInvocation.parse(
                arguments: ["--desktop-action=\(action.rawValue)"]
            ) == .desktopAction(action))
        }
    }

    @Test("ordinary activation and open paths retain their existing command-line shapes")
    func ordinaryInvocations() {
        #expect(LinuxApplicationInvocation.parse(arguments: []) == .activate)
        #expect(LinuxApplicationInvocation.parse(arguments: ["/tmp/one", "relative/two"])
            == .open(["/tmp/one", "relative/two"]))
        #expect(LinuxApplicationInvocation.parse(arguments: ["--", "-leading-dash"])
            == .open(["-leading-dash"]))
        #expect(LinuxApplicationInvocation.parse(arguments: ["--"]) == .activate)
    }

    @Test("invalid launcher actions and mixed invocations fail closed")
    func invalidInvocations() {
        #expect(LinuxApplicationInvocation.parse(arguments: ["--desktop-action=unknown"])
            == .invalid("unknown desktop action: unknown"))
        #expect(LinuxApplicationInvocation.parse(
            arguments: ["--desktop-action=new-session", "/tmp/project"]
        ) == .invalid("--desktop-action must be used alone"))
        #expect(LinuxApplicationInvocation.parse(arguments: ["--unknown"])
            == .invalid("unknown option: --unknown"))
    }

    @Test("window-scoped actions are inert behind dashboard, zoom, and picker covers")
    func modalSafety() {
        let windowActions = LinuxDesktopAction.allCases.filter {
            $0 != .newWindow && $0 != .dashboard
        }
        let dashboard = LinuxDesktopActionContext(
            terminalZoomActive: false, dashboardOpen: true, pickerActive: false)
        let zoom = LinuxDesktopActionContext(
            terminalZoomActive: true, dashboardOpen: false, pickerActive: false)
        let picker = LinuxDesktopActionContext(
            terminalZoomActive: false, dashboardOpen: false, pickerActive: true)

        for action in windowActions {
            #expect(!action.isEnabled(in: dashboard), "\(action) ran through Dashboard")
            #expect(!action.isEnabled(in: zoom), "\(action) ran through Terminal Zoom")
            #expect(!action.isEnabled(in: picker), "\(action) ran through a pending picker")
        }
        #expect(!LinuxDesktopAction.dashboard.isEnabled(in: zoom))
        #expect(!LinuxDesktopAction.dashboard.isEnabled(in: picker))
    }

    @Test("Dashboard closes its own grid and New Window bypasses window covers")
    func modalExceptions() {
        let dashboard = LinuxDesktopActionContext(
            terminalZoomActive: false, dashboardOpen: true, pickerActive: false)
        let everyCover = LinuxDesktopActionContext(
            terminalZoomActive: true, dashboardOpen: true, pickerActive: true)

        #expect(LinuxDesktopAction.dashboard.isEnabled(in: dashboard))
        #expect(LinuxDesktopAction.newWindow.isEnabled(in: everyCover))
    }
}
