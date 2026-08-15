import CGtk
import Foundation
import agtermCore

@MainActor func synchronizeLiveColorScheme(_ side: LinuxAppearanceSide) {
    GhosttyApp.shared.applyColorScheme(side)
    for controller in gWindows.values {
        for surface in controller.configurableSurfaces {
            surface.applyColorScheme(side)
        }
    }
}

@MainActor
extension AppController {
    @discardableResult
    func applySettings(
        _ settings: AppSettings,
        preserveSessionConfig: Bool = false,
        appearanceSide: LinuxAppearanceSide? = nil
    ) -> Bool {
        let side = appearanceSide ?? LinuxAppearanceSide(isDark: Self.systemIsDark)
        let lines = Self.ghosttyLines(for: settings, isDark: side.isDark)
        guard let config = GhosttyApp.shared.buildConfig(extraLines: lines) else { return false }
        let chromeColors = GhosttyConfigTheme.colors(from: config)
        GhosttyApp.shared.currentThemeBackgroundHex = chromeColors.background
        synchronizeLiveColorScheme(side)
        GhosttyApp.shared.updateConfig(config)
        for controller in gWindows.values {
            for surface in controller.configurableSurfaces {
                surface.applyConfig(config)
                if preserveSessionConfig {
                    surface.reapplySessionConfigIfNeeded(
                        windowOpacity: settings.backgroundOpacity ?? 1, settings: settings)
                } else {
                    surface.reapplyWatermarkIfNeeded(
                        windowOpacity: settings.backgroundOpacity ?? 1, settings: settings)
                }
            }
        }
        ghostty_config_free(config)

        let osc = AppSettings.themeOSC(from: lines)
        let activeTheme = settings.activeTheme(isDark: side.isDark)
        let liveOSC = osc.isEmpty && activeTheme == nil ? AppSettings.themeResetOSC : osc
        GhosttyApp.shared.currentThemeOSC = liveOSC
        for controller in gWindows.values {
            for surface in controller.configurableSurfaces {
                surface.feed(liveOSC)
                surface.queueRender()
            }
            controller.applyWindowThemeColors(for: activeTheme, resolvedColors: chromeColors)
            controller.updateAllPaneDimming(windowOpacity: settings.backgroundOpacity ?? 1)
        }
        recordAppliedColorSchemeSide(side)
        return true
    }

    /// Automatic appearance reconciliation restores complete per-session overlays.
    /// Explicit config reload stays watermark-only.
    func reloadConfigForAppearanceChange(_ side: LinuxAppearanceSide) -> Bool {
        applySettings(
            linuxSettingsStore().load(), preserveSessionConfig: true, appearanceSide: side)
    }

    func persist<V>(_ keyPath: WritableKeyPath<AppSettings, V>, _ value: V) {
        var settings = linuxSettingsStore().load()
        settings[keyPath: keyPath] = value
        try? linuxSettingsStore().save(settings)
    }

    func setToolbarModeAtIndex(_ index: Int) {
        let mode: ToolbarMode = index == 0 ? .normal : (index == 2 ? .hidden : .compact)
        var settings = linuxSettingsStore().load()
        settings.toolbarMode = mode == .compact ? nil : mode.rawValue
        settings.compactToolbar = nil
        try? linuxSettingsStore().save(settings)
        for controller in gWindows.values { controller.applyToolbarMode() }
    }

    func setRestoreRunningCommand(_ enabled: Bool) { persist(\.restoreRunningCommand, enabled ? true : nil) }
    func setConfirmCloseSession(_ enabled: Bool) { persist(\.confirmCloseSession, enabled ? true : nil) }
    func setCloseGraceUndo(_ enabled: Bool) { persist(\.closeGraceUndoEnabled, enabled ? nil : false) }
    func setNotificationsEnabled(_ enabled: Bool) { persist(\.notificationsEnabled, enabled ? nil : false) }

    func setNotificationBadge(_ enabled: Bool) {
        persist(\.notificationBadgeEnabled, enabled ? nil : false)
        for controller in gWindows.values {
            controller.badgeEnabled = enabled
            controller.rebuildSidebar()
        }
    }

    func setAttentionButtonEnabled(_ enabled: Bool) {
        persist(\.attentionButtonEnabled, enabled ? true : nil)
        for controller in gWindows.values {
            controller.updateAttentionButton()
            controller.applyInterfaceElements()
        }
    }

    func setInterfaceElementVisible(_ element: InterfaceElement, visible: Bool) {
        var settings = linuxSettingsStore().load()
        var hidden = Set(settings.hiddenInterfaceElements ?? [])
        if visible {
            hidden.remove(element.rawValue)
        } else {
            hidden.insert(element.rawValue)
        }
        settings.hiddenInterfaceElements = hidden.isEmpty ? nil : hidden.sorted()
        try? linuxSettingsStore().save(settings)
        for controller in gWindows.values {
            controller.applyInterfaceElements(settings: settings)
            controller.rebuildSidebar()
        }
    }

