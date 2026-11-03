import Foundation
import agtermCore

@MainActor
extension AppController {
    func reportCustomCommandFailure(_ failure: LinuxCustomCommandFailure,
                                    command: CustomCommand, sessionID: String) {
        showToast(failure.toast(commandName: command.name))
        guard command.errorHud, !sessionID.isEmpty else { return }
        let spec = HudSpec(message: CommandFailure.message(name: command.name, reason: failure.reason),
                           detail: failure.detail, position: command.errorPosition, hideAfter: 10)
        _ = openHud(sessionID, window: nil, spec: spec,
                    placement: ControlHudPlacement(pane: command.errorPane))
    }
}
