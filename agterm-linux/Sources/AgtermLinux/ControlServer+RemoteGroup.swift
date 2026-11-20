import Foundation
import agtermCore

extension ControlServer {
    /// One fresh discovery read supplies both parent and membership. SSH waits remain on this request's
    /// worker; each insertion re-resolves the parent's current store on the GTK thread.
    func attachRemoteGroup(host: String, session: String, tree: ControlRemoteTree, window: String?) -> ControlResponse {
        guard let remote = tree.sessions.first(where: { $0.id == session }) else {
            return ControlResponse(ok: false, error: "no attachable session \(session) on \(host)")
        }
        guard remote.parent == nil, remote.content == nil else {
            return ControlResponse(ok: false, error: "\(session) is a companion, not a group's parent")
        }
        let attached = attachRemoteOnMain(host: host, session: session, tree: tree, window: window)
        guard attached.ok, let parent = attached.result?.id.flatMap(UUID.init(uuidString:)) else { return attached }
        let members = remote.companions
            ?? tree.sessions.filter { $0.parent == remote.id }.map { ControlRemoteMember(id: $0.id, name: $0.name) }
        let outcomes = members.map { attachRemoteGroupMember($0, parent: parent, tree: tree, host: host) }
        let group = ControlRemoteGroup(membershipKnown: remote.companions != nil, companions: outcomes)
        let result = ControlResult(id: parent.uuidString, remoteGroup: group)
        let missing = zip(members, outcomes).filter { $0.1.id == nil }
        let remains = companionOnMain { ControlResponse(ok: gLibrary.store(forSession: parent) != nil) }.ok
        if !remains, !members.isEmpty {
            let names = missing.map(\.0.name).joined(separator: ", ")
            return ControlResponse(ok: false, result: result, error: "parent row \(parent.uuidString) was closed"
                + (names.isEmpty ? "" : "; not attached: \(names)"))
        }
        guard !missing.isEmpty else { return ControlResponse(ok: true, result: result) }
        let reasons = missing.map { "\($0.0.name) (\($0.1.error ?? "not attached"))" }.joined(separator: ", ")
        return ControlResponse(ok: false, result: result, error: "kept \(remote.name) (\(parent.uuidString)) and "
            + "\(outcomes.count - missing.count) companion(s); not attached: \(reasons)")
    }

    private func attachRemoteGroupMember(
        _ member: ControlRemoteMember, parent: UUID, tree: ControlRemoteTree, host: String
    ) -> ControlRemoteGroupMember {
        guard let remote = tree.sessions.first(where: { $0.id == member.id }) else {
            return ControlRemoteGroupMember(origin: member.id, error: "unavailable on \(host)")
        }
        let reply: ControlResponse
        if remote.content == "page" {
            reply = attachRemotePage(remote.id, host: host, parent: parent, select: false)
        } else {
            reply = companionOnMain {
                guard let store = gLibrary.store(forSession: parent), let window = gLibrary.windowID(for: store),
                      let controller = gWindows[window] else {
                    return ControlResponse(ok: false, error: "parent row was closed")
                }
                return controller.attachRemoteSession(host: host, session: member.id, tree: tree, parent: parent, select: false)
            }
        }
        guard reply.ok, let id = reply.result?.id else {
            return ControlRemoteGroupMember(origin: member.id, error: reply.error ?? "attach failed")
        }
        return ControlRemoteGroupMember(origin: member.id, id: id)
    }
}
