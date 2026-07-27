---
paths:
  - "agterm/Views/Palette.swift"
  - "agterm/SettingsModel.swift"
  - "agterm/SettingsCatalog.swift"
  - "agterm/AppActions*.swift"
  - "agterm-linux/Sources/AgtermLinux/ThemePicker.swift"
  - "agterm-linux/Sources/AgtermLinux/GhosttyConfigTheme.swift"
---

## Theme picker

- **A live-preview theme picker as a third command-palette mode.**
  The `.themes` `PaletteMode` (alongside `.actions`/`.sessions`, `Palette.swift`) reuses the SAME `CommandPalette`
  fuzzy-search/list/nav view; only theme mode carries the live preview.
  Its rows = `AppActions.paletteThemes()` (a leading "default ghostty" = nil/no-theme + one per `SettingsCatalog.themeNames()`,
  the current one badged `current`).
  The theme NAMES never pollute the action palette — only a single **"Select Theme…"** launcher item
  appears in `paletteActions()` (and the View ▸ Select Theme… menu item + the keyless `BuiltinAction.selectTheme`).
  The launcher opens the picker via `AppActions.openThemePalette()` → `palette.open(.themes)` dispatched
  ASYNC (the launcher runs inside the action palette's `runItem`, which closes that palette right after;
  the async open lets `.themes` re-open a tick later as a FRESH view — empty query,
  not the launcher's search text).
- **Preview/commit/cancel, themes-only.**
  Two optional hooks the View invokes ONLY when `mode == .themes`: `PaletteItem.onSelect` (fired on selection
  change → `AppActions.previewTheme(name)`) and a mode-level cancel.
  `previewTheme` = `SettingsModel.previewTheme` sets `settings.theme = name` immediately but DEBOUNCES
  the live `apply()` (~0.07 s) so a burst of nav/typing previews coalesces to one surface reload — applied
  WITHOUT `settingsStore.save` (`persistAndApply` was split into `save(); apply()` so preview can apply-without-persist).
  Enter/click commits via `commitThemePreview()` → `SettingsModel.commitTheme(nonActiveOriginal:)`,
  which FLUSHES the pending debounced apply (so the active slot's latest value is live NOW), RESTORES the
  off-screen slot to its captured original (so a value browsed into it during a mid-preview flip can't
  commit — the commit-side twin of the Esc revert; re-applies only in that flip case so the dual line on
  disk matches), then `save()`s.
  Any dismiss without a commit — Esc, scrim tap, switch to another palette mode,
  unmount — reverts via `cancelThemePreview()` → `revertThemePreview(theme:darkTheme:)`,
  which CANCELS the pending debounce and restores BOTH slots captured on open SYNCHRONOUSLY (no debounce
  lag, no stuck last-preview).
  `beginThemePreview` snapshots the WHOLE `(theme, darkTheme)` pair (not just the on-screen slot) so the
  revert stays correct even if macOS flips appearance mid-preview — otherwise the Esc revert would re-resolve
  the slot at flip-time and write the captured value into the wrong side, stranding both slots.
  `AppActions` owns the session state (`themePreviewActive` + `themePreviewOriginal`, the captured pair);
  `SettingsModel` stays stateless about it.
  The View wires it through `syncThemeSession()` (begin + select the current theme's row on enter,
  cancel on leave — called from `.onAppear`/`.onChange(of: mode)`) + `.onDisappear { cancelThemePreview() }`
  + the `onChange(of: selection)` preview call.
  The picker opens with the CURRENT theme's row selected (via `currentThemeID`),
  so it doesn't preview-jump to "default ghostty".
  **Typing also previews:** `onChange(of: query)` resets `selection = 0` then calls `previewSelected()`
  — because a filter re-orders the list so the item AT index 0 changes while `selection` STAYS 0,
  `onChange(of: selection)` doesn't fire, so the new top match would never preview on filtering alone
  (only on arrow-nav).
  `previewSelected()` fires `filtered[selection].onSelect?()` explicitly (a no-op for non-theme palettes,
  whose items carry no `onSelect`).
- **Focus invariant (load-bearing).**
  `AppActions.focusActiveSession` early-returns when `palette?.mode != nil` — NEVER grab terminal first
  responder while a palette is open.
  Without it, the launcher path breaks: closing the action palette fires `WindowContentView`'s close-restore
  (`onChange(palette.mode == nil) { focusActiveSession() }`), whose ~12×0.03s `makeFirstResponder(terminal)`
  RETRY loop out-races the just-opened picker's field focus, so the picker can't be typed into (the terminal
  behind it eats the keys).
  The guard also kills the retry the instant `.themes` opens AND blocks any focus steal during a live
  preview reload.
- **Default theme = the bundled `agterm` theme (NOT ghostty's built-in).**
  `AppSettings.defaultTheme = "agterm"` (host-free), and `SettingsStore.load()` seeds it on a fresh install
  (missing/corrupt `settings.json` → `AppSettings(theme: defaultTheme)`).
  It is NOT baked into the `AppSettings()` memberwise default — that stays `theme == nil` so `ghosttyConfigLines()`'s
  "nil = no theme line" invariant (and its tests) hold; the seed lives ONLY in the fresh-load path.
  So `theme == nil` means ghostty's built-in (the picker's "default ghostty" row);
  the agterm default is a real seeded value, and the picker opens on the "agterm" row for a fresh install.
  An EXISTING `settings.json` with `theme` absent decodes to nil (ghostty built-in) — an existing user
  is never silently re-themed.
  `theme.set` with no name still sets nil (ghostty built-in / "default ghostty"),
  distinct from the seeded app default.
- **Appearance sync = two theme slots + an explicit toggle; emission is the RAW dual value.**
  Three `AppSettings` fields hold it: `theme` (the single/base theme, and the LIGHT slot while following), `darkTheme` (the DARK slot), and `followSystemAppearance` (nil/false = off, the default).
  `ghosttyConfigLines()` (no `isDark` param) emits ONE line: while following it is ghostty's own dual conditional `theme = light:NAME,dark:NAME` written RAW; otherwise the single theme — one `if`, no parsing.
  libghostty resolves the active side itself at runtime, but the SWITCH is host-driven: `SystemAppearanceObserver` (an app-level KVO observer on `NSApplication.effectiveAppearance`) posts `.agtermSystemAppearanceChanged` with the KVO-delivered `isDark`; `SettingsModel.appearanceChanged` (guarded on following + both slots set, AND on the posted side differing from the last config feed) threads that `isDark` into `reloadConfigPreservingSessionZoom` → `GhosttyApp.reloadConfig(surfaces:isDark:)`, which sets `ghostty_app_set_color_scheme` + each surface's `ghostty_surface_set_color_scheme` from it and re-feeds via `update_config` DIRECTLY — the raw dual file text is stable across flips, so `writeGhosttyConfig`'s text-diff would otherwise skip the reload.
  The flip reload KEEPS each session's ⌘+/⌘− zoom (`reapplySessionConfigIfNeeded` re-emits the zoomed sessions' `font-size` after the broadcast); only the explicit reloads clear it.
  The side comes from the APP-level `NSApplication.effectiveAppearance` via KVO (`change.newValue`, the settled value), never from a view — the old per-view hook wedged after sleep/wake and stuck the terminal on the old theme (see the libghostty rule for the mechanism; `AppearanceFlipUITests` pins the zoom-preserving flip via the UI-test-only `debug.appearance` seam).
  `AppSettings.activeTheme(isDark:)` (dark slot in dark mode, else `theme`) is now used ONLY by the palette badge/selection; emission never resolves a side.
  The one surviving dual PARSE is `ThemeName.resolved(from:isDark:)` (host-free, from #146) — used only to pick the active side for the sidebar selection colors (`GhosttyApp.resolveSelectionColors`, which reads the raw `theme` line back out of the config); `ThemeResolution`, the branch's own `AppSettings.dualThemeSides`, and the legacy dual-string migration are gone.
  Settings UI: picker 1 ("Theme", stable AX id `settings-theme`) edits the current-appearance slot via `setThemeForCurrentAppearance`; a `Toggle("Follow system appearance")` (`settings-follow-appearance`, default OFF) drives `setFollowSystemAppearance` (ON seeds the other slot from the current theme so both start equal; OFF collapses to the on-screen theme, no visual flip); and — only while following — an alternate picker (`settings-theme-dark`, labeled for the OTHER appearance) drives `setAlternateTheme`.
  The primary picker offers the "default ghostty" (nil) row only when NOT following, since a dual conditional needs two named themes.
  A palette PREVIEW writes the CURRENT-appearance slot (`previewTheme` writes the dark slot while following in dark mode, else `theme`), so the on-screen render reflects it and Esc restores the captured slot pair (both slots, snapshotted on open — flip-safe).
  COMMIT (`AppActions.commitThemePreview` → `SettingsModel.commitTheme(nonActiveOriginal:)`) persists the active (on-screen) slot's browsed value and RESTORES the off-screen slot to its pre-preview original, so a value browsed into the other slot during a mid-preview flip never commits; save-only in the common no-flip case (nothing to restore), one reload in the flip case to rewrite the dual line.
  The picker badges/opens on the EFFECTIVE theme (`activeTheme(isDark:)` — the on-screen slot), so the open-row preview is a config no-op.
- **Control parity = the commit, not the preview**
  (preview is interactive-only): `theme.set`/`theme.list` (see the Control API catalog for the four-point
  audit).
  The font-zoom reset on a theme change (any `apply()` that changes the config text runs `resetSessionFontSizesAllWindows`)
  applies to the preview too — navigating the picker clears per-session ⌘+/⌘− zoom and Esc does not bring
  it back; accepted (matches the Settings-picker behavior, a colors-only reload isn't cheaply available
  from libghostty).

- **Linux (GTK port): the preview is an UNPERSISTED override every preview-path reader must resolve
  through.**
  The Linux picker (`agterm-linux/Sources/AgtermLinux/ThemePicker.swift`) applies a theme without persisting
  it, and applying it makes libghostty emit `config_change` + OSC color-change actions whose handlers
  re-derive chrome/palette from settings — reading the store there repaints the preview with the OLD
  persisted theme (the sidebar "flashes then reverts" bug).
  `AppController.themePreviewSettings` (declared in `GhosttyConfigTheme.swift`, next to its readers) holds
  the live preview: `previewTheme` sets it, and it is cleared on commit (`applyTheme`) and by
  `teardownThemePicker()`, the ONE exit path `closeThemePicker` and `themePickerWasDestroyed` share — a
  leaked override pins the whole process to a stale theme until restart, so any preview state added later
  must be cleared there too.
  Clearing it is necessary but not sufficient — an exit that clears WITHOUT reverting strands the last
  preview on every live surface, which the next chrome re-resolve then repaints from the persisted theme,
  so the terminal palette and the chrome disagree.
  Two exits therefore route through `cancelTheme()` rather than a bare close: `windowWillClose` calls it
  directly (the picker is its own toplevel, and GTK4 does NOT destroy a transient child with its parent, so
  `themePickerWasDestroyed` may never fire), and `commitTheme` falls through when no row resolves — a query
  matching no theme leaves the list EMPTY, so Enter has nothing to commit.
  `cancelTheme` owns the "is a picker still up?" guard itself, BEFORE it sets the override — its clear runs
  inside `closeThemePicker`, which is a no-op with no picker, so a cancel arriving after teardown would
  otherwise set a process-global override nothing would ever clear; keeping the guard at the entry point
  rather than in each of its three callers (Esc in `onThemeKey`, the `commitTheme` fallthrough, and
  `windowWillClose` — the `row-activated` and entry-`activate` signals reach it only through `commitTheme`)
  is what makes that unreachable.
  Both readers — `applyResolvedWindowThemeColors` and `GhosttyApp.configWithOverlay` — go through
  `AppController.resolvedThemeSettings(persisted:)`, the single place the `preview ?? persisted` precedence
  is spelled out; `AppController.themeSettings(_:base:)` is the shared builder for the preview and the
  commit (both pin ONE appearance-independent theme, clearing `darkTheme`/`followSystemAppearance`).
  Reading the override made `configWithOverlay` `@MainActor` (a `@MainActor` static cannot be reached from a
  nonisolated autoclosure) — the shape any future override reader will need too.
  Covered host-free by `AgtermLinuxTests/GhosttyConfigThemeTests.swift`
  (`AppControllerThemeSettingsTests`); the picker's own preview/commit/cancel remains a manual GUI check.
  KNOWN, ACCEPTED: the override is a process-global `static`, and the two APP-GLOBAL re-appliers that
  bypass the picker — `setTheme` (the `theme.set` control arm) and the desktop light/dark flip
  (`onColorSchemeChanged`) — both `reloadConfig()` from PERSISTED settings without clearing it, so while a
  live preview is up the terminals repaint persisted while the chrome still resolves the preview.
  It needs a socket call or a desktop theme flip to RACE an open picker, and it self-heals on the next
  picker exit (commit or cancel both re-resolve the chrome), so it is documented rather than fixed —
  clearing the override from those paths would silently drop the user's in-progress preview instead.
