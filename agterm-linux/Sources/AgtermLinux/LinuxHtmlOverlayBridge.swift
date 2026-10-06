import CWebKit
import Foundation
import agtermCore

/// LinuxHtmlBridgeDispatch runs one page request as the control socket would and answers through the callback.
typealias LinuxHtmlBridgeDispatch = @MainActor (ControlRequest, @escaping @MainActor (ControlResponse) -> Void) -> Void

/// LinuxHtmlOverlayBridge is upstream's `HtmlOverlayBridge` over WebKitGTK script message handlers: the same
/// `data-agterm` adapter in a world of its own, and `agterm.request` on a `--js` page. WebKitGTK names no frame for
/// a message, so both scripts, injected into the top frame only, send the page's token, and a message without
/// it came from a frame. The token lives in a script closure with `postMessage` bound at document start, so no
/// function source, property or later prototype patch shows it to the page or a same-origin frame.
@MainActor
enum LinuxHtmlOverlayBridge {
    static let world = "agterm-bridge"
    static let handlerName = "agterm"

    // upstream's adapter, sending through `post`; see HtmlOverlayBridge.adapterScript for its rules
    static func adapterScript(token: String) -> String {
        """
        (() => {
          \(sender(token: token))
          const show = (el, text) => {
            const selector = el.getAttribute('data-agterm-into');
            const into = selector ? document.querySelector(selector) : null;
            if (into) into.textContent = text;
          };
          const shown = (result) => {
            if (result && typeof result.text === 'string') return result.text;
            return JSON.stringify(result ?? {});
          };
          const formArgs = (form, args, submitter) => {
            const seen = new Set();
            for (const control of form.elements) {
              const name = control.name;
              if (!name || control.matches(':disabled')) continue;
              const type = (control.type || '').toLowerCase();
              if (['submit', 'button', 'reset', 'image'].includes(type) && control !== submitter) continue;
              if (type === 'file') throw new Error(`file inputs are not supported: ${name}`);
              if (type === 'radio' && !control.checked) continue;
              let value;
              if (type === 'checkbox') {
                value = control.checked;
              } else if (type === 'number') {
                if (control.value === '') continue;
                value = control.valueAsNumber;
                if (!Number.isFinite(value)) throw new Error(`not a number: ${name}`);
              } else if (control instanceof HTMLSelectElement && control.multiple) {
                const picked = Array.from(control.selectedOptions);
                if (picked.length > 1) throw new Error(`more than one value for ${name}`);
                if (picked.length === 0) continue;
                value = picked[0].value;
              } else {
                value = control.value;
              }
              if (seen.has(name)) throw new Error(`more than one value for ${name}`);
              seen.add(name);
              args[name] = value;
            }
            return args;
          };
          const send = (el, form, submitter) => {
            const body = {cmd: el.getAttribute('data-agterm')};
            const target = el.getAttribute('data-agterm-target');
            if (target !== null) body.target = target;
            try {
              const base = el.getAttribute('data-agterm-args');
              let args = base === null ? undefined : JSON.parse(base);
              if (form) args = formArgs(form, args ?? {}, submitter);
              if (args !== undefined) body.args = args;
            } catch (error) {
              show(el, error.message);
              return;
            }
            post(body).then((result) => show(el, shown(result)), (error) => show(el, error.message));
          };
          document.addEventListener('submit', (event) => {
            const form = event.target;
            if (!(form instanceof HTMLFormElement) || !form.hasAttribute('data-agterm')) return;
            event.preventDefault();
            send(form, form, event.submitter);
          }, true);
          document.addEventListener('click', (event) => {
            const el = event.target instanceof Element ? event.target.closest('[data-agterm]') : null;
            if (!el || el instanceof HTMLFormElement || el.closest('form[data-agterm]')) return;
            if (el instanceof HTMLButtonElement && el.type !== 'button') return;
            event.preventDefault();
            send(el, null, null);
          }, true);
        })();
        """
    }

    // `post` names the token only through its closure, and calls the handler's own postMessage, bound before any
    // page script can replace it on the prototype
    private static func sender(token: String) -> String {
        "const post = ((token, send) => (body) => send({token, request: body}))("
            + "'\(token)', window.webkit.messageHandlers.\(handlerName).postMessage.bind(window.webkit.messageHandlers.\(handlerName)));"
    }

    static func helperScript(token: String) -> String {
        """
        (() => {
          \(sender(token: token))
          const request = (cmd, {target, args} = {}) => {
            const body = {cmd};
            if (target !== undefined) body.target = target;
            if (args !== undefined) body.args = args;
            return post(body);
          };
          Object.defineProperty(window, 'agterm', {value: Object.freeze({request}), enumerable: false});
        })();
        """
    }

    /// handle answers one page message through `reply` exactly once. `origin` is where the page sits now, nil once
    /// it left its slot; the request is built from it at admission and dispatched afterwards.
    static func handle(_ message: String?, token: String, origin: HtmlBridgePage?, dispatch: LinuxHtmlBridgeDispatch?,
                       reply: @escaping @MainActor (_ json: String?, _ error: String?) -> Void) {
        let envelope = message?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        guard let envelope, envelope["token"] as? String == token else {
            return reply(nil, "requests from frames are refused")
        }
        guard let origin else { return reply(nil, "page closed") }
        guard let body = envelope["request"], JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            return reply(nil, "invalid request")
        }
        let request: ControlRequest
        switch HtmlBridge.request(from: data, page: origin) {
        case .success(let built): request = built
        case .failure(let refusal): return reply(nil, refusal.message)
        }
        guard let dispatch else { return reply(nil, "control is unavailable") }
        dispatch(request) { response in
            let (json, error) = Self.reply(response)
            reply(json, error)
        }
    }

    /// reply shapes a response for the page: the result as JSON text, or the error for a refused request.
    static func reply(_ response: ControlResponse) -> (json: String?, error: String?) {
        guard response.ok else { return (nil, response.error ?? "request failed") }
        guard let result = response.result, let data = try? JSONEncoder().encode(result),
              let json = String(data: data, encoding: .utf8) else { return ("{}", nil) }
        return (json, nil)
    }
}

/// LinuxScriptReply holds WebKit's reply to one page message until the request is answered, then answers once.
@MainActor
final class LinuxScriptReply {
    private var reply: UnsafeMutableRawPointer?

    init(_ reply: UnsafeMutableRawPointer) {
        self.reply = agterm_script_message_reply_ref(reply)
    }

    func send(_ json: String?, error: String?) {
        guard let reply else { return }
        self.reply = nil
        if let error {
            error.withCString { agterm_script_message_reply_error(reply, $0) }
        } else {
            (json ?? "{}").withCString { agterm_script_message_reply_json(reply, $0) }
        }
        agterm_script_message_reply_unref(reply)
    }
}
