# Linux settings and integrations parity plan

## Objective

Complete the existing GTK4/libadwaita Settings experience and provide a native Linux equivalent of the macOS CLI, hooks, and agent-skill installation menu.
Keep the Linux port aligned with upstream product behavior while adapting package management, compositor-owned effects, and filesystem integration to Linux conventions.

## Approved product decisions

- Use a hybrid native-and-text model.
- Provide native controls for common settings and keep `ghostty.conf` and `keymap.conf` as first-class advanced configuration surfaces.
- Treat `settings.json` as internal persistence rather than a user-edited configuration file.
- Keep the content toolbar menu-free; expose Preferences through `Ctrl+,` and expose auxiliary routes through the command palette.
- Make `Ctrl+,` open Preferences.
- Organize Preferences into General, Appearance, Notifications, Agent Status, Key Mapping, and Integrations pages.
- Replace the command palette's immediate hooks and skill mutations with entry points into the Integrations page.
- Show integration status and an exact installation preview before changing files.
- Keep DEB/RPM-owned `agtermctl` installations under package-manager control.
- Allow tar installations to create or update an agterm-owned launcher in `~/.local/bin`.
- Do not expose macOS background blur on Linux because blur is compositor-owned.
- Do not add a Linux-only generic runtime settings protocol.

## Current state

- `agterm-linux/Sources/AgtermLinux/Settings.swift` already implements a partial `AdwPreferencesDialog`.
- Preferences are currently reachable only through the command palette.
- The content header intentionally has no primary menu button.
- Existing settings cover portions of General, Appearance, and Key Mapping.
- The current “Copy on select” row is incorrectly bound to `rightClickPaste` and must be relabelled “Right-click pastes”.
- Notification and agent-status controls exist but are mixed into General instead of matching upstream's page structure.
- `LinuxAgentIntegrations.swift` already installs Claude/Codex hooks and the bundled agent skill using shared merge decisions.
- The existing palette actions mutate integration files immediately and do not provide a persistent status view or preflight plan.
- Linux packages already ship `agtermctl`; only portable tar-style installs need an in-app launcher action.

## Platform adaptations and exclusions

- Use `AdwPreferencesDialog`, `AdwPreferencesPage`, and native GTK/libadwaita rows instead of reproducing the macOS Settings implementation widget-for-widget.
- Use native GTK file and directory choosers for paths.
- Keep terminal configuration in `ghostty.conf`; do not duplicate the full Ghostty option catalog in Preferences.
- Do not add a fake application blur setting.
- Present a short explanation that Wayland/X11 compositor configuration owns background blur.
- Do not run `sudo`, invoke a distribution package manager, or replace package-owned binaries from the application.
- Never overwrite unrelated executables, hooks, settings, or skills.
- Preserve symlinks, file modes, backups, and existing conflict behavior during hook installation.
- Keep all integration inspection and mutation code in Linux-owned targets.

## Architecture and ownership

### Settings UI

Split the existing 528-line settings implementation before adding behavior.
Keep GTK/libadwaita construction in the Linux application target.

Planned files:

- `agterm-linux/Sources/AgtermLinux/LinuxSettingsController.swift`
  owns loading, persistence, resets, live application, and debounced previews.
- `agterm-linux/Sources/AgtermLinux/SettingsDialog.swift`
  owns one-dialog-per-window lifecycle and direct page selection.
- `agterm-linux/Sources/AgtermLinux/SettingsGeneralPage.swift`
- `agterm-linux/Sources/AgtermLinux/SettingsAppearancePage.swift`
- `agterm-linux/Sources/AgtermLinux/SettingsNotificationsPage.swift`
- `agterm-linux/Sources/AgtermLinux/SettingsAgentStatusPage.swift`
- `agterm-linux/Sources/AgtermLinux/SettingsKeyMappingPage.swift`
- `agterm-linux/Sources/AgtermLinux/SettingsIntegrationsPage.swift`
- `agterm-linux/Sources/AgtermLinux/AppControllerPrimaryMenu.swift`
  owns the Preferences shortcut and auxiliary Keyboard Shortcuts/About dialogs.

The exact split may reuse small existing helpers when that keeps each file focused and below lint limits.
Do not move GTK types or side effects into `agtermCore`.

