import CGtk
import Foundation
import agtermCore

// The `window.*` half of the Linux `ControlActions` adapter, split out of `ControlActions+AppController.swift`
// so that file stays under the 1000-line cap — the same family split upstream made with
// `ControlServer+WindowCommands.swift`. These arms still satisfy the `ControlActions` conformance declared
// there, and they are the SINGLE implementation of each window command: `AppControllerControl.handleControl`
// delegates to them rather than keeping an inline copy that could drift (it already had: the inline
// `window.list` lost the fullscreen/zoom read-back the conformance supplies). `windowSelect`/`windowClose`
// are `async` only because the upstream protocol is; the work is synchronous, so each forwards to a `*Sync`
// core the GTK server's synchronous socket callback can call — the `typeSessionSync` pattern.
@MainActor
extension AppController {
    func windowNew(name: String?, minimized: Bool) async -> ControlResponse {
        windowNewSync(name: name, minimized: minimized)
    }

    func windowNewSync(name: String?, minimized: Bool) -> ControlResponse {
        let info = library.newWindow(name: name?.linuxTrimmedOrNil)
        openWindow(info.id)
        if minimized, let controller = gWindows[info.id] {
            gtk_window_minimize(WIN(controller.windowPointer))
        }
        return ok(info.id)
    }

    func windowList() -> ControlResponse {
        let nodes = projectingLinuxAutoFollow(library.controlWindowNodes(flags: { id in
            guard let ctl = gWindows[id] else { return nil }
            return (fullscreen: gtk_window_is_fullscreen(WIN(ctl.windowPointer)) != 0,
                    zoomed: gtk_window_is_maximized(WIN(ctl.windowPointer)) != 0,
                    minimized: linuxWindowIsMinimized(ctl.windowPointer))
        }))
        return ControlResponse(ok: true, result: ControlResult(windows: nodes))
    }

    func windowSelect(_ target: String?) async -> ControlResponse {
        windowSelectSync(target)
    }

    func windowSelectSync(_ target: String?) -> ControlResponse {
        switch resolveWindowResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            openWindow(id)
            return ok(id)
        }
    }

    func windowClose(_ target: String?) async -> ControlResponse {
        windowCloseSync(target)
    }

    func windowCloseSync(_ target: String?) -> ControlResponse {
        switch resolveWindowResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let ctl = gWindows[id] {
                gtk_window_close(WIN(ctl.windowPointer))
            } else {
                library.closeWindow(id)
            }
            return ok(id)
        }
    }

    func windowRename(_ target: String?, name: String) -> ControlResponse {
        switch resolveWindowResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            library.renameWindow(id, to: name)
            gWindows[id]?.updateTitle()
            return ok(id)
        }
    }

    func windowDelete(_ target: String?) -> ControlResponse {
        switch resolveWindowResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard library.canRemoveWindow else { return err("cannot delete last window") }
            if let ctl = gWindows[id] {
                // Bypass the quit-confirm the way the GUI Delete Window does (`confirmWindowDelete`): the
                // caller already decided, and a control command must never block on a GUI modal. Without
                // this, deleting the LAST OPEN window with sessions presents the alert and
                // `windowShouldClose` REFUSES, so `windowWillClose` never runs — yet `removeWindow` below
                // would still delete the store, the watermark PNGs and `windows/<id>.json` out from under a
                // window that stays on screen with live shells. (`canRemoveWindow` counts ALL known windows
                // and the quit-confirm counts only OPEN ones, so one open + one closed reaches that state.)
                ctl.confirmedClose = true
                gtk_window_close(WIN(ctl.windowPointer))
            }
            library.removeWindow(id)
            return ok(id)
        }
    }

    func windowResize(_ target: String?, width: Int, height: Int) -> ControlResponse {
        switch resolveWindowResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let ctl = gWindows[id] else { return err("window not open — window.select it first") }
            gtk_window_set_default_size(WIN(ctl.windowPointer), Int32(width), Int32(height))
            return ok(id)
        }
    }

    func windowMove(_ target: String?, x: Int, y: Int, display: Int?) -> ControlResponse {
        err("window.move is not supported on this platform (the compositor controls window position)")
    }

    func windowZoom(_ target: String?) -> ControlResponse {
        switch resolveWindowResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let ctl = gWindows[id] else { return err("window not open — window.select it first") }
            if gtk_window_is_maximized(WIN(ctl.windowPointer)) != 0 {
                gtk_window_unmaximize(WIN(ctl.windowPointer))
            } else {
                gtk_window_maximize(WIN(ctl.windowPointer))
            }
            return ok(id)
        }
    }

    func windowFullscreen(_ target: String?) -> ControlResponse {
        switch resolveWindowResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let ctl = gWindows[id] else { return err("window not open — window.select it first") }
            ctl.requestWindowFullscreenToggle()
            return ok(id)
        }
    }

    func windowMinimize(_ target: String?, mode: ControlToggleMode) async -> ControlResponse {
        windowMinimizeSync(target, mode: mode)
    }

    func windowMinimizeSync(_ target: String?, mode: ControlToggleMode) -> ControlResponse {
        switch resolveWindowResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let ctl = gWindows[id] else { return err("window not open — window.select it first") }
            let want = mode.desiredValue(current: linuxWindowIsMinimized(ctl.windowPointer))
            if want {
                gtk_window_minimize(WIN(ctl.windowPointer))
            } else {
                gtk_window_unminimize(WIN(ctl.windowPointer))
            }
            return ok(id)
        }
    }
}

private func linuxWindowIsMinimized(_ window: OpaquePointer?) -> Bool {
    guard let window,
          let surface = gtk_native_get_surface(window) else { return false }
    let state = gdk_toplevel_get_state(surface)
    return state.rawValue & GDK_TOPLEVEL_STATE_MINIMIZED.rawValue != 0
}
