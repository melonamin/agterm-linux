import Foundation
import agtermCore

extension AppSettings {
    static let themeResetOSC = "\u{1B}]110\u{7}\u{1B}]111\u{7}"

    static let agtermThemeLines = [
        "background = #303030",
        "foreground = #ffffff",
        "selection-background = #5b5b5b",
        "selection-foreground = #dfdfff",
    ]

    static func themeOSC(from lines: [String]) -> String {
        let colors = ThemeColorResolver.colors(fromLines: lines)
        var osc = ""
        if let background = colors.background {
            osc += "\u{1B}]11;\(background)\u{7}"
        }
        if let foreground = colors.foreground {
            osc += "\u{1B}]10;\(foreground)\u{7}"
        }
        return osc
    }
}

struct ThemeColors: Equatable, Sendable {
    let background: String?
    let foreground: String?
    let selectionBackground: String?
    let selectionForeground: String?
}

enum ThemeColorResolver {
    static func colors(fromLines lines: [String]) -> ThemeColors {
        func value(_ key: String) -> String? {
            var found: String?
            for raw in lines {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                if line[..<eq].trimmingCharacters(in: .whitespaces) == key {
                    found = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            return found
        }
        return ThemeColors(
            background: value("background"),
            foreground: value("foreground"),
            selectionBackground: value("selection-background"),
            selectionForeground: value("selection-foreground")
        )
    }

    static func colors(forTheme theme: String?, themesDir: String?, fallbackLines: [String]) -> ThemeColors {
        if let theme, !theme.isEmpty, let dir = themesDir {
            let path = (dir as NSString).appendingPathComponent(theme)
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                return colors(fromLines: content.components(separatedBy: "\n"))
            }
        }
        return colors(fromLines: fallbackLines)
    }

    static func shiftedHex(_ hex: String, amount: Double) -> String {
        guard amount != 0 else { return hex }
        let h = hex.trimmingCharacters(in: .whitespaces)
        guard h.hasPrefix("#") else { return hex }
        let digits = String(h.dropFirst())
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return hex }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        func shift(_ c: Double) -> Int {
            let v = amount >= 0 ? c * (1 - amount) : c + (1 - c) * (-amount)
            return max(0, min(255, Int((v * 255).rounded())))
        }
        return String(format: "#%02X%02X%02X", shift(r), shift(g), shift(b))
    }

    /// Keep sidebar selection visible even when libghostty does not expose a selection color through
    /// `ghostty_config_get` (or a theme intentionally makes it equal to the terminal background).
    static func selectionHighlight(background: String, preferred: String?) -> String {
        if let preferred, preferred.caseInsensitiveCompare(background) != .orderedSame { return preferred }
        let trimmed = background.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.dropFirst()
        guard trimmed.hasPrefix("#"), digits.count == 6,
              let value = Int(digits, radix: 16) else { return preferred ?? background }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        let dark = ThemeBrightness.isDark(red: red, green: green, blue: blue)
        return shiftedHex(trimmed, amount: dark ? -0.18 : 0.14)
    }

    /// Overriding libadwaita's named colors (`@window_bg_color`, `@headerbar_bg_color`, `@view_bg_color`, …)
    /// re-themes the whole Adwaita stylesheet at once; the explicit `.agterm-sidebar` rules carry the
    /// shifted sidebar tint. Loaded by `AppController.applyWindowThemeColors` into the display-wide
    /// provider (priority 650); string-pinned in `GhosttyConfigThemeTests`.
    static func windowThemeCSS(
        background: String, foreground: String, selectionBackground: String,
        selectionForeground: String, sidebarBackground: String
    ) -> String {
        """
        @define-color window_bg_color \(background);
        @define-color window_fg_color \(foreground);
        @define-color view_bg_color \(background);
        @define-color view_fg_color \(foreground);
        @define-color headerbar_bg_color \(background);
        @define-color headerbar_backdrop_color \(background);
        @define-color headerbar_fg_color \(foreground);
        @define-color dialog_bg_color \(background);
        @define-color dialog_fg_color \(foreground);
        @define-color card_bg_color alpha(\(foreground), 0.08);
        @define-color card_fg_color \(foreground);
        @define-color card_shade_color alpha(#000000, 0.25);
        @define-color popover_bg_color \(background);
        @define-color popover_fg_color \(foreground);
        @define-color popover_shade_color alpha(#000000, 0.25);
        @define-color shade_color alpha(#000000, 0.25);
        @define-color sidebar_bg_color \(sidebarBackground);
        @define-color sidebar_fg_color \(foreground);
        .agterm-sidebar { background-color: \(sidebarBackground); }
        .agterm-sidebar list, .agterm-sidebar row { background-color: transparent; }
        .agterm-sidebar row.agterm-selected {
            background-color: \(selectionBackground);
            border-radius: 6px;
        }
        .agterm-sidebar label { color: \(foreground); }
        /* exact row-content path: a row-parented popover must not inherit the selection foreground */
        .agterm-sidebar row.agterm-selected > .agterm-session-row-content > label,
        .agterm-sidebar row.agterm-selected > .agterm-session-row-content > image { color: \(selectionForeground); }
        .agterm-sidebar button { color: \(foreground); }
        .agterm-sidebar separator { background-color: alpha(\(foreground), 0.22); }
        toolbarview.agterm-sidebar-column > .top-bar,
        toolbarview.agterm-sidebar-column > .bottom-bar { background-color: \(sidebarBackground); color: \(foreground); }
        paned.agterm-sidebar-split > separator {
            min-width: 1px; padding: 0 4px; background-color: alpha(\(foreground), 0.18); background-clip: content-box; box-shadow: none;
        }
        """
    }
}
