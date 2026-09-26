import Foundation
import agtermCore

@MainActor
extension LinuxControlDispatcher {
    func dispatchAskCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .askOpen: return dispatchAskOpen(request)
        case .askResult:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "ask.result requires an ask id")
            }
            return actions.askResult(target, window: request.args?.window)
        case .askCancel:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "ask.cancel requires an ask id")
            }
            return actions.cancelAsk(target, window: request.args?.window)
        default: preconditionFailure("unexpected ask command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchAskOpen(_ request: ControlRequest) -> ControlResponse {
        guard let args = request.args, let title = args.title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ControlResponse(ok: false, error: "ask.open requires a title")
        }
        guard let buttons = args.buttons else {
            return ControlResponse(ok: false, error: "ask.open requires buttons")
        }
        guard !buttons.isEmpty else {
            return ControlResponse(ok: false, error: "ask.open requires at least one button")
        }
        guard buttons.count <= ControlAskButton.maxButtons else {
            return ControlResponse(ok: false, error: "too many buttons (max \(ControlAskButton.maxButtons))")
        }
        guard buttons.allSatisfy({ !$0.label.isEmpty }) else {
            return ControlResponse(ok: false, error: "ask button label must not be empty")
        }
        let ids = Set(buttons.map(\.id))
        guard ids.count == buttons.count else {
            return ControlResponse(ok: false, error: "ask button ids must be unique")
        }
        guard !askHasControlCharacters(title), !askHasControlCharacters(args.message ?? ""),
              buttons.allSatisfy({ !askHasControlCharacters($0.label) }) else {
            return ControlResponse(ok: false, error: "ask text must not contain control characters")
        }
        for (role, id) in [("default", args.defaultButton), ("destructive", args.destructiveButton)] {
            if let id, !ids.contains(id) {
                return ControlResponse(ok: false, error: "unknown \(role) button: \(id)")
            }
        }
        if args.defaultButton != nil, args.defaultButton == args.destructiveButton {
            return ControlResponse(ok: false, error: "default button must not be destructive")
        }
        guard let style = ControlAskStyle(rawValue: args.style ?? "terminal") else {
            return ControlResponse(ok: false, error: "unknown style")
        }
        guard let align = ControlAskAlignment(rawValue: args.align ?? "right") else {
            return ControlResponse(ok: false, error: "unknown align")
        }
        if let width = args.width, !(10...100).contains(width) {
            return ControlResponse(ok: false, error: "width must be 10 to 100")
        }
        var hotkeys = Set<String>()
        for button in buttons {
            guard let hotkey = button.hotkey else { continue }
            guard hotkey.utf8.count == 1, let ascii = hotkey.utf8.first,
                  (65...90).contains(ascii) || (97...122).contains(ascii) else {
                return ControlResponse(ok: false, error: "ask button hotkey must be one ASCII letter")
            }
            guard hotkeys.insert(hotkey.lowercased()).inserted else {
                return ControlResponse(ok: false, error: "ask button hotkeys must be unique")
            }
        }
        if style == .gui, args.pane != nil || args.paneID != nil, request.target == nil {
            return ControlResponse(ok: false, error: "--pane requires a session")
        }
        let pane: OverlayPane?
        if let raw = args.pane {
            guard let parsed = OverlayPane(controlName: raw) else {
                return ControlResponse(ok: false, error: "--pane must be left or right")
            }
            pane = parsed
        } else {
            pane = nil
        }
        let ask = PendingAsk(
            id: UUID().uuidString, title: title, message: args.message,
            buttons: buttons.map { ControlAskButton(id: $0.id, label: $0.label,
                                                    hotkey: $0.hotkey?.lowercased()) },
            defaultID: args.defaultButton, destructiveID: args.destructiveButton,
            style: style, align: align, width: args.width
        )
        return actions.openAsk(ask, target: request.target, window: args.window,
                               placement: ControlAskPlacement(pane: pane, paneID: args.paneID),
                               follow: args.follow == true)
    }

    private func askHasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
