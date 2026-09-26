import agtermCore

enum FontBindingAction {
    static let increase = "increase_font_size:1"
    static let decrease = "decrease_font_size:1"
    static let reset = "reset_font_size"
}

/// Chrome tooltips rendered FROM the Linux default-chord table, so a title-bar hint and the keymap
/// default cannot disagree.
///
/// These strings are contract, not decoration: an icon-only GtkButton exposes its tooltip as its AT-SPI
/// accessible NAME, and the e2e scenarios look buttons up by exact tooltip text.
///
/// The DEFAULT chord, not the effective one — the header is built before `reloadKeymapDiagnostics()`
/// runs, so a user's `keymap.conf` override is not known yet.
enum LinuxChromeTooltip {
    /// `"Toggle Sidebar (Ctrl+Shift+S)"`, or the bare title when the action has no default chord.
    static func text(_ title: String, _ action: BuiltinAction) -> String {
        guard let chord = action.linuxDefaultChord else { return title }
        return text(title, shortcut: label(chord))
    }

    /// Escape hatch for a chord with NO `BuiltinAction` behind it: Ctrl+Tab is a reserved monitor chord,
    /// so it is deliberately absent from `linuxDefaultChord`.
    static func text(_ title: String, shortcut: String) -> String {
        "\(title) (\(shortcut))"
    }

    /// `"Ctrl+Shift+S"`, ``"Ctrl+`"``. Modifier order mirrors `Chord.displayString`; on Linux `.command`
    /// is Super and `.option` is Alt.
    static func label(_ chord: Chord) -> String {
        var parts: [String] = []
        if chord.mods.contains(.control) { parts.append("Ctrl") }
        if chord.mods.contains(.command) { parts.append("Super") }
        if chord.mods.contains(.option) { parts.append("Alt") }
        if chord.mods.contains(.shift) { parts.append("Shift") }
        parts.append(chord.key.count == 1 ? chord.key.uppercased() : chord.key.capitalized)
        return parts.joined(separator: "+")
    }
}

extension BuiltinAction {
    var linuxDefaultChord: Chord? {
        switch self {
        case .newWindow: return Chord(mods: [.control, .shift], key: "n")
        case .newWorkspace: return Chord(mods: [.control, .shift], key: "w")
        case .newSession: return Chord(mods: [.control, .shift], key: "t")
        case .openDirectory: return Chord(mods: [.control, .shift], key: "o")
        case .closeSession: return Chord(mods: [.control, .shift], key: "q")
        case .toggleSplit: return Chord(mods: [.control, .shift], key: "d")
        case .dashboard: return Chord(mods: [.control, .shift], key: "m")
        case .toggleScratch: return Chord(mods: [.control, .shift], key: "j")
        case .toggleSearch: return Chord(mods: [.control, .shift], key: "f")
        case .toggleSidebar: return Chord(mods: [.control, .shift], key: "s")
        case .toggleFlag: return Chord(mods: [.control, .shift], key: "g")
        case .quickTerminal: return Chord(mods: [.control], key: "`")
        case .sessionPalette: return Chord(mods: [.control], key: "p")
        case .commandPalette: return Chord(mods: [.control, .shift], key: "p")
        // Ctrl+Shift+O belongs to Open Directory on Linux. Keep the custom-command palette keyless so
        // restoring a reserved Open Directory override cannot create a default-vs-default collision.
        case .customCommandPalette: return nil
        case .showAttention: return Chord(mods: [.control, .shift], key: "i")
        default: return nil
        }
    }
}
