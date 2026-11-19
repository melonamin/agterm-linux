import agtermCore

@MainActor
extension LinuxControlDispatcher {
    func dispatchCompanionCommand(_ request: ControlRequest,
                                  create: ((LinuxRemoteCompanionRequest, Bool) -> ControlResponse)? = nil) -> ControlResponse {
        switch request.cmd {
        case .sessionCompanionConvert:
            return actions.convertToCompanion(request.target, window: request.args?.window)
        case .sessionCompanionMove:
            guard let parent = request.args?.parent?.trimmingCharacters(in: .whitespaces), !parent.isEmpty else {
                return actions.err("session.companion.move needs a parent")
            }
            if request.args?.workspace != nil || request.args?.to != nil || request.args?.after != nil || request.args?.before != nil {
                return actions.err("session.companion.move takes no workspace, --to, --after or --before")
            }
            if request.args?.targets != nil { return actions.err("session.companion.move moves one companion, named by target") }
            if let index = request.args?.index, index < 0 { return actions.err("index must be 0 or more") }
            return actions.moveLinuxCompanion(request.target, parent: parent, index: request.args?.index)
        case .sessionPage:
            return dispatchCompanionPage(request, create: nil)
        case .sessionCompanionNew:
            return dispatchCompanionNew(request, create: create)
        case .sessionCompanionPage:
            return dispatchCompanionPage(request, create: create)
        case .sessionCompanionDuplicate:
            if let create { return create(.duplicate, request.args?.noSelect != true) }
            return actions.duplicateLinuxCompanion(request.target, window: request.args?.window,
                                                      select: request.args?.noSelect != true)
        case .sessionCompanionPageAttach:
            return actions.attachCompanionPage(request.target, window: request.args?.window)
        case .sessionCollapse:
            return actions.setSessionExpansion(request.target, window: request.args?.window, expanded: false)
        case .sessionExpand:
            return actions.setSessionExpansion(request.target, window: request.args?.window, expanded: true)
        default:
            return ControlResponse(ok: false, error: "unknown command \(request.cmd.rawValue)")
        }
    }

    // a page companion's page is the row, so it is always full size and session-wide
    private func dispatchCompanionPage(_ request: ControlRequest,
                                       create: ((LinuxRemoteCompanionRequest, Bool) -> ControlResponse)?) -> ControlResponse {
        let args = request.args
        let page: HtmlSource
        switch Self.overlayContent(command: args?.command ?? "", args: args) {
        case .rejected(let response): return response
        case .program, .page(.image), .page(.markdown), .page(.text):
            return ControlResponse(ok: false, error: OverlayHtmlError.companionNeedsPage)
        case .page(let source): page = source
        }
        if args?.pane != nil || args?.sizePercent != nil || args?.width != nil || args?.height != nil {
            return ControlResponse(ok: false, error: "a page companion is full size: it takes no --pane, --size-percent, --width or --height")
        }
        if let color = args?.color, !WatermarkConfig.isValidColorHex(color) {
            return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
        }
        let options = ControlSessionOverlayOpenOptions(
            command: "", cwd: nil, wait: false, sizePercent: nil, backgroundColor: args?.color,
            follow: args?.follow ?? false, pane: nil, page: page, navigation: args?.navigation ?? false,
            javascript: args?.javascript ?? false, chromeless: args?.chromeless ?? false,
            persistent: args?.persistent ?? false, browse: args?.browse ?? false)
        if let create { return create(.page(options), options.follow) }
        if request.cmd == .sessionPage { return actions.createLinuxPageSession(request.target, options: options) }
        return actions.createLinuxPageCompanion(request.target, window: args?.window, options: options)
    }

    // a companion lands under its parent, so a raw client's workspace or placement field is refused, not dropped
    private func dispatchCompanionNew(_ request: ControlRequest,
                                      create: ((LinuxRemoteCompanionRequest, Bool) -> ControlResponse)?) -> ControlResponse {
        let args = request.args
        if args?.workspace != nil || args?.workspaceName != nil || args?.createWorkspace == true
            || args?.after != nil || args?.before != nil {
            return ControlResponse(ok: false, error: "a companion takes no workspace or placement: it lands under its parent")
        }
        if args?.wait == true, args?.command == nil {
            return ControlResponse(ok: false, error: "--wait requires --command")
        }
        let tint: SidebarTint?
        switch Self.creationTint(args) {
        case .success(let value): tint = value
        case .failure(let rejection): return ControlResponse(ok: false, error: rejection.message)
        }
        let options = CompanionOptions(cwd: args?.cwd, command: args?.command, name: args?.name,
                                       wait: args?.wait == true, select: args?.noSelect != true, tint: tint)
        if let create { return create(.terminal(options), options.select) }
        return actions.createLinuxCompanion(request.target, options: options, window: args?.window)
    }
}
