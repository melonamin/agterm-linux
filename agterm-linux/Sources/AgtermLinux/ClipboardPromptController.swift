import CGtk
import Foundation
import agtermCore

@MainActor
final class ClipboardPromptController {
    static let shared = ClipboardPromptController()

    struct PromptKey: Hashable {
        let access: ClipboardAccess
        let requester: ObjectIdentifier?
    }

    private struct Pending {
        let requester: GhosttySurface?
        var waiters: [(Bool) -> Void]
    }

    final class ResponseContext {
        let key: PromptKey
        init(key: PromptKey) { self.key = key }
    }

    private var policy = ClipboardPromptPolicy()
    private var pending: [PromptKey: Pending] = [:]

    func request(_ access: ClipboardAccess, requester: GhosttySurface?, completion: @escaping (Bool) -> Void) {
        switch policy.decision(for: access) {
        case .allow:
            completion(true)
        case .deny:
            completion(false)
        case .prompt:
            let key = PromptKey(access: access, requester: requester.map(ObjectIdentifier.init))
            if pending[key] != nil {
                pending[key]?.waiters.append(completion)
                return
            }
            pending[key] = Pending(requester: requester, waiters: [completion])
            presentPrompt(key)
        }
    }

    private func presentPrompt(_ key: PromptKey) {
        let heading = key.access == .read ? "Allow a program to read the clipboard?" : "Allow a program to set the clipboard?"
        let body = key.access == .read
            ? "A program running in the terminal is trying to read your clipboard contents (OSC 52)."
            : "A program running in the terminal is trying to replace your clipboard contents (OSC 52)."
        let dialog = OpaquePointer(heading.withCString { h in body.withCString { b in adw_alert_dialog_new(h, b) } })
        "deny".withCString { i in "Deny".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "allow".withCString { i in "Allow".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "always-deny".withCString { i in "Always Deny".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "always-allow".withCString { i in "Always Allow".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "allow".withCString { adw_alert_dialog_set_response_appearance(cast(dialog), $0, ADW_RESPONSE_SUGGESTED) }
        "always-deny".withCString { adw_alert_dialog_set_response_appearance(cast(dialog), $0, ADW_RESPONSE_DESTRUCTIVE) }
        "deny".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        let ctx = Unmanaged.passRetained(ResponseContext(key: key)).toOpaque()
        connect(dialog, "response",
                unsafeBitCast(onClipboardPromptResponse as @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void,
                              to: GCallback.self),
                ctx)
        adw_dialog_present(cast(dialog), W(window(for: pending[key]?.requester)))
    }

    func resolve(_ key: PromptKey, response: String) {
        let allowed = response == "allow" || response == "always-allow"
        if response == "always-allow" || response == "always-deny" {
            policy.remember(key.access, allow: allowed)
        }
        let entry = pending.removeValue(forKey: key)
        for waiter in entry?.waiters ?? [] { waiter(allowed) }
    }

    private func window(for requester: GhosttySurface?) -> OpaquePointer? {
        guard let requester else { return gController?.windowPointer }
        return gWindows.values.first { $0.store.session(withID: requester.sessionID) != nil }?.windowPointer
            ?? gController?.windowPointer
    }
}

private let onClipboardPromptResponse: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, response, data in
    guard let data else { return }
    let ctx = Unmanaged<ClipboardPromptController.ResponseContext>.fromOpaque(data).takeRetainedValue()
    let id = response.map { String(cString: $0) } ?? "deny"
    MainActor.assumeIsolated { ClipboardPromptController.shared.resolve(ctx.key, response: id) }
}
