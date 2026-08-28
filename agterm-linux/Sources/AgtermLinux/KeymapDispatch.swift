// Keymap-driven key dispatch: turns the shared, host-free keymap (user-rebound built-ins + custom
// shell commands) into AppController actions. The GTK key handler (GhosttySurface.keyPressed) stays
// thin — it calls handleKey(...) and this file owns all the logic, mirroring the macOS menu-equivalent +
// CustomCommandRunner split over the SAME agtermCore Keymap/KeybindMatcher.
//
// Resolution: a built-in's chord is `keymap.builtinOverrides[action] ?? action.linuxDefaultChord` (the
// macOS BuiltinAction.defaultChord is Cmd-based and unsuitable on Linux). Custom commands feed a
// KeybindMatcher (simple chords + leader sequences). The arrow/page nav and font keys stay fixed; reserved
// monitor chords (Ctrl+Tab, Ctrl+1/2) are resolved before custom/built-in bindings.
import CGtk
import Foundation
import agtermCore

private let linuxPreferencesChord = Chord(mods: [.control], key: ",")

enum LinuxFixedShortcut: Equatable {
    case preferences
    case focusPane(left: Bool)
    case fontIncrease
    case fontDecrease
    case fontReset
    case sessionSwitch(reverse: Bool)
}

func linuxFixedShortcut(for chord: Chord) -> LinuxFixedShortcut? {
    if chord.key == "tab", chord.mods.contains(.control) {
        return .sessionSwitch(reverse: chord.mods.contains(.shift))
    }
    switch chord {
    case linuxPreferencesChord:
        return .preferences
    case Chord(mods: [.control], key: "1"):
        return .focusPane(left: true)
    case Chord(mods: [.control], key: "2"):
        return .focusPane(left: false)
    case Chord(mods: [.control], key: "+"), Chord(mods: [.control], key: "="),
         Chord(mods: [.control, .shift], key: "="):
        return .fontIncrease
    case Chord(mods: [.control], key: "-"), Chord(mods: [.control], key: "_"):
        return .fontDecrease
    case Chord(mods: [.control], key: "0"):
        return .fontReset
    default:
        return nil
    }
}

func isLinuxReservedChord(_ chord: Chord) -> Bool {
    isReservedMonitorChord(chord) || chord == linuxPreferencesChord
}

/// Re-resolve parsed overrides against the Linux default chord table. The shared parser already does
/// this against upstream's macOS defaults, but removing a Linux-reserved override restores a different
/// default and can expose a fresh collision. Iterate to a fixpoint because dropping one override may
/// restore another Linux default that invalidates a second override.
private func resolveLinuxBuiltinOverrides(
    _ parsed: [BuiltinAction: Chord], unbound: Set<BuiltinAction>, diagnostics: inout [KeymapDiagnostic]
) -> [BuiltinAction: Chord] {
    var candidates = parsed
    while true {
        var ownersByChord: [Chord: [BuiltinAction]] = [:]
        for action in BuiltinAction.allCases {
            if unbound.contains(action), candidates[action] == nil { continue }
            guard let chord = candidates[action] ?? action.linuxDefaultChord else { continue }
            ownersByChord[chord, default: []].append(action)
        }

        var loserAndKeeper: (BuiltinAction, BuiltinAction)?
        for owners in ownersByChord.values where owners.count > 1 {
            let defaults = owners.filter { candidates[$0] == nil }
                .sorted { $0.rawValue < $1.rawValue }
            let overrides = owners.filter { candidates[$0] != nil }
                .sorted { $0.rawValue < $1.rawValue }
            if let keeper = defaults.first, let loser = overrides.first {
                loserAndKeeper = (loser, keeper)
                break
            }
            if overrides.count > 1 {
                loserAndKeeper = (overrides[overrides.count - 1], overrides[0])
                break
            }
        }
        guard let (loser, keeper) = loserAndKeeper else { return candidates }
        let chord = candidates.removeValue(forKey: loser)
        diagnostics.append(KeymapDiagnostic(
            line: 0,
            message: "chord '\(chord?.displayString ?? "unknown")' conflicts with Linux built-in "
                + "'\(keeper.rawValue)'; \(loser.rawValue) map skipped"
        ))
    }
}