### Integration engine

Add a Linux-local library target used by both the GTK application and Linux `agtermctl`.
The target may depend on Foundation and `agtermCore`, but not GTK.

Planned files:

- `agterm-linux/Sources/LinuxIntegrations/IntegrationEnvironment.swift`
  provides injectable home, PATH, resource, executable, and filesystem locations.
- `agterm-linux/Sources/LinuxIntegrations/IntegrationStatus.swift`
  defines typed CLI, hooks, and skill status snapshots.
- `agterm-linux/Sources/LinuxIntegrations/IntegrationPlan.swift`
  defines preflight operations, conflicts, warnings, and user-facing summaries.
- `agterm-linux/Sources/LinuxIntegrations/IntegrationInstaller.swift`
  applies only a previously validated plan and returns per-operation results.
- `agterm-linux/Sources/agtermctl/IntegrationCommands.swift`
  exposes local integration commands without connecting to the control socket.

Refactor `LinuxAgentIntegrations.swift` into a GTK presentation adapter around this library.
Reuse `AgentHooksInstall` and `SkillInstall` decisions from `agtermCore` instead of copying their merge rules.

### Control and text surfaces

Existing `theme set/list`, `config reload`, and `keymap reload` commands remain the supported runtime automation surfaces.
`ghostty.conf` and `keymap.conf` remain the supported text configuration surfaces.
Do not introduce Linux-only `settings get/set/reset` protocol cases because a generic settings protocol must be designed upstream-first and shared by both hosts.

The integration commands are exempt from control-socket coverage because they inspect and modify local installation files rather than active application state.
They must work when agterm is not running.

## Implemented settings inventory and parity audit

This inventory was recorded before closeout against the upstream `AppSettings` model and macOS Settings grouping.
“Reset” names the Linux reset path; fields without a reset button retain their upstream default semantics through the control itself.

| `AppSettings` field | Effective default | Linux page and live side effect | Reset / parity |
| --- | --- | --- | --- |
| `fontFamily` | Ghostty default | Appearance; rebuilds live Ghostty config | Terminal defaults; shared |
| `fontSize` | 13 pt | Appearance; reloads config and resets per-session zoom | Terminal defaults; shared |
| `theme` | `agterm` on first load | Appearance; applies theme OSC and window colors | Terminal defaults; shared |
| `darkTheme` | unset | Appearance alternate theme while following system | Terminal defaults; shared |
| `followSystemAppearance` | off | Appearance; switches between single and dual theme slots | Terminal defaults; shared |
| `backgroundOpacity` | 100% | Appearance; debounced persistence with immediate renderer/window preview | Window defaults; Linux-adapted composition |
| `backgroundBlur` | none | Omitted; compositor ownership is explained beside opacity | Inapplicable on Linux |
| `notificationsEnabled` | on | Notifications; gates desktop banners | Control default; Linux-adapted desktop delivery |
| `notificationBadgeEnabled` | on | Notifications; rebuilds sidebar badges immediately | Control default; shared |
| `toolbarMode` | compact | Appearance; rebuilds toolbar in every window | Window defaults; Linux-adapted header |
| `compactToolbar` | legacy decode shim | No separate control; cleared when toolbar mode changes | Window defaults; compatibility-only |
| `activeStatusColorHex` | `#3584e4` | Agent Status; updates GTK status CSS | Colors and sound; shared |
| `blockedStatusColorHex` | `#e5a50a` | Agent Status; updates GTK status CSS | Colors and sound; shared |
| `completedStatusColorHex` | `#2ec27e` | Agent Status; updates GTK status CSS | Colors and sound; shared |
| `configDirectory` | `~/.config/agterm` | Key Mapping; creates starters and reloads keymap/Ghostty config | Use Default; shared path model |
| `mouseScrollMultiplier` | 3 | General; reloads live Ghostty config | Control default; shared |
| `inactivePaneMuteStrength` | 5 | Appearance; updates all pane dimming | Window defaults; shared renderer behavior |
| `sidebarBackgroundShift` | 5 (neutral) | Appearance; updates sidebar color | Window defaults; Linux-adapted CSS |
| `restoreRunningCommand` | off | General; controls next-launch pane command restoration | Control default; shared |
| `inheritGlobalGhosttyConfig` | off | General; reloads the live config chain | Control default; shared |
| `attentionButtonEnabled` | off | Notifications; updates every window toolbar | Control default; shared |
| `blockedStatusSoundName` | none | Agent Status; previews/uses the desktop bell | Colors and sound; Linux-adapted sound catalog |
| `rightClickPaste` | on | General; reloads Ghostty right-click action | Control default; shared, corrected label |
| `newSessionDirectory` | home | General; controls new-session cwd selection | Home option; shared |
| `newSessionCustomDirectory` | unset | General native folder chooser and displayed path | Replaced by next choice; shared |
| `confirmCloseSession` | off | General; gates GUI close confirmation | Control default; shared |
| `closeGraceUndoEnabled` | on | General; controls the shared close undo grace | Control default; shared |
| `autoFollowAttention` | off | Agent Status; applies per-window idle timeout | Disabled option; shared |
| `autoFollowStayOnActive` | off | Agent Status; applies per-window running-session hold | Control default; shared |
| `sidebarFontSize` | 13 pt | Appearance; resizes and rebuilds sidebar rows | Window defaults; shared |