    func setAutoHideInactiveSidebars(_ enabled: Bool) {
        persist(\.autoHideSidebarInactiveWindows, enabled ? true : nil)
        if enabled { applyInactiveWindowSidebarHidingIfEnabled() }
    }

    func setWorkspaceRowClickExpands(_ enabled: Bool) {
        persist(\.workspaceRowClickExpands, enabled ? nil : false)
    }

    func applyInactiveWindowSidebarHidingIfEnabled() {
        guard linuxSettingsStore().load().autoHideSidebarInactiveWindows == true else { return }
        library.applyInactiveWindowSidebarHiding()
        for controller in gWindows.values { controller.applySidebarVisibility() }
    }

    func applyInterfaceElements(settings: AppSettings? = nil) {
        let settings = settings ?? linuxSettingsStore().load()
        let hidden = settings.resolvedHiddenInterfaceElements
        for (element, widget) in interfaceWidgets {
            gtk_widget_set_visible(W(widget), hidden.contains(element) ? 0 : 1)
        }
        let countA = (hidden.contains(.recentSessions) ? 0 : 1)
            + ((settings.attentionButtonEnabled ?? false) ? 1 : 0)
        let countB = (hidden.contains(.scratch) ? 0 : 1) + (hidden.contains(.split) ? 0 : 1)
        let countC = (hidden.contains(.dashboard) ? 0 : 1) + (hidden.contains(.quickTerminal) ? 0 : 1)
        let dividers = InterfaceElement.titlebarGroupDividers(countA: countA, countB: countB, countC: countC)
        gtk_widget_set_visible(W(titlebarDividerAfterA), dividers.afterA ? 1 : 0)
        gtk_widget_set_visible(W(titlebarDividerAfterB), dividers.afterB ? 1 : 0)
        let footerVisible = !hidden.isSuperset(
            of: [.newWorkspace, .newSession, .flaggedView, .focusFilter])
        gtk_widget_set_visible(W(bottomBar), footerVisible ? 1 : 0)
        updateTitle()
    }

    func setNewSessionDirectoryAtIndex(_ index: Int) {
        let mode: AppSettings.NewSessionDirectory = index == 1 ? .currentSession : (index == 2 ? .custom : .home)
        persist(\.newSessionDirectory, mode == .home ? nil : mode.rawValue)
    }

    func setNewSessionCustomDirectory(_ path: String) {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        persist(\.newSessionCustomDirectory, value.isEmpty ? nil : value)
        if let row = settingsCustomDirectoryRow {
            (value.isEmpty ? "Not set" : value).withCString { adw_action_row_set_subtitle(cast(row), $0) }
        }
    }

    func setRightClickPaste(_ enabled: Bool) {
        persist(\.rightClickPaste, enabled ? nil : false)
        reloadConfig()
    }

    func setScrollSpeed(_ value: Double) {
        persist(\.mouseScrollMultiplier, value == 3 ? nil : value)
        reloadConfig()
    }

    func setInheritGlobalGhosttyConfig(_ enabled: Bool) {
        persist(\.inheritGlobalGhosttyConfig, enabled ? true : nil)
        reloadConfig()
    }

    func setConfigDirectory(_ path: String?) {
        let value = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        persist(\.configDirectory, value?.isEmpty == false ? value : nil)
        ensureStarterFiles()
        // Through the seam, not a hand-written `gWindows` loop: a new config directory means a DIFFERENT
        // keymap.conf, so every window must re-parse. The old loop bannered errors once PER WINDOW (each
        // `reloadKeymapDiagnostics()` toasted its own count); this reports at most once, in this window.
        // Do NOT read that banner as this path's user-visible reporting: an AdwToast lands on the window
        // CONTENT, under the Settings dialog the user is still in. What they actually read is the Key
        // Mapping page's Diagnostics group, which the caller rebuilds right after with the per-line detail.
        reloadKeymapAllWindows(reportingIn: self)
        reloadConfig()
    }

    func setFontSize(_ value: Double) {
        persist(\.fontSize, value == 13 ? nil : value)
        reloadConfig()
        library.resetSessionFontSizesAllWindows()
    }

    func setFontFamilyAtIndex(_ index: Int) {
        let fonts = monospaceFonts()
        let value = index == 0 ? nil : fonts.indices.contains(index - 1) ? fonts[index - 1] : nil
        persist(\.fontFamily, value)
        reloadConfig()
    }