func loadLinuxKeymap(configDirectory: URL) -> (keymap: Keymap, diagnostics: [KeymapDiagnostic]) {
    let (parsed, baseDiagnostics) = KeymapStore(configDirectory: configDirectory).load()
    var diagnostics = baseDiagnostics
    var overrides = parsed.builtinOverrides
    for (action, chord) in parsed.builtinOverrides.sorted(by: { $0.key.rawValue < $1.key.rawValue })
    where isLinuxReservedChord(chord) {
        overrides[action] = nil
        diagnostics.append(KeymapDiagnostic(
            line: 0,
            message: "chord '\(chord.displayString)' is reserved by the Linux host; \(action.rawValue) map skipped"
        ))
    }
    overrides = resolveLinuxBuiltinOverrides(
        overrides,
        unbound: parsed.builtinUnbound,
        diagnostics: &diagnostics
    )
    // Dropping an override restores that action's Linux default. Re-check custom commands against the
    // resulting Linux chord set because the shared parser validated against the upstream macOS defaults.
    let activeBuiltinChords: Set<Chord> = Set(BuiltinAction.allCases.compactMap { action -> Chord? in
        if parsed.builtinUnbound.contains(action), overrides[action] == nil { return nil }
        return overrides[action] ?? action.linuxDefaultChord
    })
    var sequences = parsed.builtinSequences
    for (action, alternatives) in parsed.builtinSequences {
        let survivors = alternatives.filter { keybind in
            !keybind.contains(where: isLinuxReservedChord)
                && !(keybind.first.map(activeBuiltinChords.contains) ?? false)
        }
        guard survivors.count != alternatives.count else { continue }
        sequences[action] = survivors
        diagnostics.append(KeymapDiagnostic(
            line: 0,
            message: "\(action.rawValue) alternative uses a Linux-reserved or active built-in shortcut and was skipped"
        ))
    }

    var commands = parsed.commands
    for index in commands.indices {
        let rawAlternatives = commands[index].shortcut.split(
            separator: "|", omittingEmptySubsequences: false
        ).map(String.init)
        let parsedAlternatives = rawAlternatives.compactMap { raw in
            parseKeybind(raw).map { (raw: raw, keybind: $0) }
        }
        guard parsedAlternatives.count == rawAlternatives.count else { continue }
        let survivors = parsedAlternatives.filter { binding in
            !binding.keybind.contains(where: isLinuxReservedChord)
                && !(binding.keybind.first.map(activeBuiltinChords.contains) ?? false)
        }
        guard survivors.count != parsedAlternatives.count else { continue }
        diagnostics.append(KeymapDiagnostic(
            line: 0,
            message: "command '\(commands[index].name)' has a Linux-reserved or active built-in alternative; binding skipped"
        ))
        commands[index].shortcut = survivors.map(\.raw).joined(separator: "|")
    }
    return (
        Keymap(
            builtinOverrides: overrides,
            commands: commands,
            builtinSequences: sequences,
            builtinUnbound: parsed.builtinUnbound,
            globalHotkey: parsed.globalHotkey
        ),
        diagnostics
    )
}

/// Project the Linux-resolved binding table for `keymap.list`. The shared projection intentionally uses
/// macOS defaults; Linux must report the Ctrl-based chords that its key monitor actually dispatches.
func projectLinuxKeymap(
    _ keymap: Keymap, diagnostics: [KeymapDiagnostic], path: String
) -> ControlKeymap {
    let actions = BuiltinAction.allCases.map { action in
        let resolved: Chord?
        if let override = keymap.builtinOverrides[action] {
            resolved = override
        } else {
            resolved = keymap.builtinUnbound.contains(action) ? nil : action.linuxDefaultChord
        }
        let alternates = keymap.sequences(for: action).map(\.displayString)
        return ControlKeymapAction(
            action: action.rawValue,
            chord: resolved?.displayString,
            alternates: alternates.isEmpty ? nil : alternates,
            overridden: resolved != action.linuxDefaultChord ? true : nil
        )
    }
    let commands = keymap.commands.map {
        ControlKeymapCommand(name: $0.name, shortcut: $0.shortcut.isEmpty ? nil : $0.shortcut)
    }
    return ControlKeymap(
        path: path,
        actions: actions,
        commands: commands,
        diagnostics: diagnostics.map { ControlKeymapDiagnostic(line: $0.line, message: $0.message) }
    )
}