The Linux host keeps all shared values in `agtermCore.AppSettings`, while GTK construction, persistence side effects, compositor adaptations, and integration filesystem work remain in Linux-owned targets.

## Task 1: Establish the settings controller and file boundaries

- [ ] Inventory every existing `AppSettings` field, side effect, default, and reset path before moving code.
- [ ] Compare the current upstream macOS Settings pages and record whether each setting is shared, Linux-adapted, or inapplicable.
- [ ] Extract dialog lifecycle, persistence, and page builders from `Settings.swift` without changing behavior.
- [ ] Centralize typed setting mutations so each control persists and applies through one path.
- [ ] Preserve live terminal/sidebar/theme updates and debounce expensive appearance previews.
- [ ] Ensure closing or reopening Preferences cannot create duplicate dialogs for one window.
- [ ] Support opening the dialog directly to a requested page.
- [ ] Keep the command palette Preferences action working throughout the refactor.
- [ ] Delete the old monolithic implementation only after all migrated controls build and work.

## Task 2: Add native application entry points

- [ ] Keep the normal content header menu-free and register `Ctrl+,` directly on each window.
- [ ] Add Preferences, Integrations, Keyboard Shortcuts, and About actions.
- [ ] Bind `Ctrl+,` to Preferences and keep it available when the toolbar is hidden.
- [ ] Make Integrations open Preferences directly to the Integrations page.
- [ ] Implement Keyboard Shortcuts as a native shortcuts window populated from resolved/default bindings, with a route to Key Mapping for customization.
- [ ] Implement a native About dialog using Linux package metadata, version, license, and repository links.
- [ ] Keep command-palette equivalents available for keyboard-first and toolbar-hidden use.
- [ ] Verify header background, focus state, sidebar divider, and draggable resize behavior remain unchanged.

## Task 3: Complete General and Appearance parity

### General

- [ ] Preserve toolbar visibility, command restoration, close confirmation, close-undo duration, default session directory, and scroll-speed controls.
- [ ] Replace the raw directory-only workflow with a native directory chooser while retaining direct text entry where useful.
- [ ] Correct the mislabeled `rightClickPaste` setting to “Right-click pastes”.
- [ ] Add the applicable upstream global Ghostty-config inheritance option if the Linux bridge supports the same behavior.
- [ ] Show concise restart/reload guidance only for settings that cannot apply live.

### Appearance

- [ ] Preserve font size, font family, window opacity, sidebar tint, sidebar font size, theme, dark theme, and status-color controls.
- [ ] Add inactive-pane muting when supported by the current Linux renderer.
- [ ] Add native font and color selection affordances where GTK provides a suitable control.
- [ ] Add per-section reset actions and ensure resets update persistence and live UI together.
- [ ] Explain that compositor configuration controls blur and omit a non-functional blur toggle.
- [ ] Keep advanced terminal appearance settings in `ghostty.conf` and provide an Open Configuration action.

## Task 4: Complete Notifications, Agent Status, and Key Mapping parity