    func applyThemeAtIndex(_ index: Int) {
        let themes = Self.bundledThemes()
        var settings = linuxSettingsStore().load()
        let following = settings.followSystemAppearance == true
        let value = following
            ? (themes.indices.contains(index) ? themes[index] : nil)
            : (index == 0 ? nil : (themes.indices.contains(index - 1) ? themes[index - 1] : nil))
        if following {
            if Self.systemIsDark { settings.darkTheme = value } else { settings.theme = value }
        } else {
            settings.theme = value
            settings.darkTheme = nil
            settings.followSystemAppearance = nil
        }
        try? linuxSettingsStore().save(settings)
        applySettings(settings)
    }

    func setAlternateThemeAtIndex(_ index: Int) {
        let themes = Self.bundledThemes()
        guard themes.indices.contains(index) else { return }
        var settings = linuxSettingsStore().load()
        if Self.systemIsDark {
            settings.theme = themes[index]
        } else {
            settings.darkTheme = themes[index]
        }
        settings.followSystemAppearance = true
        try? linuxSettingsStore().save(settings)
        applySettings(settings)
    }

    func setFollowSystemAppearance(_ enabled: Bool) {
        var settings = linuxSettingsStore().load()
        if enabled {
            let current = settings.theme
            settings.theme = current ?? "Builtin Light"
            settings.darkTheme = settings.darkTheme ?? current ?? AppSettings.defaultTheme
            settings.followSystemAppearance = true
        } else {
            if Self.systemIsDark { settings.theme = settings.darkTheme ?? settings.theme }
            settings.darkTheme = nil
            settings.followSystemAppearance = nil
        }
        try? linuxSettingsStore().save(settings)
        applySettings(settings)
        rebuildSettings(page: .appearance)
    }

    func setBackgroundOpacity(_ percent: Double) {
        for controller in gWindows.values { controller.cancelPendingBackgroundOpacity() }
        cancelPendingBackgroundOpacity()
        pendingBackgroundOpacity = percent >= 100 ? nil : percent / 100
        backgroundOpacityPending = true
        var settings = linuxSettingsStore().load()
        settings.backgroundOpacity = pendingBackgroundOpacity
        applySettings(settings)
        for controller in gWindows.values { controller.applyWindowTranslucency(settings: settings) }
        if backgroundSettingsSource != 0 { g_source_remove(backgroundSettingsSource) }
        backgroundSettingsSource = g_timeout_add(300, onBackgroundSettingsCommit,
                                                  Unmanaged.passUnretained(self).toOpaque())
    }

    func commitBackgroundOpacity() {
        guard backgroundOpacityPending else { return }
        if backgroundSettingsSource != 0 {
            g_source_remove(backgroundSettingsSource)
            backgroundSettingsSource = 0
        }
        let value = pendingBackgroundOpacity
        persist(\.backgroundOpacity, value)
        pendingBackgroundOpacity = nil
        backgroundOpacityPending = false
        // A different setting may have reloaded the last persisted opacity while this value was debounced.
        // Reapply the committed snapshot so live Ghostty/window composition matches settings.json immediately.
        let settings = linuxSettingsStore().load()
        applySettings(settings)
        for controller in gWindows.values { controller.applyWindowTranslucency(settings: settings) }
    }

    func cancelPendingBackgroundOpacity() {
        if backgroundSettingsSource != 0 {
            g_source_remove(backgroundSettingsSource)
            backgroundSettingsSource = 0
        }
        pendingBackgroundOpacity = nil
        backgroundOpacityPending = false
    }

    func setSidebarTint(_ value: Double) {
        let strength = Int(value)
        persist(\.sidebarBackgroundShift,
                strength == AppSettings.defaultSidebarBackgroundShift ? nil : strength)
        for controller in gWindows.values { controller.applySidebarThemeColor() }
    }

    func setSidebarFontSize(_ value: Double) {
        let size = AppSettings.clampSidebarFontSize(value)
        persist(\.sidebarFontSize, size == AppSettings.defaultSidebarFontSize ? nil : size)
        for controller in gWindows.values {
            controller.applySidebarFontSize()
            controller.rebuildSidebar()
        }
    }

    func setInterfaceFontSize(_ value: Double) {
        let size = AppSettings.clampInterfaceFontSize(value)
        persist(\.interfaceFontSize, size == AppSettings.defaultInterfaceFontSize ? nil : size)
        for controller in gWindows.values { controller.applyInterfaceFontSize() }
    }

    func setInactivePaneMute(_ value: Double) {
        let strength = Int(value)
        persist(\.inactivePaneMuteStrength,
                strength == AppSettings.defaultInactivePaneMuteStrength ? nil : strength)
        for controller in gWindows.values { controller.updateAllPaneDimming() }
    }

    enum StatusColorKind { case active, blocked, completed }