/// The toast for a keymap load, or `nil` when the load produced nothing worth saying.
///
/// A load REPORTS ERRORS AND OTHERWISE STAYS SILENT, whether it happened at startup or on an explicit
/// reload — matching macOS, where `SettingsModel.reloadKeymap()` notifies only on a non-empty
/// `keymapDiagnostics`. Silence matters most for `agtermctl keymap reload`, a scripted/headless surface
/// (hooks, custom commands) that must not banner the frontmost window on every invocation. The one
/// success confirmation in the app is the Settings ▸ Key Mapping reload BUTTON, which posts its own
/// (see `SettingsKeyMappingPage.swift`) because there the user pressed a button and expects an answer.
///
/// It lives in a helper because both the app-wide reload seam and startup report the same wording, and
/// returning `String?` puts the "do not toast" case in the value instead of an `if` each caller repeats.
/// Internal, not `private`, so `AgtermLinuxTests` can reach it — this wording is the only host-free part
/// of the reload seam, which otherwise runs over live GTK controllers.
func keymapReloadToast(count: Int) -> String? {
    guard count > 0 else { return nil }
    // Kitty-style: a malformed line is skipped and the rest of the file still loads, so name the count
    // instead of silently dropping the bad lines.
    return "keymap.conf: \(count) error\(count == 1 ? "" : "s") — bad line\(count == 1 ? "" : "s") ignored"
}

@MainActor
private final class LeaderTimeoutContext {
    weak var controller: AppController?

    init(controller: AppController) {
        self.controller = controller
    }
}

private let releaseLeaderTimeoutContext: GDestroyNotify = { data in
    guard let data else { return }
    Unmanaged<LeaderTimeoutContext>.fromOpaque(data).release()
}

/// The custom-command leader deadline fired on the main loop — abandon the half-typed sequence.
/// The source owns a weak-controller context until it fires or is cancelled.
private let onLeaderTimeout: @MainActor @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    MainActor.assumeIsolated {
        Unmanaged<LeaderTimeoutContext>.fromOpaque(data).takeUnretainedValue().controller?.leaderDeadlineFired()
    }
    return 0
}

@MainActor
extension AppController {
    /// (Re)load keymap.conf and rebuild the dispatch caches: the resolved built-in chord→action map, the
    /// custom-command leader matcher, and the id→command lookup. Returns the parse-diagnostic count.
    ///
    /// This rebuilds ONE window's caches and deliberately does NOT toast — the CALLER owns the toast, via
    /// `keymapReloadToast(count:)`. Toasting here would banner every window on an app-wide reload (see
    /// `reloadKeymapAllWindows(reportingIn:)`, which fans this out and reports once). Direct callers are
    /// `loadKeymapAtStartup()` and that seam; every explicit reload goes through the seam.
    func reloadKeymapDiagnostics() -> Int {
        let (km, diagnostics) = loadLinuxKeymap(configDirectory: configDirectory())
        keymap = km
        keymapDiagnostics = diagnostics

        // Reverse map: defaults for un-overridden actions first, then overrides (so an override REPLACES
        // its action's default chord; a genuine chord collision resolves override-wins). Reserved monitor
        // chords are never inserted — they're handled by the fixed fallback.
        var reverse: [Chord: BuiltinAction] = [:]
        for action in BuiltinAction.allCases
        where km.builtinOverrides[action] == nil && !km.builtinUnbound.contains(action) {
            if let chord = action.linuxDefaultChord, !isLinuxReservedChord(chord) { reverse[chord] = action }
        }
        for (action, chord) in km.builtinOverrides where !isLinuxReservedChord(chord) {
            reverse[chord] = action
        }
        resolvedBuiltinChords = reverse

        // Custom commands: the shared engine indexes by id + builds the leader matcher (parseKeymap already
        // cleared shortcuts that collide with built-ins / reserved chords / each other).
        customCommandEngine = CustomCommandEngine(
            commands: km.commands,
            builtinSequences: km.builtinSequences
        )
        return diagnostics.count
    }

    /// Build THIS new controller's keymap caches while the window is being constructed.
    ///
    /// Deliberately NOT `reloadKeymapAllWindows(reportingIn:)`: this is one window's FIRST load, not an
    /// app-wide reload, and fanning out here would re-parse every already-open window on every window
    /// open. A malformed `keymap.conf` therefore toasts once per window opened, which is per-window on
    /// purpose — each window is loading the file for the first time.
    func loadKeymapAtStartup() {
        if let message = keymapReloadToast(count: reloadKeymapDiagnostics()) { showToast(message) }
    }

    /// The chord currently bound to `action`, or nil when nothing resolves (no Linux default, or the
    /// binding was dropped as reserved). Reverse lookup over the same `resolvedBuiltinChords` dispatch
    /// uses, shared by the palette's shortcut column and the Keyboard Shortcuts dialog so the two
    /// surfaces can never render different chords for one action. Named `resolvedChord` rather than
    /// `chord` so it does not shadow the global `chord(fromKeyval:state:)` inside this extension.
    func resolvedChord(for action: BuiltinAction) -> Chord? {
        resolvedBuiltinChords.first(where: { $0.value == action })?.key
    }