### Notifications

- [ ] Move notification banner, badge, and attention behavior out of General into a dedicated page.
- [ ] Match upstream labels, help text, defaults, and reset behavior where Linux notifications support them.
- [ ] Clearly identify any desktop-environment limitation rather than silently ignoring a setting.

### Agent Status

- [ ] Move agent-status colors and behavior into a dedicated page.
- [ ] Add blocked-status sound selection, preview, and reset if the Linux audio backend can support it natively.
- [ ] Add auto-follow timeout and stay-active behavior with the same shared semantics as upstream.
- [ ] Keep hooks installation out of this page and link to Integrations for setup or repair.

### Key Mapping

- [ ] Preserve keymap directory display and reload behavior.
- [ ] Add Open Keymap, Open Directory, and Reload actions.
- [ ] Surface parse diagnostics and the active configuration path in the dialog.
- [ ] Keep `keymap.conf` authoritative and avoid storing a second binding representation in `settings.json`.
- [ ] Ensure changes made externally can be reloaded without restarting the application.

## Task 5: Build status-driven Linux integration services

- [ ] Add the `LinuxIntegrations` library and test target to `agterm-linux/Package.swift`.
- [ ] Make the environment fully injectable so tests never inspect or mutate the developer's real home directory.
- [ ] Produce one idempotent status snapshot for CLI, Claude hooks, Codex hooks, and the bundled skill.
- [ ] Represent Not installed, Installed, Update available, Partial, and Conflict states explicitly where applicable.
- [ ] Generate an exact preflight plan before any write, including target paths, backups, replacements, skipped files, and conflicts.
- [ ] Refuse to apply a stale plan if relevant source or destination state has changed.
- [ ] Return structured per-operation results that both GTK and JSON CLI output can render.

### CLI detection and installation

- [ ] Detect `agtermctl` through PATH, the application bundle, known package locations, and the current executable layout.
- [ ] Identify package-owned DEB/RPM installations and report that updates belong to the package manager.
- [ ] For portable archives, offer an agterm-owned symlink at `~/.local/bin/agtermctl`.
- [ ] Create or update only a missing, broken, or agterm-owned launcher.
- [ ] Report a conflict for an unrelated file or executable and never replace it.
- [ ] Never request elevation or write outside user-owned locations.

### Hooks and skill

- [ ] Inspect Claude and Codex independently and show per-agent status.
- [ ] Preserve current backup, symlink, mode, malformed-settings, and custom-hook protections.
- [ ] Keep installation idempotent and distinguish repair from update.
- [ ] Detect supported skill destinations and show the selected destination path.
- [ ] Install or update only absent or agterm-managed skill directories.
- [ ] Refuse to overwrite an unrelated skill with the same name.

## Task 6: Add the Integrations Preferences page

- [ ] Present separate CLI, Claude hooks, Codex hooks, and Agent Skill cards or groups.
- [ ] Show status, detected path/version, last inspection result, and the action appropriate to each state.
- [ ] Refresh status when the page opens and through an explicit Refresh action.
- [ ] Show the full preflight plan in a confirmation dialog before installation, update, or repair.
- [ ] Disable mutation when conflicts exist and give a precise manual resolution path.
- [ ] Show structured success, partial-success, and failure results without hiding individual operations.
- [ ] Replace immediate command-palette installer actions with Manage Integrations routes.
- [ ] Keep all filesystem work off the GTK main loop and marshal presentation updates back to the UI context.

## Task 7: Add local `agtermctl integration` commands

- [ ] Add `agtermctl integration status` with readable terminal output.
- [ ] Add `agtermctl integration status --json` using a stable, documented response shape.
- [ ] Add `agtermctl integration install hooks` with the same preflight and safeguards as the GUI.
- [ ] Add `agtermctl integration install skill` with the same preflight and safeguards as the GUI.
- [ ] Support `--dry-run` for mutating integration commands.
- [ ] Keep these commands local and avoid requiring `--socket` or a running agterm process.
- [ ] Return distinct nonzero exit statuses for conflicts, invalid resources, and failed writes.
- [ ] Do not add a self-updating CLI command; CLI launcher installation remains a package-aware GUI action.

