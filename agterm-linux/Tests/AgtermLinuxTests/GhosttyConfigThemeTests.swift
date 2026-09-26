import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Resolved Ghostty chrome colors")
struct GhosttyConfigThemeTests {
    @Test("resolved config channels drive the chrome palette")
    func resolvedChannels() {
        let values: [String: GhosttyConfigTheme.RGB] = [
            "background": .init(red: 255, green: 252, blue: 240),
            "foreground": .init(red: 16, green: 15, blue: 15),
            "selection-background": .init(red: 206, green: 205, blue: 195),
            "selection-foreground": .init(red: 32, green: 94, blue: 166),
        ]

        #expect(
            GhosttyConfigTheme.colors(read: { values[$0] })
                == ThemeColors(
                    background: "#FFFCF0",
                    foreground: "#100F0F",
                    selectionBackground: "#CECDC3",
                    selectionForeground: "#205EA6"))
    }

    @Test("sidebar selection keeps a distinct supplied theme color")
    func suppliedSelectionHighlight() {
        #expect(
            ThemeColorResolver.selectionHighlight(background: "#303030", preferred: "#5B5B5B")
                == "#5B5B5B")
    }

    @Test("sidebar selection derives contrast when the resolved color is absent")
    func derivedSelectionHighlight() {
        #expect(ThemeColorResolver.selectionHighlight(background: "#303030", preferred: nil) == "#555555")
        #expect(ThemeColorResolver.selectionHighlight(background: "#FFFCF0", preferred: nil) == "#DBD9CE")
    }

    @Test("window theme CSS emits the chrome palette and the row-scoped selection tint")
    func windowThemeCSS() {
        // Five distinct sentinels, so a transposed parameter cannot emit the same string.
        let expected = """
        @define-color window_bg_color #111111;
        @define-color window_fg_color #222222;
        @define-color view_bg_color #111111;
        @define-color view_fg_color #222222;
        @define-color headerbar_bg_color #111111;
        @define-color headerbar_backdrop_color #111111;
        @define-color headerbar_fg_color #222222;
        @define-color dialog_bg_color #111111;
        @define-color dialog_fg_color #222222;
        @define-color card_bg_color alpha(#222222, 0.08);
        @define-color card_fg_color #222222;
        @define-color card_shade_color alpha(#000000, 0.25);
        @define-color popover_bg_color #111111;
        @define-color popover_fg_color #222222;
        @define-color popover_shade_color alpha(#000000, 0.25);
        @define-color shade_color alpha(#000000, 0.25);
        @define-color sidebar_bg_color #555555;
        @define-color sidebar_fg_color #222222;
        .agterm-sidebar { background-color: #555555; }
        .agterm-sidebar list, .agterm-sidebar row { background-color: transparent; }
        .agterm-sidebar row.agterm-selected {
            background-color: #333333;
            border-radius: 6px;
        }
        .agterm-sidebar label { color: #222222; }
        /* exact row-content path: a row-parented popover must not inherit the selection foreground */
        .agterm-sidebar row.agterm-selected > .agterm-session-row-content > label,
        .agterm-sidebar row.agterm-selected > .agterm-session-row-content > image { color: #444444; }
        .agterm-sidebar button { color: #222222; }
        .agterm-sidebar separator { background-color: alpha(#222222, 0.22); }
        toolbarview.agterm-sidebar-column > .top-bar,
        toolbarview.agterm-sidebar-column > .bottom-bar { background-color: #555555; color: #222222; }
        paned.agterm-sidebar-split > separator {
            min-width: 1px; padding: 0 4px; background-color: alpha(#222222, 0.18); background-clip: content-box; box-shadow: none;
        }
        """

        let css = ThemeColorResolver.windowThemeCSS(
            background: "#111111", foreground: "#222222", selectionBackground: "#333333",
            selectionForeground: "#444444", sidebarBackground: "#555555")

        #expect(css == expected)
        #expect(css.contains("\n.agterm-sidebar row.agterm-selected > .agterm-session-row-content > label,"))
        #expect(!css.contains("\n.agterm-selected"))
    }
}

/// The theme-picker preview override: the builder both the preview and the commit path share, and the
/// precedence every preview-path settings reader resolves through. Serialized because
/// `AppController.themePreviewSettings` is a process-global static.
@MainActor
@Suite(.serialized)
struct AppControllerThemeSettingsTests {
    @Test("a theme name pins one appearance-independent theme and keeps the rest of the settings")
    func themeSettingsPinsTheName() {
        var base = AppSettings()
        base.theme = "old"
        base.darkTheme = "old-dark"
        base.followSystemAppearance = true
        base.sidebarFontSize = 13
        let settings = AppController.themeSettings("Nord", base: base)
        #expect(settings.theme == "Nord")
        #expect(settings.darkTheme == nil)          // one value, so a system appearance flip cannot undo it
        #expect(settings.followSystemAppearance == nil)
        #expect(settings.sidebarFontSize == 13)     // unrelated settings survive the theme change
    }

    @Test("an empty or absent name clears back to ghostty's built-in default")
    func themeSettingsClearsForEmptyNames() {
        var base = AppSettings()
        base.theme = "old"
        #expect(AppController.themeSettings(nil, base: base).theme == nil)
        #expect(AppController.themeSettings("", base: base).theme == nil)
    }

    @Test("preview-path readers see the live preview, and the persisted theme once it is cleared")
    func resolvedThemeSettingsPrefersTheLivePreview() {
        AppController.themePreviewSettings = nil
        defer { AppController.themePreviewSettings = nil }
        var persisted = AppSettings()
        persisted.theme = "persisted"

        #expect(AppController.resolvedThemeSettings(persisted: persisted).theme == "persisted")

        var preview = AppSettings()
        preview.theme = "preview"
        AppController.themePreviewSettings = preview
        // this is the reported bug: while a preview is up, a config_change re-resolve must NOT fall back to
        // the persisted theme and repaint the chrome with it
        #expect(AppController.resolvedThemeSettings(persisted: persisted).theme == "preview")

        AppController.themePreviewSettings = nil    // what every picker exit path must do
        #expect(AppController.resolvedThemeSettings(persisted: persisted).theme == "persisted")
    }
}
