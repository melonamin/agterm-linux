import agtermCore

extension GhosttyApp {
    /// Link selection may switch or free terminal surfaces. Run it after libghostty releases its callback locks.
    @MainActor
    static func queueTerminalLink(_ raw: String, source: LinkPolicy.ClickSource = .other, from surface: GhosttySurface?) {
        let hadSurface = surface != nil
        let reveal = surface?.linkBrowserOverride
        runOnMain { [weak surface] in MainActor.assumeIsolated {
            if hadSurface {
                guard let surface, surface.surface != nil else { return }
                if surface.openLink(raw, browserOverride: reveal, source: source) { return }
            }
            openTerminalURL(raw)
        } }
    }
}