## Task 8: Test behavior and safety

### Host-free and Linux-local tests

- [ ] Preserve all existing `agtermCore` tests for hook merge and skill-install decisions.
- [ ] Add temporary-home tests for every integration status transition.
- [ ] Test portable CLI symlink creation, update, broken-link repair, package-owned detection, and unrelated-file conflict.
- [ ] Test hook plan/apply idempotency, backups, symlink preservation, modes, partial installs, malformed JSON, and custom-hook conflicts.
- [ ] Test skill target detection, update, idempotency, and unrelated-directory protection.
- [ ] Test stale-plan rejection and structured partial-failure results.
- [ ] Test CLI parsing, JSON output, dry-run behavior, exit statuses, and independence from the control socket.

### GTK and accessibility tests

- [ ] Extend `agterm-linux/tests/atspi_smoke.py` to verify the absent menu button and open Preferences with `Ctrl+,`.
- [ ] Verify `Ctrl+,` opens the existing dialog and each page is accessible.
- [ ] Change representative settings and verify both `settings.json` persistence and live UI application.
- [ ] Assert the corrected “Right-click pastes” label and binding.
- [ ] Exercise integration status, preflight, cancellation, and safe installation in isolated `HOME` and `AGTERM_STATE_DIR` directories.
- [ ] Confirm no UI test reads or mutates the user's actual sessions, configuration, hooks, skill, or PATH launcher.
- [ ] Verify the application remains usable with the toolbar hidden.

### Visual acceptance

- [ ] Build and launch an isolated development instance for manual review.
- [ ] Check the menu-free toolbar, all Preferences pages, focus colors, sidebar divider, narrow-window behavior, keyboard navigation, and light/dark themes.
- [ ] Leave the isolated instance hands-off for user testing after launch.

## Task 9: Documentation, CI, and closeout

- [ ] Document Preferences, `Ctrl+,`, text configuration boundaries, compositor-owned blur, and integration management in `README.md` and relevant Linux docs.
- [ ] Document package-specific CLI behavior for DEB, RPM, AppImage/tar, and development builds.
- [ ] Document all `agtermctl integration` commands, JSON output, dry-run behavior, and exit statuses.
- [ ] Update `agterm/Resources/agent-skill/` because the Linux CLI surface changes.
- [ ] Do not edit installed skill copies under user home directories.
- [ ] Do not update `CHANGELOG.md` until a release is intentionally prepared.
- [ ] Add Linux package tests to CI after re-reading the CI and release subsystem rules.
- [ ] Run strict lint, shared tests, Linux-local tests, debug builds, release build, and isolated GTK smoke tests.
- [ ] Inspect the complete downstream diff for ownership boundaries and upstream compatibility.
- [ ] Leave unrelated `site/_screenshot.png` untouched.
- [ ] Move this plan to `docs/plans/completed/` only after every required item passes.

## Validation commands

```sh
cd agtermCore && mise x swift@6.3.2 -- swift test
cd agterm-linux && mise x swift@6.3.2 -- swift test
mise x swiftlint@0.65.0 -- swiftlint lint --strict --quiet
scripts/setup-linux.sh
cd agterm-linux && mise x swift@6.3.2 -- swift build --product agtermctl-linux
cd agterm-linux && mise x swift@6.3.2 -- swift build --product AgtermLinux
cd agterm-linux && mise x swift@6.3.2 -- swift build -c release
python3 agterm-linux/tests/atspi_smoke.py
git diff --check
```

Run package-content verification when the work is included in a release candidate.
Do not require a full DEB/RPM/AppImage release matrix for ordinary UI iteration, but complete it before publishing the next Linux revision.

## Completion criteria

- Preferences are discoverable from native Linux UI and `Ctrl+,`.
- Every applicable upstream settings group has a working Linux-native counterpart or a documented platform exemption.
- Text configuration remains authoritative for Ghostty and key mapping.
- Integrations show truthful status and exact plans before mutation.
- Package-owned files are never silently replaced.
- GUI and local CLI integration behavior use the same tested engine.
- Runtime control protocol remains upstream-compatible.
- Tests, lint, builds, accessibility smoke, documentation, and isolated visual acceptance all pass.
