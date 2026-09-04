import CGtk
import Foundation
import agtermCore

/// Theme resolution for the chrome: reads chrome colors from libghostty's finalized configuration (after
/// global/scoped files, recursive `config-file` imports, and agterm's UI settings have all been resolved),
/// and — in the `AppController` extension below — owns the theme apply/persist path plus the unpersisted
/// live-preview override every preview-path reader resolves through.
enum GhosttyConfigTheme {
    struct RGB: Equatable, Sendable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    static func colors(from config: ghostty_config_t) -> ThemeColors {
        colors { color(from: config, key: $0) }
    }

    static func colors(read: (String) -> RGB?) -> ThemeColors {
        ThemeColors(
            background: read("background").map(hex),
            foreground: read("foreground").map(hex),
            selectionBackground: read("selection-background").map(hex),
            selectionForeground: read("selection-foreground").map(hex)
        )
    }

    private static func color(from config: ghostty_config_t, key: String) -> RGB? {
        var color = ghostty_config_color_s()
        let found = key.withCString {
            ghostty_config_get(config, &color, $0, UInt(key.utf8.count))
        }
        guard found else { return nil }
        return RGB(red: color.r, green: color.g, blue: color.b)
    }

    private static func hex(_ color: RGB) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }
}

@MainActor
extension AppController {
    /// The theme picker's UNPERSISTED preview settings, while a preview is live. Readers that
    /// re-derive chrome colors from settings (`applyResolvedWindowThemeColors`, reached from every
    /// surface's `config_change` action) must resolve through this instead of the persisted store —
    /// else each preview's own surface-config updates trigger a re-resolve of the OLD persisted
    /// theme that stomps the just-previewed chrome (the sidebar "flashes then reverts" bug).
    /// Set by `previewTheme`, cleared on commit (`applyTheme`) and by `teardownThemePicker` (every picker
    /// exit path). Read it through `resolvedThemeSettings(persisted:)`, never directly.
    static var themePreviewSettings: AppSettings?

    /// The settings a preview or a commit applies for `name`: `base` with the theme pinned to ONE
    /// appearance-independent value (an empty/nil name clears back to ghostty's built-in default). Pure, so
    /// the branches are unit-tested; the two callers differ only in whether they persist the result.
    static func themeSettings(_ name: String?, base: AppSettings) -> AppSettings {
        var settings = base
        settings.theme = (name?.isEmpty == false) ? name : nil
        settings.darkTheme = nil
        settings.followSystemAppearance = nil
        return settings
    }

    /// Settings as every PREVIEW-PATH reader must see them: the live picker preview while one is active,
    /// else what is persisted. The ONE place that precedence is spelled out — a new reader on a
    /// preview-reachable path calls this instead of rediscovering the rule. `persisted` is an autoclosure
    /// so the disk read is skipped while a preview is up.
    static func resolvedThemeSettings(persisted: @autoclosure () -> AppSettings) -> AppSettings {
        themePreviewSettings ?? persisted()
    }

    /// Preview one theme as a single appearance-independent value without persisting it.
    func previewTheme(_ name: String?) {
        let settings = Self.themeSettings(name, base: linuxSettingsStore().load())
        Self.themePreviewSettings = settings
        applySettings(settings)
    }

    /// Apply a ghostty theme to every live surface and persist it so it survives relaunch.
    func applyTheme(_ name: String?) {
        Self.themePreviewSettings = nil
        let settings = Self.themeSettings(name, base: linuxSettingsStore().load())
        try? linuxSettingsStore().save(settings)
        applySettings(settings)
    }

    /// Rebuild the same finalized config used by the terminal when a chrome-only setting changes.
    /// Resolves through the live theme-picker preview when one is active — this runs off every
    /// surface's `config_change` action, so during a preview the persisted (old) theme would
    /// otherwise repaint the chrome right after the preview did.
    func applyResolvedWindowThemeColors() {
        let settings = AppController.resolvedThemeSettings(persisted: linuxSettingsStore().load())
        let isDark = Self.systemIsDark
        let lines = Self.ghosttyLines(for: settings, isDark: isDark)
        guard let config = GhosttyApp.shared.buildConfig(extraLines: lines) else { return }
        defer { ghostty_config_free(config) }
        applyWindowThemeColors(
            for: settings.activeTheme(isDark: isDark),
            resolvedColors: GhosttyConfigTheme.colors(from: config))
    }
}
