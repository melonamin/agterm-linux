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
}
