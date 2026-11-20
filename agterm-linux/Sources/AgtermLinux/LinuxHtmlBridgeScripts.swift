import Foundation

/// Upstream's DOM adapter, using WebKitGTK's reply-capable message handler.
enum LinuxHtmlBridgeScripts {
    static func adapter(nonce: String) -> String { adapterScript(nonce: nonce) }
    static func helper(nonce: String) -> String { helperScript(nonce: nonce) }
    private static func adapterScript(nonce: String) -> String { """
        (() => {
          if (window !== window.top) return;
          const native = window.webkit.messageHandlers.agterm;
          const handler = {postMessage: body => native.postMessage({nonce: '\(nonce)', request: body})};
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
            handler.postMessage(body).then((result) => show(el, shown(result)), (error) => show(el, error.message));
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

    // the page's own entry point; the second argument is the request envelope, not the arguments themselves
    private static func helperScript(nonce: String) -> String { """
        (() => {
          if (window !== window.top) return;
          const native = window.webkit.messageHandlers.agterm;
          const handler = {postMessage: body => native.postMessage({nonce: '\(nonce)', request: body})};
          const request = (cmd, {target, args} = {}) => {
            const body = {cmd};
            if (target !== undefined) body.target = target;
            if (args !== undefined) body.args = args;
            return handler.postMessage(body);
          };
          Object.defineProperty(window, 'agterm', {value: Object.freeze({request}), enumerable: false});
        })();
        """
    }

}
