import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func linkOpenMode(_ mode: LinkOpenMode?) -> ControlResponse {
        let settingsStore = linuxSettingsStore()
        var settings = settingsStore.load()
        if let mode {
            settings.linkOpenMode = mode == .browser ? nil : mode.rawValue
            do { try settingsStore.save(settings) } catch { return err("could not save link-open mode") }
        }
        return ControlResponse(ok: true, result: ControlResult(text: settings.effectiveLinkOpenMode.rawValue))
    }
}

@MainActor
extension GhosttySurface {
    func rememberLinkModifiers(_ mods: ghostty_input_mods_e) {
        let browserChord = GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SHIFT.rawValue
        linkBrowserOverride = mods.rawValue == browserChord && surface.map { !ghostty_surface_mouse_captured($0) } == true
    }

    var linkClickOrigin: LinkPolicy.ClickOrigin {
        switch role {
        case .main, .split:
            if controller?.store.session(withID: sessionID)?.remoteHost != nil { return .remotePane(sessionID) }
            return .pane(sessionID)
        case .scratch: return .scratch(sessionID)
        case .quick: return .quick
        case .overlay: return controller?.store.session(withID: sessionID)?.hudActive == true ? .hud : .programOverlay
        }
    }

    func openLink(_ raw: String) -> Bool {
        guard let controller else { return false }
        let mode = linkBrowserOverride ? LinkOpenMode.browser : linuxSettingsStore().load().effectiveLinkOpenMode
        switch LinkPolicy.route(for: raw, mode: mode, origin: linkClickOrigin) {
        case .image(let url, let id):
            return controller.openClickedFile(url, session: id, markdown: false)
        case .markdown(let url, let id, let sizePercent):
            return controller.openClickedFile(url, session: id, markdown: true, sizePercent: sizePercent)
        case .overlay(let url, let id, let sizePercent):
            guard controller.terminalZoom.target == nil, controller.store.session(withID: id)?.hudActive != true else { return false }
            return controller.openSessionOverlay(id.uuidString, window: nil, options: ControlSessionOverlayOpenOptions(
                command: "", cwd: nil, wait: false, sizePercent: sizePercent, backgroundColor: nil, follow: false,
                pane: nil, page: .url(url), navigation: true, javascript: true, persistent: true, browse: true)).ok
        case .browser, .reveal, .ignore: return false
        }
    }
}
