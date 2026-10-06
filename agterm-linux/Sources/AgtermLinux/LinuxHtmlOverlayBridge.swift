import CGtk
import CWebKit
import Foundation
import agtermCore

@MainActor
extension LinuxHtmlOverlayPage {
    func installBridge() {
        guard case .file = overlay.source else { return }
        let data = Unmanaged.passUnretained(self).toOpaque()
        connect(manager, "script-message-with-reply-received::agterm", unsafeBitCast(onHtmlBridgeRequest, to: GCallback.self), data)
        for world in overlay.javascript ? ["agterm-bridge", ""] : ["agterm-bridge"] {
            world.withCString { name in
                _ = "agterm".withCString {
                    webkit_user_content_manager_register_script_message_handler_with_reply(manager, $0,
                                                                                           world.isEmpty ? nil : name)
                }
            }
        }
        addBridgeScript(LinuxHtmlBridgeScripts.adapter(nonce: bridgeNonce), world: "agterm-bridge")
        if overlay.javascript { addBridgeScript(LinuxHtmlBridgeScripts.helper(nonce: bridgeNonce), world: nil) }
    }

    private func addBridgeScript(_ text: String, world: String?) {
        text.withCString { source in
            let script: OpaquePointer?
            if let world {
                script = world.withCString {
                    webkit_user_script_new_for_world(source, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
                                                     WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, $0, nil, nil)
                }
            } else {
                script = webkit_user_script_new(source, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
                                                WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, nil, nil)
            }
            webkit_user_content_manager_add_script(manager, script)
            webkit_user_script_unref(script)
        }
    }

    func bridgeRequest(_ value: OpaquePointer?, reply: OpaquePointer?) {
        guard let reply else { return }
        guard !closed, let store, let controller, let slot = store.htmlOverlaySlot(id),
              let uri = webkit_web_view_get_uri(cast(webView)).map(String.init(cString:)),
              uri == "about:blank" || uri.hasPrefix("agterm-file://\(id.uuidString.lowercased())/") else {
            return rejectBridge(reply, "page closed or navigation left the file grant")
        }
        guard let json = jsc_value_to_json(value, 0) else { return rejectBridge(reply, "invalid request") }
        let data = Data(String(cString: json).utf8)
        g_free(json)
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["nonce"] as? String == bridgeNonce, let object = envelope["request"],
              let requestData = try? JSONSerialization.data(withJSONObject: object) else {
            return rejectBridge(reply, "request must come from the file page's main frame")
        }
        let page = HtmlBridgePage(window: controller.windowID.uuidString, session: slot.session.id, pane: slot.pane)
        let request: ControlRequest
        switch HtmlBridge.request(from: requestData, page: page) {
        case .failure(let error): return rejectBridge(reply, error.message)
        case .success(let decoded): request = decoded
        }
        guard let context = jsc_value_get_context(value) else { return rejectBridge(reply, "no JavaScript context") }
        let delivery = LinuxHtmlBridgeReply(reply: reply, context: context)
        let server = gControlServer
        Thread.detachNewThread {
            let response = server.performRequest(request)
            runOnMain { MainActor.assumeIsolated { delivery.finish(response) } }
        }
    }

    private func rejectBridge(_ reply: OpaquePointer, _ error: String) {
        error.withCString { webkit_script_message_reply_return_error_message(reply, $0) }
    }

    func applyZoom() {
        let zoom = linuxSettingsStore().load().effectiveHtmlOverlayZoom
        webkit_web_view_set_zoom_level(cast(webView), zoom)
    }
}

/// Retain only the reply and JS context across the worker; touch both again on GTK's main thread.
@MainActor
private final class LinuxHtmlBridgeReply {
    let reply: OpaquePointer
    let context: OpaquePointer
    init(reply: OpaquePointer, context: OpaquePointer) {
        self.reply = webkit_script_message_reply_ref(reply)
        self.context = context
        g_object_ref(RAW(context))
    }
    func finish(_ response: ControlResponse) {
        if !response.ok {
            (response.error ?? "request failed").withCString { webkit_script_message_reply_return_error_message(reply, $0) }
        } else {
            let data = response.result.flatMap { try? JSONEncoder().encode($0) } ?? Data("{}".utf8)
            let value = String(decoding: data, as: UTF8.self).withCString { jsc_value_new_from_json(context, $0) }
            webkit_script_message_reply_return_value(reply, value)
            if let value { g_object_unref(RAW(value)) }
        }
        webkit_script_message_reply_unref(reply)
        g_object_unref(RAW(context))
    }
}

private let onHtmlBridgeRequest: @MainActor @convention(c)
    (OpaquePointer?, OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean = { _, value, reply, data in
        guard let data else { return 0 }
        Unmanaged<LinuxHtmlOverlayPage>.fromOpaque(data).takeUnretainedValue().bridgeRequest(value, reply: reply)
        return 1
    }
