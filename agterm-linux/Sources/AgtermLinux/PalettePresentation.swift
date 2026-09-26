// Host-free presentation model for the command-palette rows. Palette.swift stays pure GTK: it turns
// one of these into a horizontal box (title | badge | shortcut) and never string-mangles a title again.
import agtermCore

/// One command-palette row, split into the fields the GTK composer renders as separate labels.
///
/// macOS carries the same split as a multi-field `PaletteItem` rendered `HStack` + `Spacer` +
/// `.foregroundStyle(.secondary)`; the Linux port used to concatenate the shortcut into the title,
/// which is why a row read `Dashboard   ctrl+shift+m` as one left-aligned run of text.
struct LinuxPaletteRow: Equatable {
    /// The action name, left-aligned and the only field the empty-query sort and the alphabetical
    /// tie-break look at.
    let title: String
    /// The current keybind in kitty syntax (`ctrl+shift+t`), right-aligned and dimmed; nil = unbound.
    let shortcut: String?
    /// A trailing pill (currently only `custom`), nil for the ordinary catalog rows.
    let badge: String?

    init(title: String, shortcut: String? = nil, badge: String? = nil) {
        self.title = title
        self.shortcut = shortcut
        self.badge = badge
    }

    /// The keys `fuzzyRank` scores this row against: the bare title, plus — only when the row actually
    /// has a badge or a shortcut — ONE composite key joining every visible field.
    ///
    /// Do NOT "simplify" this into one key per field. `fuzzyScore` requires EVERY whitespace-separated
    /// term to match the SAME key, so a cross-field query (`custom launch`, or the AT-SPI suite typing a
    /// row's full visible text) matches no single-field key and the row disappears. And `termScore`
    /// scores a prefix `0`, so a standalone `ctrl+shift+m` / `custom` key would make every short `c…`
    /// query a perfect prefix match on every chord-bound row, flattening the ranking until chord matches
    /// tie with genuine title matches. The composite reproduces today's concatenated-title scores while
    /// leaving `keys.first == title` as the clean alphabetical tie-break `fuzzyRank` uses.
    var searchKeys: [String] {
        guard shortcut != nil || badge != nil else { return [title] }
        let composite = [title, badge, shortcut].compactMap { $0 }.joined(separator: " ")
        return [title, composite]
    }
}

/// One rendered palette row paired with the closure Enter/click runs. Spelled out at every palette
/// seam otherwise — `paletteAll`, `paletteItems`, and each of the list builders.
typealias LinuxPaletteItem = (row: LinuxPaletteRow, run: () -> Void)

/// Everything one palette open lists: the rows, plus whether their INPUT order is itself the ranking.
///
/// The two travel together because `filtered` needs both, and because a separate controller flag would
/// be one more thing every close path had to remember to reset.
struct LinuxPaletteList {
    var items: [LinuxPaletteItem] = []
    /// True only for the attention palette, whose rows arrive ranked blocked→active→completed.
    var preservesNaturalOrder = false

    /// The rows to show for `query`, in display order — the ONE ordering seam `filterPalette` uses, so
    /// the empty-query list and the ranked list can't drift.
    ///
    /// Do NOT add an alphabetical branch for the empty query: `fuzzyRank` already scores every row `0`
    /// then tie-breaks on `keys.first` (the title), so it IS that sort. The one list that must not go
    /// through it is the attention palette — its input order is itself the ranking (blocked→active→completed,
    /// newest change first), and the alphabetical tie-break would re-sort it so Return ran the
    /// alphabetically-first session instead of the blocked one. macOS special-cases exactly this
    /// (`agterm/Views/Palette.swift`); `preservesNaturalOrder` is the Linux half. Whitespace-only counts
    /// as "nothing typed yet", matching macOS trimming the query before its emptiness check.
    func filtered(query: String) -> [LinuxPaletteItem] {
        if preservesNaturalOrder, query.allSatisfy(\.isWhitespace) { return items }
        return fuzzyRank(query: query, items: items, keys: { $0.row.searchKeys })
    }
}

/// Pure builders — no GTK, no `@MainActor` — so the mapping from a catalog command / keymap command to
/// its rendered fields is unit-tested outside the render code. A row with nothing but a title (the
/// Linux-only entries, the dynamic window/workspace rows, the session/attention pickers) just uses
/// `LinuxPaletteRow(title:)`.
extension LinuxPaletteRow {
    /// A catalog command as the CURRENT UI state presents it: its context-dependent title plus its
    /// resolved keybind, when one resolves.
    ///
    /// The context is not optional decoration — two catalog titles flip with it (`toggleFlag` reads
    /// `Unflag Session` for an already-flagged session, `toggleFlaggedView` `Show All Sessions` while
    /// the flagged view is on), so the context-free `PaletteCommand.title` would leave the palette
    /// offering the wrong verb. macOS passes it the same way (`agterm/AppActions+Palette.swift`).
    ///
    /// The chord renders as kitty syntax (`Chord.displayString`), which is what the user writes in
    /// `keymap.conf` — deliberately NOT macOS's `glyphString`, since Linux has no menu-glyph convention.
    static func action(_ command: PaletteCommand, in context: PaletteContext, chord: Chord?) -> LinuxPaletteRow {
        LinuxPaletteRow(title: command.title(in: context), shortcut: chord?.displayString)
    }

    /// A persisted window target. Closed entries use the same explicit "Open Window" wording as macOS;
    /// open entries are a Linux-only switcher convenience and are raised by the same `openWindow` path.
    static func window(name: String, isOpen: Bool) -> LinuxPaletteRow {
        LinuxPaletteRow(title: "\(isOpen ? "Switch to" : "Open") Window: \(name)")
    }

    /// A `keymap.conf` custom command: its name, the `custom` badge, and its own bound chord if any.
    ///
    /// `CustomCommand.shortcut` is the RAW keybind token the user typed, passed through verbatim (the
    /// parser stores `firstToken` as written), so the palette shows the same text `keymap.conf` does —
    /// including a leader sequence like `ctrl+a>g`. Empty means palette-only, and cross-section
    /// validation clears it to empty when it collides, so a whitespace-only value must read as unbound
    /// too — hence `linuxTrimmedOrNil` rather than an `isEmpty` check.
    static func custom(_ command: CustomCommand) -> LinuxPaletteRow {
        LinuxPaletteRow(title: command.name, shortcut: command.shortcut.linuxTrimmedOrNil, badge: "custom")
    }
}
