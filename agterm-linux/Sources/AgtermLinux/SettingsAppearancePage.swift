import CGtk
import agtermCore

@MainActor
extension AppController {
    func makeAppearanceSettingsPage(_ settings: AppSettings) -> OpaquePointer? {
        let page = preferencesPage(
            "Appearance", name: .appearance, icon: "applications-graphics-symbolic")
        let terminal = preferencesGroup("Terminal")

        let fonts = monospaceFonts()
        let fontValues = ["Default"] + fonts
        let fontIndex = settings.fontFamily.flatMap(fonts.firstIndex).map { $0 + 1 } ?? 0
        adw_preferences_group_add(
            cast(terminal),
            W(
                preferencesCombo(
                    "Font", values: fontValues, selected: fontIndex,
                    handler: unsafeBitCast(onSettingsFontFamily, to: GCallback.self))))

        let fontSize = OpaquePointer(adw_spin_row_new_with_range(8, 32, 1))
        "Default font size".withCString { adw_preferences_row_set_title(cast(fontSize), $0) }
        adw_spin_row_set_value(fontSize, settings.fontSize ?? 13)
        connect(fontSize, "notify::value", unsafeBitCast(onSettingsFontSize, to: GCallback.self))
        adw_preferences_group_add(cast(terminal), W(fontSize))

        let cursorStyles = ["Config default"] + AppSettings.CursorStyle.allCases.map {
            $0.rawValue.capitalized
        }
        let cursorIndex = settings.effectiveCursorStyle.flatMap(AppSettings.CursorStyle.allCases.firstIndex)
            .map { $0 + 1 } ?? 0
        adw_preferences_group_add(
            cast(terminal),
            W(preferencesCombo("Cursor shape", values: cursorStyles, selected: cursorIndex,
                               handler: unsafeBitCast(onSettingsCursorStyle, to: GCallback.self))))
        let blinkIndex = settings.cursorBlink.map { $0 ? 1 : 2 } ?? 0
        adw_preferences_group_add(
            cast(terminal),
            W(preferencesCombo("Cursor blink", values: ["Config default", "On", "Off"],
                               selected: blinkIndex,
                               handler: unsafeBitCast(onSettingsCursorBlink, to: GCallback.self))))

        let themes = Self.bundledThemes()
        let following = settings.followSystemAppearance == true
        let activeTheme = settings.activeTheme(isDark: Self.systemIsDark)
        let themeValues = following ? themes : ["default ghostty"] + themes
        let themeIndex = activeTheme.flatMap(themes.firstIndex).map { following ? $0 : $0 + 1 } ?? 0
        adw_preferences_group_add(
            cast(terminal),
            W(
                preferencesCombo(
                    "Theme", values: themeValues, selected: themeIndex,
                    handler: unsafeBitCast(onSettingsTheme, to: GCallback.self))))
        adw_preferences_group_add(
            cast(terminal),
            W(
                preferencesSwitch(
                    "Follow system appearance", active: settings.followSystemAppearance ?? false,
                    handler: unsafeBitCast(onSettingsFollowAppearance, to: GCallback.self))))
        if following {
            let alternateTheme = Self.systemIsDark ? settings.theme : settings.darkTheme
            let alternateIndex =
                alternateTheme.flatMap(themes.firstIndex)
                ?? themes.firstIndex(of: AppSettings.defaultTheme) ?? 0
            let alternateTitle = Self.systemIsDark ? "Light theme" : "Dark theme"
            let alternate = preferencesCombo(
                alternateTitle, values: themes, selected: alternateIndex,
                handler: unsafeBitCast(
                    onSettingsAlternateTheme,
                    to: GCallback.self))
            "Used for the other system appearance".withCString {
                adw_action_row_set_subtitle(cast(alternate), $0)
            }
            adw_preferences_group_add(cast(terminal), W(alternate))
        }
        let terminalReset = OpaquePointer(adw_action_row_new())
        "Terminal defaults".withCString { adw_preferences_row_set_title(cast(terminalReset), $0) }
        adw_action_row_add_suffix(
            cast(terminalReset),
            W(
                preferencesButton(
                    "Reset", handler: unsafeBitCast(onResetTerminalAppearance, to: GCallback.self))))
        adw_preferences_group_add(cast(terminal), W(terminalReset))
        adw_preferences_page_add(cast(page), cast(terminal))

        let window = preferencesGroup("Window")
        let toolbarIndex =
            settings.effectiveToolbarMode == .normal
            ? 0
            : (settings.effectiveToolbarMode == .hidden ? 2 : 1)
        adw_preferences_group_add(
            cast(window),
            W(
                preferencesCombo(
                    "Toolbar", values: ["Normal", "Compact", "Hidden"], selected: toolbarIndex,
                    handler: unsafeBitCast(onSettingsToolbarMode, to: GCallback.self))))

        let opacity = OpaquePointer(adw_spin_row_new_with_range(0, 100, 5))
        "Background opacity".withCString { adw_preferences_row_set_title(cast(opacity), $0) }
        "Your Wayland/X11 compositor owns background blur".withCString {
            adw_action_row_set_subtitle(cast(opacity), $0)
        }
        adw_spin_row_set_value(opacity, (settings.backgroundOpacity ?? 1) * 100)
        connect(
            opacity, "notify::value", unsafeBitCast(onSettingsBackgroundOpacity, to: GCallback.self))
        adw_preferences_group_add(cast(window), W(opacity))

        let tint = OpaquePointer(adw_spin_row_new_with_range(0, 10, 1))
        "Sidebar tint".withCString { adw_preferences_row_set_title(cast(tint), $0) }
        adw_spin_row_set_value(
            tint,
            Double(
                settings.sidebarBackgroundShift
                    ?? AppSettings.defaultSidebarBackgroundShift))
        connect(tint, "notify::value", unsafeBitCast(onSettingsSidebarTint, to: GCallback.self))
        adw_preferences_group_add(cast(window), W(tint))

        let sidebarFont = OpaquePointer(
            adw_spin_row_new_with_range(
                AppSettings.sidebarFontSizeRange.lowerBound, AppSettings.sidebarFontSizeRange.upperBound, 1)
        )
        "Sidebar font size".withCString { adw_preferences_row_set_title(cast(sidebarFont), $0) }
        adw_spin_row_set_value(
            sidebarFont, settings.sidebarFontSize ?? AppSettings.defaultSidebarFontSize)
        connect(sidebarFont, "notify::value", unsafeBitCast(onSettingsSidebarFont, to: GCallback.self))
        adw_preferences_group_add(cast(window), W(sidebarFont))

        let interfaceFont = OpaquePointer(
            adw_spin_row_new_with_range(
                AppSettings.interfaceFontSizeRange.lowerBound,
                AppSettings.interfaceFontSizeRange.upperBound, 1)
        )
        "Interface font size".withCString { adw_preferences_row_set_title(cast(interfaceFont), $0) }
        "Command palette, pickers, and session switcher".withCString {
            adw_action_row_set_subtitle(cast(interfaceFont), $0)
        }
        adw_spin_row_set_value(
            interfaceFont, settings.interfaceFontSize ?? AppSettings.defaultInterfaceFontSize)
        connect(interfaceFont, "notify::value", unsafeBitCast(onSettingsInterfaceFont, to: GCallback.self))
        adw_preferences_group_add(cast(window), W(interfaceFont))

        let quickChoices = QuickTerminalMetrics.sizePercentChoices
        let quickIndex = settings.quickTerminalSizePercent.flatMap(quickChoices.firstIndex)
            .map { $0 + 1 } ?? 0
        adw_preferences_group_add(
            cast(window),
            W(preferencesCombo("Quick terminal size",
                               values: ["Default (90%)"] + quickChoices.map { "\($0)%" },
                               selected: quickIndex,
                               handler: unsafeBitCast(onSettingsQuickTerminalSize, to: GCallback.self))))

        let mute = OpaquePointer(adw_spin_row_new_with_range(0, 10, 1))
        "Inactive pane mute".withCString { adw_preferences_row_set_title(cast(mute), $0) }
        adw_spin_row_set_value(
            mute,
            Double(
                settings.inactivePaneMuteStrength
                    ?? AppSettings.defaultInactivePaneMuteStrength))
        connect(mute, "notify::value", unsafeBitCast(onSettingsInactivePaneMute, to: GCallback.self))
        adw_preferences_group_add(cast(window), W(mute))

        let windowReset = OpaquePointer(adw_action_row_new())
        "Window defaults".withCString { adw_preferences_row_set_title(cast(windowReset), $0) }
        adw_action_row_add_suffix(
            cast(windowReset),
            W(
                preferencesButton(
                    "Reset", handler: unsafeBitCast(onResetWindowAppearance, to: GCallback.self))))
        adw_preferences_group_add(cast(window), W(windowReset))
        adw_preferences_page_add(cast(page), cast(window))
        return page
    }
}