    /// The single entry point for a terminal key press (called by GhosttySurface.keyPressed). Returns
    /// true when the key was consumed as an app shortcut / custom command; false to let libghostty encode
    /// it for the terminal. Dispatch order: Esc leader-abort → reserved host chord → custom command
    /// matcher → built-in → fixed shortcut → raw arrow/page navigation.
    func handleKey(keyval: UInt32, keycode: UInt32, state: UInt32, sessionID: UUID,
                   origin: GhosttySurface? = nil,
                   context: @autoclosure () -> ShortcutKeyContext? = nil) -> Bool {
        // Reset the leader deadline to the FINAL armed state on every exit: a fresh leader (re)starts the
        // 1.5s timer, a fired/aborted leader cancels it (macOS-parity leader timeout — see syncLeaderDeadline).
        defer { syncLeaderDeadline() }
        // Escape: abort a half-typed leader (consumed); otherwise pass through to the terminal.
        if keyval == 0xFF1B {
            if customCommandEngine.isArmed { customCommandEngine.reset(); return true }
            return false
        }

        let needsKeyContext = needsShortcutKeyContext(
            state: state, leaderArmed: customCommandEngine.isArmed
        )
        guard let chord = shortcutChord(
            fromKeyval: keyval,
            keycode: keycode,
            state: state,
            context: needsKeyContext ? context() : nil
        ) else {
            // A non-Chord key (arrow/page/F-key) can't continue a leader sequence; abandon a half-typed
            // one so a stale prefix can't complete across it.
            if customCommandEngine.isArmed { customCommandEngine.reset() }
            return rawNavigationShortcut(keyval: keyval, state: state)
        }

        if isLinuxReservedChord(chord) {
            if customCommandEngine.isArmed { customCommandEngine.reset() }
            guard let shortcut = linuxFixedShortcut(for: chord) else { return false }
            dispatchFixedShortcut(shortcut, origin: origin)
            return true
        }

        switch customCommandEngine.advance(chord) {
        case .fired(let command):
            runCustomCommand(command, origin: origin, allowSessionless: store.activeSession == nil)
            return true
        case .firedBuiltin(let action):
            dispatchBuiltin(action, sessionID: sessionID)
            return true
        case .armed:
            return true
        case .unmatched:
            break
        }

        if let action = resolvedBuiltinChords[chord] {
            dispatchBuiltin(action, sessionID: sessionID)
            return true
        }
        if let shortcut = linuxFixedShortcut(for: chord) {
            dispatchFixedShortcut(shortcut, origin: origin)
            return true
        }
        return rawNavigationShortcut(keyval: keyval, state: state)
    }

    private func dispatchFixedShortcut(_ shortcut: LinuxFixedShortcut, origin: GhosttySurface?) {
        switch shortcut {
        case .preferences:
            showSettings()
        case .focusPane(let left):
            focusPane(left: left)
        case .fontIncrease:
            (origin ?? focusedSurface())?.performBindingAction(FontBindingAction.increase)
        case .fontDecrease:
            (origin ?? focusedSurface())?.performBindingAction(FontBindingAction.decrease)
        case .fontReset:
            (origin ?? focusedSurface())?.performBindingAction(FontBindingAction.reset)
        case .sessionSwitch(let reverse):
            quickSwitchSession(reverse: reverse)
        }
    }

    /// Abandon a half-typed leader sequence (called on terminal focus loss — mirrors the macOS
    /// first-responder gate).
    func resetLeader() { customCommandEngine.reset() }

    /// Sync the leader deadline to the matcher's armed state (called via `defer` on every key): cancel any
    /// pending timer, then (re)arm a 1.5s g_timeout if a leader sequence is partially entered, so a
    /// half-typed leader self-aborts after the deadline — the Linux analogue of the macOS 1.5s timeout.
    private func syncLeaderDeadline() {
        cancelLeaderDeadline()
        if customCommandEngine.isArmed {
            let context = LeaderTimeoutContext(controller: self)
            leaderTimeout = g_timeout_add_full(
                G_PRIORITY_DEFAULT, 1500, onLeaderTimeout,
                Unmanaged.passRetained(context).toOpaque(), releaseLeaderTimeoutContext)
        }
    }
    private func cancelLeaderDeadline() {
        if leaderTimeout != 0 { g_source_remove(leaderTimeout); leaderTimeout = 0 }
    }
    func cancelLeaderDeadlineForWindowClose() {
        cancelLeaderDeadline()
        resetLeader()
    }
    /// The leader timer fired (no completing chord in time): abandon the half-typed sequence. The source
    /// auto-removes (the callback returns G_SOURCE_REMOVE), so just clear the id + reset the matcher.
    func leaderDeadlineFired() {
        leaderTimeout = 0
        resetLeader()
    }

