import Testing
@testable import agtermCore

@MainActor
struct MainLoopControlTests {
    @Test(arguments: [Command.sessionOverlayFollow, .sessionOverlaySearch, .sessionOverlayChanges,
                      .sessionOverlayWrap, .sessionOverlayExpand, .sessionOverlayFiles])
    func asyncTextCommandsReachTheHostAdapter(_ command: Command) {
        let actions = MockControlActions()
        let response = ControlDispatcher(actions: actions).dispatchSynchronous(ControlRequest(cmd: command))
        #expect(response == nil)
        #expect(actions.calls.isEmpty)
    }
}