private let onSettingsFontFamily: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setFontFamilyAtIndex(Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsFontSize: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { controllerForWidget(row)?.setFontSize(adw_spin_row_get_value(row)) }
}
private let onSettingsCursorStyle: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setCursorStyleAtIndex(Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsCursorBlink: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setCursorBlinkAtIndex(Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsTheme: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.applyThemeAtIndex(Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsFollowAppearance: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setFollowSystemAppearance(adw_switch_row_get_active(row) != 0)
    }
}
private let onSettingsAlternateTheme: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setAlternateThemeAtIndex(Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsToolbarMode: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setToolbarModeAtIndex(Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsBackgroundOpacity: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { controllerForWidget(row)?.setBackgroundOpacity(adw_spin_row_get_value(row)) }
}
private let onSettingsSidebarTint: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { controllerForWidget(row)?.setSidebarTint(adw_spin_row_get_value(row)) }
}
private let onSettingsSidebarFont: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { controllerForWidget(row)?.setSidebarFontSize(adw_spin_row_get_value(row)) }
}
private let onSettingsInterfaceFont: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { controllerForWidget(row)?.setInterfaceFontSize(adw_spin_row_get_value(row)) }
}
private let onSettingsQuickTerminalSize: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated {
        controllerForWidget(row)?.setQuickTerminalSizeAtIndex(Int(adw_combo_row_get_selected(cast(row))))
    }
}
private let onSettingsInactivePaneMute: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { row, _, _ in
    MainActor.assumeIsolated { controllerForWidget(row)?.setInactivePaneMute(adw_spin_row_get_value(row)) }
}
private let onResetTerminalAppearance: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.resetTerminalAppearance() }
}
private let onResetWindowAppearance: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.resetWindowAppearance() }
}