    func setStatusColor(_ kind: StatusColorKind, fromButton button: OpaquePointer?) {
        guard let button, let rgba = gtk_color_dialog_button_get_rgba(button) else { return }
        let hex = String(format: "#%02X%02X%02X", Int((rgba.pointee.red * 255).rounded()),
                         Int((rgba.pointee.green * 255).rounded()), Int((rgba.pointee.blue * 255).rounded()))
        switch kind {
        case .active: persist(\.activeStatusColorHex, hex)
        case .blocked: persist(\.blockedStatusColorHex, hex)
        case .completed: persist(\.completedStatusColorHex, hex)
        }
        installStatusColorCSS()
    }

    func setStatusShape(_ kind: StatusColorKind, at index: Int) {
        let shapes = StatusShape.allCases
        guard shapes.indices.contains(index) else { return }
        let value = shapes[index] == .circle ? nil : shapes[index].rawValue
        switch kind {
        case .active: persist(\.activeStatusShape, value)
        case .blocked: persist(\.blockedStatusShape, value)
        case .completed: persist(\.completedStatusShape, value)
        }
        for controller in gWindows.values {
            controller.rebuildSidebar()
            controller.updateDashboardStatusIndicators()
        }
    }

    func setBlockedSoundAtIndex(_ index: Int) {
        let value: String? = index == 0 ? nil : "Desktop Bell"
        persist(\.blockedStatusSoundName, value)
        if let value { StatusSoundPlayer.shared.play(value) }
    }

    func setAutoFollowAtIndex(_ index: Int) {
        let values = AppSettings.AutoFollowAttention.allCases
        guard values.indices.contains(index) else { return }
        let value = values[index]
        persist(\.autoFollowAttention, value == .off ? nil : value.rawValue)
        for controller in gWindows.values { controller.applyAutoFollowSettings() }
        if let row = settingsAutoFollowAwayRow { gtk_widget_set_sensitive(W(row), value == .off ? 0 : 1) }
    }

    func setAutoFollowAwayFromRunning(_ enabled: Bool) {
        persist(\.autoFollowStayOnActive, enabled ? nil : true)
        for controller in gWindows.values { controller.applyAutoFollowSettings() }
    }

    func applyAutoFollowSettings() {
        let settings = linuxSettingsStore().load()
        let timeout = AppSettings.AutoFollowAttention(tolerant: settings.autoFollowAttention).timeout
        let stayOnActive = settings.autoFollowStayOnActive ?? false
        // Keep the upstream DispatchQueue timer disabled under GTK. Linux owns the equivalent GLib
        // runtime, while AppStore.noteUserActivity still supplies the shared control API's idle metric.
        store.setAutoFollow(timeout: nil, stayOnActive: stayOnActive)
        autoFollowCoordinator.configure(timeout: timeout, stayOnActive: stayOnActive)
    }

    func resetTerminalAppearance() {
        var settings = linuxSettingsStore().load()
        settings.fontFamily = nil
        settings.fontSize = nil
        settings.theme = AppSettings.defaultTheme
        settings.darkTheme = nil
        settings.followSystemAppearance = nil
        try? linuxSettingsStore().save(settings)
        reloadConfig()
        library.resetSessionFontSizesAllWindows()
        rebuildSettings(page: .appearance)
    }

    func resetWindowAppearance() {
        for controller in gWindows.values { controller.cancelPendingBackgroundOpacity() }
        cancelPendingBackgroundOpacity()
        var settings = linuxSettingsStore().load()
        settings.toolbarMode = nil
        settings.compactToolbar = nil
        settings.backgroundOpacity = nil
        settings.sidebarBackgroundShift = nil
        settings.sidebarFontSize = nil
        settings.interfaceFontSize = nil
        settings.inactivePaneMuteStrength = nil
        try? linuxSettingsStore().save(settings)
        reloadConfig()
        for controller in gWindows.values {
            controller.applyToolbarMode()
            controller.applyWindowTranslucency()
            controller.applySidebarFontSize()
            controller.applyInterfaceFontSize()
            controller.updateAllPaneDimming()
            controller.rebuildSidebar()
        }
        rebuildSettings(page: .appearance)
    }

    func resetAgentStatus() {
        var settings = linuxSettingsStore().load()
        settings.activeStatusColorHex = nil
        settings.blockedStatusColorHex = nil
        settings.completedStatusColorHex = nil
        settings.activeStatusShape = nil
        settings.blockedStatusShape = nil
        settings.completedStatusShape = nil
        settings.blockedStatusSoundName = nil
        try? linuxSettingsStore().save(settings)
        installStatusColorCSS()
        rebuildSettings(page: .agentStatus)
    }
}

private let onBackgroundSettingsCommit: @MainActor @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    MainActor.assumeIsolated {
        let controller = Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue()
        controller.backgroundSettingsSource = 0
        controller.commitBackgroundOpacity()
    }
    return 0
}
