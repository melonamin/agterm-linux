import Foundation
import agtermCore

@MainActor
extension AppController {
    func resolveMessagePane(_ address: MessageAddress) -> Result<MessageRecipient, MessagePaneError> {
        let stores = library.openIDs().compactMap { library.store(for: $0) }
        let candidates = stores.flatMap { $0.workspaces.flatMap { $0.sessions.map(\.id) } }
        switch ControlResolve.resolve(address.session, candidates: candidates, active: store.selectedSessionID) {
        case .ambiguous(let ids):
            return .failure(MessagePaneError(ControlResolve.ambiguousMessage(noun: "session", target: address.session, hits: ids)))
        case .notFound:
            return .failure(MessagePaneError("no such session: \(address.session)"))
        case .resolved(let id):
            guard let recipient = library.store(forSession: id)?.messageRecipient(session: id, pane: address.pane) else {
                return .failure(MessagePaneError("pane \(address.pane.text) is not a live pane of session \(id.uuidString)"))
            }
            return .success(recipient)
        }
    }

    func messagePanes(workspace: String?, window: String?) -> Result<[MessageRecipient], MessagePaneError> {
        let stores = library.openIDs().compactMap { library.store(for: $0) }
        guard let workspace else { return .success(stores.flatMap { $0.messageRecipients() }) }
        let scoped: [AppStore]
        if let window {
            guard case .resolved(let id) = library.resolveWindow(window), let found = library.store(for: id) else {
                return .failure(MessagePaneError("no such window: \(window)"))
            }
            scoped = [found]
        } else {
            scoped = stores
        }
        let candidates = scoped.flatMap { $0.workspaces.map(\.id) }
        switch ControlResolve.resolve(workspace, candidates: candidates, active: store.currentWorkspaceID) {
        case .ambiguous(let ids):
            return .failure(MessagePaneError(ControlResolve.ambiguousMessage(noun: "workspace", target: workspace, hits: ids)))
        case .notFound:
            return .failure(MessagePaneError("no such workspace: \(workspace)"))
        case .resolved(let id):
            return .success(scoped.flatMap { $0.messageRecipients(workspace: id) })
        }
    }

    func messageQueued(_ messageID: UUID, from: String?, to recipients: [MessageRecipient]) {
        let stores = library.openIDs().compactMap { library.store(for: $0) }
        for recipient in recipients {
            for store in stores where store.emitMessageQueued(messageID, from: from, to: recipient) { break }
        }
    }
}
