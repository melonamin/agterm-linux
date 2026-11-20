import Foundation
import agtermCore

@MainActor
extension AppController {
    func openLoopbackLink(_ page: ForwardedPage, session id: UUID, mode: LinkOpenMode) -> Bool {
        guard let host = store.session(withID: id)?.remoteHost else { return false }
        LinuxPortForward.open(page, host: host, window: windowID, row: id) { [weak self] port in
            guard let self, store.session(withID: id) != nil else { return }
            guard let port, let url = page.url(localPort: port) else {
                NotificationManager.send(title: "Open remote link", body: "the port forward to \(host) could not be opened")
                return
            }
            if mode == .browser {
                _ = launchDefaultHandler(forURI: url.absoluteString)
            } else {
                store.releaseHiddenClickedPage(id)
                let options = ControlSessionOverlayOpenOptions(command: "", cwd: nil, wait: false, sizePercent: mode.overlaySizePercent,
                    backgroundColor: nil, page: .url(url), navigation: true, javascript: true, persistent: true, browse: true, clicked: true)
                _ = openSessionOverlay(id.uuidString, window: nil, options: options)
            }
        }
        return true
    }
}
