import agtermCore

/// LinuxTintRejection is the refusal text of a tint request the dispatcher will not pass on.
struct LinuxTintRejection: Error {
    let message: String
}

@MainActor
extension LinuxControlDispatcher {
    /// `session.tint` and `workspace.tint` share one parse, so both refuse the same input the same way.
    func dispatchTint(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        switch Self.tintUpdate(args, command: request.cmd.rawValue) {
        case .failure(let rejection):
            return ControlResponse(ok: false, error: rejection.message)
        case .success(let update) where request.cmd == .workspaceTint:
            return actions.setWorkspaceTint(request.target, window: args?.window, update: update)
        case .success(let update):
            return actions.setSessionTint(request.target, window: args?.window, update: update)
        }
    }

    /// tintUpdate parses a set or clear. The mode is required, a set needs a color, and a clear refuses a
    /// color or placement rather than ignoring it, so a contradictory raw request never half-applies.
    static func tintUpdate(_ args: ControlArgs?, command: String) -> Result<ControlTintUpdate, LinuxTintRejection> {
        switch args?.mode ?? "" {
        case "set":
            guard let raw = args?.tint else { return .failure(LinuxTintRejection(message: "\(command) set requires a color")) }
            return tintColor(raw).flatMap { color in
                tintParts(args?.tintOn).map { ControlTintUpdate.set(color, parts: $0) }
            }
        case "clear":
            guard args?.tint == nil, args?.tintOn == nil else {
                return .failure(LinuxTintRejection(message: "\(command) clear takes no color or placement"))
            }
            return .success(.clear)
        default:
            return .failure(LinuxTintRejection(message: "invalid tint mode: \(args?.mode ?? "") (set|clear)"))
        }
    }

    /// creationTint parses `session.new`/`workspace.new`'s optional tint before anything is created, so an
    /// invalid one leaves no session or workspace behind. A placement without a color is refused.
    static func creationTint(_ args: ControlArgs?) -> Result<SidebarTint?, LinuxTintRejection> {
        guard let raw = args?.tint else {
            guard args?.tintOn == nil else { return .failure(LinuxTintRejection(message: "--tint-on requires --tint")) }
            return .success(nil)
        }
        return tintColor(raw).flatMap { color in
            tintParts(args?.tintOn).map { SidebarTint(color: color, parts: $0 ?? [.icon]) }
        }
    }

    private static func tintColor(_ raw: String) -> Result<TintColor, LinuxTintRejection> {
        guard let color = TintColor(rawValue: raw.lowercased()) else {
            return .failure(LinuxTintRejection(message: "invalid tint: \(raw) (\(TintColor.validNamesList))"))
        }
        return .success(color)
    }

    private static func tintParts(_ raw: [String]?) -> Result<Set<TintPart>?, LinuxTintRejection> {
        guard let raw else { return .success(nil) }
        guard let parts = SidebarTint.parseParts(raw) else {
            let shown = raw.joined(separator: ",")
            return .failure(LinuxTintRejection(message: "invalid tint placement: \(shown) (\(TintPart.validNamesList))"))
        }
        return .success(parts)
    }
}