    /// Map a rebindable `BuiltinAction` to its AppController method. EXHAUSTIVE: adding a BuiltinAction
    /// case fails to compile until it's wired, the Linux analogue of the macOS menu keep-in-sync.
    private func dispatchBuiltin(_ action: BuiltinAction, sessionID: UUID) {
        switch action {
        case .newWindow: openNewWindow()
        case .renameWindow: renameWindowDialog(windowID)
        case .deleteWindow: confirmDeleteWindow(windowID)
        case .newWorkspace: newWorkspace()
        case .renameWorkspace: if let ws = store.currentWorkspaceID { beginRename(id: ws, isWorkspace: true) }
        case .deleteWorkspace: if store.canRemoveWorkspace, let ws = store.currentWorkspaceID { store.removeWorkspace(ws); reconcile() }
        case .newSession: newSession()
        case .openDirectory: openDirectory()
        case .renameSession: startRenameActive()
        case .duplicateSession: _ = duplicateSession(sessionID)
        case .closeSession: requestCloseSession(sessionID)
        case .reopenRecent: reopenRecentClosed()
        case .undoClose: undoPendingClose()
        case .clearStatus: clearActiveStatus()
        case .increaseFontSize: focusedSurface()?.performBindingAction(FontBindingAction.increase)
        case .decreaseFontSize: focusedSurface()?.performBindingAction(FontBindingAction.decrease)
        case .resetFontSize: focusedSurface()?.performBindingAction(FontBindingAction.reset)
        case .toggleSplit: toggleSplit(axis: .leftRight)
        case .toggleHorizontalSplit: toggleSplit(axis: .topBottom)
        case .toggleScratch: toggleScratch()
        case .toggleTerminalZoom: toggleTerminalZoom()
        case .dashboard: toggleDashboard()
        case .toggleSearch: toggleSearch()
        case .toggleSidebar: toggleSidebar()
        case .toggleFullscreen: toggleWindowFullscreen()
        case .selectTheme: showThemePicker()
        case .toggleFlaggedView: toggleFlaggedView()
        case .toggleFlag: toggleFlagActive()
        case .focusWorkspace: focusActiveWorkspace()   // toggle focus on the active session's workspace
        case .toggleWorkspaceFilter: toggleWorkspaceFilter()
        case .previousWorkspace: navigateWorkspace(.previous)
        case .nextWorkspace: navigateWorkspace(.next)
        case .toggleWorkspaceCollapse: toggleCurrentWorkspaceCollapse()
        case .focusLeftPane: focusPane(left: true)
        case .focusRightPane: focusPane(left: false)
        case .previousSession: navigate(.previous)
        case .nextSession: navigate(.next)
        case .previousAttentionSession: navigate(.previousAttention)
        case .nextAttentionSession: navigate(.nextAttention)
        case .firstSession: navigate(.first)
        case .lastSession: navigate(.last)
        case .quickTerminal: toggleQuick()
        case .sessionPalette: showSessionPalette()
        case .commandPalette: showPalette()
        case .customCommandPalette: showPalette()   // the palette already lists custom commands
        case .showAttention: showAttentionPalette()
        }
    }

    private func rawNavigationShortcut(keyval: UInt32, state: UInt32) -> Bool {
        let relevant = state & ((1 << 0) | (1 << 2) | (1 << 3) | (1 << 26))
        if relevant == (1 << 0) | (1 << 2) {
            switch keyval {
            case 0xFF52: reorderActiveSession(.up); return true        // Ctrl+Shift+Up
            case 0xFF54: reorderActiveSession(.down); return true      // Ctrl+Shift+Down
            case 0xFF55: reorderActiveWorkspace(.up); return true      // Ctrl+Shift+PageUp
            case 0xFF56: reorderActiveWorkspace(.down); return true    // Ctrl+Shift+PageDown
            case 0xFF51: focusPane(left: true); return true           // Ctrl+Shift+Left
            case 0xFF53: focusPane(left: false); return true          // Ctrl+Shift+Right
            default: return false
            }
        }
        if relevant == (1 << 2) {
            switch keyval {
            case 0xFF56: navigate(.next); return true                 // Ctrl+Page_Down
            case 0xFF55: navigate(.previous); return true             // Ctrl+Page_Up
            default: return false
            }
        }
        return false
    }
}
