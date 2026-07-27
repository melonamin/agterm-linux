import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux palette row presentation")
struct PalettePresentationTests {
    private let newSessionChord = Chord(mods: [.control, .shift], key: "t")
    private let dashboardChord = Chord(mods: [.control, .shift], key: "m")

    @Test("a bound catalog command carries its chord in kitty syntax")
    func actionWithChord() {
        let row = LinuxPaletteRow.action(.newSession, in: PaletteContext(), chord: newSessionChord)

        #expect(row.title == "New Session")
        #expect(row.shortcut == "ctrl+shift+t")
        #expect(row.badge == nil)
    }

    @Test("an unbound catalog command has no shortcut")
    func actionWithoutChord() {
        #expect(LinuxPaletteRow.action(.editKeymap, in: PaletteContext(), chord: nil)
            == LinuxPaletteRow(title: "Edit Keymap"))
    }

    /// Two catalog titles flip with UI state, so a row must be built against the LIVE `PaletteContext`.
    /// The context-free `PaletteCommand.title` left the palette offering "Flag Session" for an already
    /// flagged session and "Show Flagged Sessions" while the flagged view was already on; macOS passes
    /// the context for exactly this reason (`agterm/AppActions+Palette.swift`).
    @Test("a context-dependent catalog title flips with the UI state")
    func actionTitleFollowsContext() {
        #expect(LinuxPaletteRow.action(.toggleFlag, in: PaletteContext(), chord: nil).title == "Flag Session")
        #expect(LinuxPaletteRow.action(.toggleFlag, in: PaletteContext(activeSessionFlagged: true), chord: nil).title
            == "Unflag Session")
        #expect(LinuxPaletteRow.action(.toggleFlaggedView, in: PaletteContext(), chord: nil).title
            == "Show Flagged Sessions")
        #expect(LinuxPaletteRow.action(.toggleFlaggedView, in: PaletteContext(sidebarShowsFlaggedOnly: true),
                                       chord: nil).title == "Show All Sessions")
    }

    @Test("a custom command is badged and shows its own chord")
    func customWithShortcut() {
        let row = LinuxPaletteRow.custom(
            CustomCommand(name: "Deploy", command: "make deploy", shortcut: "ctrl+shift+e"))

        #expect(row.title == "Deploy")
        #expect(row.badge == "custom")
        #expect(row.shortcut == "ctrl+shift+e")
    }

    /// `parseCommandLine` stores the chord token exactly as written, so the palette must show the user's
    /// own text — no normalizing through `Chord.displayString`, which would lowercase a `Ctrl+Shift+E`
    /// and cannot represent a leader sequence at all.
    @Test("a custom command's shortcut is the raw keymap token, verbatim", arguments: ["Ctrl+Shift+E", "ctrl+a>g"])
    func customShortcutPassesThroughVerbatim(token: String) {
        let row = LinuxPaletteRow.custom(CustomCommand(name: "Deploy", command: "make deploy", shortcut: token))

        #expect(row.shortcut == token)
        #expect(row.searchKeys == ["Deploy", "Deploy custom \(token)"])
    }

    @Test("a palette-only custom command is badged with no shortcut")
    func customWithoutShortcut() {
        let empty = LinuxPaletteRow.custom(
            CustomCommand(name: "Launch Failure", command: "false", shortcut: ""))
        let blank = LinuxPaletteRow.custom(
            CustomCommand(name: "Slow Failure", command: "sleep 1", shortcut: "   \t "))

        #expect(empty == LinuxPaletteRow(title: "Launch Failure", badge: "custom"))
        #expect(blank.shortcut == nil)
        #expect(blank.badge == "custom")
    }

    @Test("only a row with a badge or a shortcut gains the composite search key")
    func searchKeys() {
        #expect(LinuxPaletteRow(title: "Copy Selection").searchKeys == ["Copy Selection"])
        #expect(LinuxPaletteRow.action(.dashboard, in: PaletteContext(), chord: dashboardChord).searchKeys
            == ["Dashboard", "Dashboard ctrl+shift+m"])
        #expect(LinuxPaletteRow.custom(CustomCommand(name: "Launch Failure", command: "false", shortcut: "")).searchKeys
            == ["Launch Failure", "Launch Failure custom"])
        // both fields present → title, then badge, then shortcut, in that order
        #expect(LinuxPaletteRow(title: "Deploy", shortcut: "ctrl+shift+e", badge: "custom").searchKeys
            == ["Deploy", "Deploy custom ctrl+shift+e"])
    }

    /// The composite key must not turn every chord into a prefix match — a one-letter query has to keep
    /// ranking title matches above rows that only match through their chord text.
    @Test("a short query ranks title matches above chord-only matches")
    func shortQueryRanksTitlesFirst() {
        let ranked = fuzzyRank(query: "c", items: sampleRows, keys: { $0.searchKeys }).map(\.title)

        #expect(ranked.firstIndex(of: "Clear Status") == 0)
        #expect(ranked.firstIndex(of: "Copy Selection") == 1)
        // still findable by chord, just ranked below the genuine title matches
        #expect(ranked.last == "Dashboard")
    }

    @Test("a cross-field query still finds a badged custom row")
    func crossFieldQueryMatchesBadge() {
        let ranked = fuzzyRank(query: "custom launch", items: sampleRows, keys: { $0.searchKeys })

        #expect(ranked.map(\.title) == ["Launch Failure"])
    }

    /// The badge is what a user types to list "the commands I put in keymap.conf", which the old
    /// `"<name>  (custom)"` title gave for free; the composite key is now the only thing carrying it.
    @Test("the bare badge word still filters to the custom rows")
    func badgeQueryFiltersCustomRows() {
        let ranked = fuzzyRank(query: "custom", items: sampleRows, keys: { $0.searchKeys })

        #expect(ranked.map(\.title) == ["Launch Failure"])
    }

    @Test("a chord query still finds its command")
    func chordQueryMatchesShortcut() {
        let ranked = fuzzyRank(query: "ctrl+shift+m", items: sampleRows, keys: { $0.searchKeys })

        #expect(ranked.map(\.title) == ["Dashboard"])
    }

    /// The two queries above are only meaningful against the REAL catalog: the composite key mixes chord
    /// and badge text into the searchable surface, so a future title or default chord could make `custom`
    /// or a chord query ambiguous — and a four-row sample would never see it. Built through the SAME
    /// `builtinAction` mapping production resolves its chord from, so the two can't drift apart.
    @Test("find-by-chord and the badge filter stay unambiguous across the whole shipped catalog")
    func realCatalogQueriesStayUnambiguous() {
        var rows = PaletteCommand.allCases.map {
            LinuxPaletteRow.action($0, in: PaletteContext(), chord: $0.builtinAction?.linuxDefaultChord)
        }
        rows.append(LinuxPaletteRow.custom(CustomCommand(name: "Deploy", command: "make deploy", shortcut: "")))

        #expect(fuzzyRank(query: "custom", items: rows, keys: { $0.searchKeys }).map(\.title) == ["Deploy"])
        #expect(fuzzyRank(query: "ctrl+shift+m", items: rows, keys: { $0.searchKeys }).map(\.title) == ["Dashboard"])
        #expect(fuzzyRank(query: "ctrl+shift+o", items: rows, keys: { $0.searchKeys }).map(\.title) == ["Open Directory…"])
    }

    /// Nothing typed yet is the state every palette open starts in, and the action/session palettes want
    /// it alphabetical — which `fuzzyRank` already gives for free (every row scores 0, leaving its
    /// `localizedCaseInsensitiveCompare` tie-break on the title), so no separate sort exists to drift.
    @Test("an empty query lists an ordinary palette alphabetically")
    func emptyQueryListsAlphabetically() {
        let listed = LinuxPaletteList(items: items(sampleRows)).filtered(query: "")

        #expect(listed.map(\.row.title) == ["Clear Status", "Copy Selection", "Dashboard", "Launch Failure"])
    }

    /// The attention palette's rows arrive pre-ranked by `AppStore.attentionSessions`
    /// (blocked→active→completed, newest change first). Alphabetizing that on an empty query would make
    /// Return jump to the alphabetically-first session instead of the blocked one — macOS special-cases
    /// exactly this (`agterm/Views/Palette.swift`).
    @Test("the attention palette keeps its blocked-first order until something is typed")
    func attentionPaletteKeepsNaturalOrder() {
        let natural = ["blocked session", "active session", "completed session"]
        let alphabetical = ["active session", "blocked session", "completed session"]
        let attention = LinuxPaletteList(items: items(natural.map { LinuxPaletteRow(title: $0) }),
                                         preservesNaturalOrder: true)

        #expect(attention.filtered(query: "")
            .map(\.row.title) == natural)
        // whitespace-only is the same "nothing typed yet" state (macOS trims before its emptiness check)
        #expect(attention.filtered(query: "  ")
            .map(\.row.title) == natural)
        // once a query IS typed, the shared ranking applies in attention mode like everywhere else
        #expect(attention.filtered(query: "session")
            .map(\.row.title) == alphabetical)
        // and the same rows WITHOUT the flag fall through to the ordinary alphabetical empty-query order
        #expect(LinuxPaletteList(items: attention.items).filtered(query: "")
            .map(\.row.title) == alphabetical)
    }

    private var sampleRows: [LinuxPaletteRow] {
        [LinuxPaletteRow.action(.dashboard, in: PaletteContext(), chord: dashboardChord),
         LinuxPaletteRow.action(.clearStatus, in: PaletteContext(), chord: nil),
         LinuxPaletteRow(title: "Copy Selection"),
         LinuxPaletteRow.custom(CustomCommand(name: "Launch Failure", command: "false", shortcut: ""))]
    }

    /// Rows paired with a no-op action — `filtered` only ever reads the row half.
    private func items(_ rows: [LinuxPaletteRow]) -> [LinuxPaletteItem] {
        rows.map { (row: $0, run: {}) }
    }
}
