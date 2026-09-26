import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    static func paneSurfaceOpacities(
        isSplit: Bool, splitFocused: Bool, dimmed: Double, backdropActive: Bool
    ) -> (left: Double, right: Double) {
        guard !backdropActive else { return (1, 1) }
        return (isSplit && splitFocused ? dimmed : 1.0,
                isSplit && !splitFocused ? dimmed : 1.0)
    }

    static func paneOverlayWashOpacity(
        isSplit: Bool, splitFocused: Bool, pane: OverlayPane,
        scaledMuteOpacity: Double, backdropActive: Bool
    ) -> Double {
        guard isSplit, !backdropActive else { return 0 }
        let inactive = pane == .left ? splitFocused : !splitFocused
        return inactive ? scaledMuteOpacity : 0
    }

    static func scaledMuteOpacity(_ muteOpacity: Double, renderedWindowOpacity: Double) -> Double {
        min(1, max(0, muteOpacity)) * min(1, max(0, renderedWindowOpacity))
    }

    static func paneOverlayWashColor(fixedBackground: String?, themeBackground: String?) -> String {
        fixedBackground ?? themeBackground ?? "#000000"
    }

    func renderedWindowOpacity(_ override: Double? = nil) -> Double {
        let value = override ?? pendingBackgroundOpacity ?? linuxSettingsStore().load().backgroundOpacity ?? 1
        return min(1, max(0, value))
    }

    func updatePaneDim(_ s: Session, windowOpacity: Double? = nil) {
        let strength = linuxSettingsStore().load().inactivePaneMuteStrength ?? AppSettings.defaultInactivePaneMuteStrength
        let rawMuteOpacity = AppSettings.muteOpacity(strength: strength)
        let windowOpacity = renderedWindowOpacity(windowOpacity)
        let muteOpacity = Self.scaledMuteOpacity(rawMuteOpacity, renderedWindowOpacity: windowOpacity)
        let dimmed = 1.0 - muteOpacity
        let floatingProgram = s.programOverlayActive && s.overlaySizePercent != nil
        let backdropActive = s.id == store.selectedSessionID && (quickVisible || floatingProgram)
        let opacities = Self.paneSurfaceOpacities(
            isSplit: s.isSplit, splitFocused: s.splitFocused,
            dimmed: dimmed, backdropActive: backdropActive)
        if let main = surfaces[s.id] { gtk_widget_set_opacity(W(main.rootWidget), opacities.left) }
        if let split = splitSurfaces[s.id] { gtk_widget_set_opacity(W(split.rootWidget), opacities.right) }
        if let wash = leftOverlayWashes[s.id] {
            updatePaneOverlayWashColor(s, pane: .left)
            gtk_widget_set_opacity(W(wash), Self.paneOverlayWashOpacity(
                isSplit: s.isSplit, splitFocused: s.splitFocused, pane: .left,
                scaledMuteOpacity: muteOpacity, backdropActive: backdropActive))
        }
        if let wash = rightOverlayWashes[s.id] {
            updatePaneOverlayWashColor(s, pane: .right)
            gtk_widget_set_opacity(W(wash), Self.paneOverlayWashOpacity(
                isSplit: s.isSplit, splitFocused: s.splitFocused, pane: .right,
                scaledMuteOpacity: muteOpacity, backdropActive: backdropActive))
        }
    }

    private func updatePaneOverlayWashColor(_ session: Session, pane: OverlayPane) {
        guard let provider = paneOverlayWashProvider(session.id, pane: pane) else { return }
        let color = Self.paneOverlayWashColor(
            fixedBackground: session.paneOverlay(pane)?.backgroundColor,
            themeBackground: GhosttyApp.shared.currentThemeBackgroundHex)
        "* { background-color: \(color); }".withCString {
            gtk_css_provider_load_from_string(cast(provider), $0)
        }
    }

    /// Floating program cards and the quick terminal wash out the content behind them. HUDs stay passive
    /// and do not add a wash, matching the upstream overlay distinction.
    func updateCoverDimming(windowOpacity: Double? = nil) {
        let strength = linuxSettingsStore().load().inactivePaneMuteStrength
            ?? AppSettings.defaultInactivePaneMuteStrength
        let muteOpacity = Self.scaledMuteOpacity(
            AppSettings.muteOpacity(strength: strength),
            renderedWindowOpacity: renderedWindowOpacity(windowOpacity))
        let dimmed = 1.0 - muteOpacity
        gtk_widget_set_opacity(W(sidebarBox), quickVisible ? dimmed : 1.0)
        if let dashboardHost = dashboardRuntime.host {
            gtk_widget_set_opacity(W(dashboardHost), quickVisible ? dimmed : 1.0)
        }
        let floatingOpacity = Self.floatingFrameOpacity(quickVisible: quickVisible, dimmed: dimmed)
        for frame in floatingOverlayFrames.values { gtk_widget_set_opacity(W(frame), floatingOpacity) }
        guard let active = store.activeSession, let stack = sessionStacks[active.id], !dashboard.isOpen else {
            return
        }
        let floatingProgram = active.programOverlayActive && active.overlaySizePercent != nil
        gtk_widget_set_opacity(W(stack), quickVisible || floatingProgram ? dimmed : 1.0)
    }

    static func floatingFrameOpacity(quickVisible: Bool, dimmed: Double) -> Double {
        quickVisible ? dimmed : 1
    }

    func updateAllPaneDimming(windowOpacity: Double? = nil) {
        for workspace in store.workspaces {
            for session in workspace.sessions { updatePaneDim(session, windowOpacity: windowOpacity) }
        }
        updateCoverDimming(windowOpacity: windowOpacity)
    }
}
