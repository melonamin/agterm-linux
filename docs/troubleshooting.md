# Troubleshooting

A guide to checking what agterm is doing, the most common problems, and how to report one that turns out to be a bug.

## Where things live

Paths assume the defaults. When `AGTERM_STATE_DIR` is set, the state files and test configuration move under that directory instead of the platform application-support directory.

- **Keymap**: `~/.config/agterm/keymap.conf` (or `$AGTERM_STATE_DIR/config/keymap.conf`, or a custom directory set in Settings ▸ Key Mapping).
- **Ghostty config**: `~/.config/agterm/ghostty.conf` (same directory as the keymap), an agterm-scoped ghostty config that overrides the bundled defaults and your global `~/.config/ghostty/config`.
- **Settings**: `<state>/settings.json`.
- **Window and session state**: `<state>/windows.json` plus one `windows/<id>.json` per window.
- **Control socket**: `<state>/agterm.sock` (or `$AGTERM_CONTROL_SOCKET` when set). A spawned shell sees the bound path in `$AGTERM_SOCKET`.
- **macOS state**: `~/Library/Application Support/agterm`.
- **Linux state**: the Foundation application-support directory for the current user; run `printf '%s\n' "$AGTERM_SOCKET"` inside agterm to see the active directory, or set `AGTERM_STATE_DIR` for an isolated instance.
- **Logs**: macOS uses unified logging under `com.umputun.agterm`; Linux ControlServer diagnostics use GLib structured logging, which writes to journald when the process is journal-connected and to stderr otherwise. Other Linux diagnostics may still write directly to stderr.

## Reading the logs

On macOS, agterm logs to the unified logging system under `com.umputun.agterm`, so use `log` or Console:

```bash
# the last 30 minutes, all categories
log show --predicate 'subsystem == "com.umputun.agterm"' --info --last 30m

# follow live while you reproduce the problem
log stream --predicate 'subsystem == "com.umputun.agterm"' --info

# narrow to one area
log show --predicate 'subsystem == "com.umputun.agterm" && category == "CustomCommandRunner"' --info --last 30m
```

The categories are `GhosttyApp`, `GhosttySurfaceView`, `WatermarkRenderer`, `NotificationManager`, `SettingsView`, `SettingsModel`, `CustomCommandRunner`, and `ControlServer`.
In Console.app, filter on the same subsystem.

On Linux, ControlServer diagnostics use GLib structured logging.
When the desktop process is journal-connected, journald stores the structured fields; otherwise GLib writes to stderr, so launching the binary from a terminal keeps the entries visible.

```bash
# ControlServer diagnostics from the last 30 minutes
journalctl --user -t agterm GLIB_DOMAIN=ControlServer --since "30 minutes ago"
```

Other Linux diagnostics may still write directly to stderr without these structured fields.

## Checking Linux integrations

The Integrations page and the local CLI use the same inspection engine.
The CLI does not connect to the control socket, so it also works while agterm is stopped:

```bash
agtermctl integration status
agtermctl integration status --json
agtermctl integration install hooks --dry-run
agtermctl integration install skill --dry-run
```

A `conflict` status means agterm found unrelated content and deliberately refused to replace it.
For a multi-target hooks or skill install, independently safe targets can still be applied while the protected target is skipped and reported.
Read the reported path and detail, move or merge that content yourself, then refresh the Integrations page.
Exit status `2` is a protected conflict, `4` is a filesystem write failure, `1` is an unavailable bundled resource, and `64` is a malformed command line.

Native DEB/RPM installations keep `/usr/bin/agtermctl` under package-manager ownership.
Tar and development builds can create an agterm-owned launcher in `~/.local/bin` from Preferences ▸ Integrations.
AppImage and Flatpak builds do not offer a host launcher because their executable paths are temporary or sandbox-local; use a native package, an extracted AppImage, or the tar archive for a persistent CLI.

Hook installation preserves existing settings and writes a backup before changing Claude or Codex configuration.
Malformed settings and pre-existing custom hook definitions are reported as conflicts for manual resolution.
The skill installer updates only an agterm-managed `~/.claude/skills/agterm` or `~/.codex/skills/agterm` directory and refuses an unrelated directory with the same name.

Pi integration is available only after Pi has created `~/.pi/agent`.
After installing or updating hooks, restart Pi or run `/reload` so it loads
`~/.pi/agent/extensions/agterm-status.ts`.
An unmarked file at that path is user-owned and is reported as a conflict rather than replaced.

## Checking packaged Ghostty resources on Linux

Release artifacts contain the pinned Ghostty themes, shell integration, and an `xterm-ghostty` terminfo entry.
Run `scripts/verify-linux-resources.sh <payload>/share` from a checkout to validate an extracted tar, DEB, or RPM
payload; `scripts/verify-linux-packages.sh VERSION DIRECTORY` checks all four release formats.
The app uses `TERM=xterm-ghostty` only when it resolves both the shell-integration tree and sibling terminfo entry.
If either is missing, it uses the portable `TERM=xterm-256color` fallback instead of advertising an unavailable
terminal definition.

## Dashboard or notification navigation looks wrong on Linux

The dashboard opens from **Ctrl+Shift+M**, the command palette, or the grid button beside Quick Terminal.
A single click briefly highlights a cell before entering its exact pane; keyboard Enter enters immediately.
Dashboard and terminal-zoom headers show `Dashboard` or the active session title plus a custom window name.

A desktop notification is suppressed only when its exact terminal surface is focused in the active window.
Clicking a delivered notification selects its encoded pane and reopens its source window if that window was closed.
An explicit `agtermctl notify` request deliberately bypasses focus suppression.

## Terminals show "Terminal rendering needs OpenGL" on Linux

The bundled Ghostty renderer is desktop-OpenGL-only, so the terminal widget pins its GL area to desktop GL.
When that context cannot be created, the pane shows a generic overlay and the real reason goes to stderr:

```
agterm: GtkGLArea failed to create a GL context: <driver message>
```

Capture it by launching the binary from a terminal, or with `journalctl --user` as described under **Reading the logs**.
The known cause is GTK 4.16 and later preferring the OpenGL ES API for its own EGL paint context, which makes a desktop-GL sibling context unrealizable; agterm now prevents it by setting `GDK_DISABLE=gles-api,vulkan` (`GDK_DEBUG=gl-disable-gles,vulkan-disable` on GTK 4.14–4.15) before GTK initializes.
That is why a launch from a terminal prints one line such as `agterm: setting GDK_DISABLE=gles-api,vulkan` — it is expected, not an error, and `agterm: failed to set …` instead means the assignment did not take.
Nothing is printed when there is nothing to assign: on GTK below 4.14 neither spelling exists, an ordinary
environment that already carries both tokens is left exactly as it is, and `all` already selects both flags.
Because GDK interprets tokens after `all` as exclusions, agterm removes either required flag if it appears
there; appending it would re-enable the feature the policy must disable.

To look deeper, run with `GDK_DEBUG=opengl` and read the context decisions: a paint context reported as `es:yes` is the GLES preference, and after the fix every context should report `es:no` with a desktop GL version.
The `vulkan` token is part of the fix, not a tuning knob: with GTK's Vulkan renderer active, GSK cannot import the desktop-GL terminal texture and falls back to a per-frame CPU readback that is retained, which shows up as steadily climbing memory under heavy terminal output.

## Checking the keymap

After editing `keymap.conf`, nothing changes until you reload it.

- **Settings ▸ Key Mapping** shows a read-only list of parse problems (a malformed line, a dropped binding, a conflict). This is the first place to look when a binding does not behave.
- **File ▸ Reload Keymap** re-reads the file. A reload that found problems posts a banner with the count.
- **`agtermctl keymap reload`** does the same from the command line and prints the diagnostic count (`0` means a clean reload).
- **`agtermctl keymap list`** shows what is actually bound: every built-in with the chord it resolved to, the custom commands, each diagnostic in full rather than just a count, and the key equivalents the menu bar is really carrying.

## A keybinding does not fire

Run `agtermctl keymap list` and compare its two lists. If the action's chord is what you expect but no menu entry carries it (or a different item does), the keymap is fine and the menu is stale: agterm rebuilds the menu when the app next becomes active, so switch to another app and back, and relaunch if it persists.

One built-in is legitimately missing from the menu list: `undo_close` (⌘Z) is delivered by a key monitor rather than a menu item, so that native text undo keeps working in the rename, palette and Settings fields. Its absence there is expected.

## The keymap editor will not open

**Edit Keymap** (File ▸ Edit Keymap…, or the `⌃⇧P` palette) opens `keymap.conf` in `$VISUAL`, else `$EDITOR`, else `vi`, inside a floating overlay over the active session. The overlay runs the editor through your login shell, so the editor resolves the same way it does in a normal terminal — whether your login shell is zsh/bash or fish.

Common causes when nothing usable appears:

1. **A GUI editor without its blocking flag.** Editors like VS Code, Sublime, Zed, and TextMate launch a detached window and return immediately, so the overlay opens and closes in a flash. Set the editor's wait flag so the launcher blocks until you close the file:

   ```bash
   export EDITOR='code -w'     # VS Code; also: 'subl -w', 'zed -w', 'mate -w', 'cursor -w'
   ```

2. **`$EDITOR` unset.** You get `vi` inside the overlay. Press `i` to start typing, then `Esc` and `:wq` to save and quit; the keymap reloads when the editor exits.
3. **No active session, or an overlay is already open.** Edit Keymap is a no-op with no session selected, or while another overlay or the quick terminal is up. Select a session and close any overlay first.

Set and **export** `$EDITOR` or `$VISUAL` in your shell startup file (`export EDITOR=…` in `~/.zshrc`/`~/.bashrc`, or `set -gx EDITOR …` in `~/.config/fish/config.fish`), not just in the current shell. The overlay reads the *exported* value from your login shell, so a value that lives in one terminal session only — or one set without `export` — is not seen and falls back to `vi`.

## A custom action does nothing

Work down this list:

1. **Read the diagnostics.** Open Settings ▸ Key Mapping. A malformed `command` line is listed there and skipped.
2. **Chord conflict.** If your chord collides with a built-in shortcut or with another custom command, the binding is dropped and the command becomes palette-only. It still runs from the action palette (`⌃⇧P`), where it is listed with a `custom` tag. Pick a free chord, or run it from the palette.
3. **Reserved chords.** `ctrl+tab` / `ctrl+shift+tab` (the session switcher), `ctrl+1` / `ctrl+2` (pane focus), and Linux `ctrl+,` (Preferences) are reserved and cannot be bound.
4. **Modifier-less keys are rejected.** A custom chord needs at least one modifier so it cannot shadow a plain terminal key. `command "x" g …` is palette-only; `command "x" cmd+g …` binds.
5. **Focus.** A custom chord fires only while a terminal pane holds keyboard focus. When the sidebar, the inline rename field, a Settings field, or a palette has focus, the chord passes through. Click into the terminal first.
6. **The command runs in a plain `/bin/sh -c`, not your login shell.** It does not load `~/.zshrc` or `~/.bashrc`, so shell aliases and functions are not available and `PATH` may be shorter than in your terminal. Use absolute paths, or wrap the body in `$SHELL -lc '…'`.
7. **Exit status.** A non-zero exit posts a failure banner with the code. No banner and no effect usually means the chord never fired (causes above). A banner means it ran and failed, which points at the command itself, its `PATH`, or its arguments.
8. **Token quoting.** `{AGT_SELECTION}` and the other `{AGT_*}` tokens expand raw into the shell line. For content that may contain shell metacharacters, use the `$AGT_SELECTION` environment form, which is already quoted. The token list is in the [keymap section of the documentation](https://agterm.com/docs#keymap).

Reload after every edit (File ▸ Reload Keymap, or `agtermctl keymap reload`). Edits are not applied until you do.

## Changing ghostty settings

Most terminal behavior comes from ghostty. Use agterm's Settings for its built-in controls and a config file for other ghostty keys such as `macos-option-as-alt`, `keybind`, and `window-padding-*`.

agterm reads four config sources, each overriding the one before it:

```
ghostty's bundled defaults  →  ~/.config/ghostty/config  →  <config dir>/ghostty.conf  →  agterm Settings
       (lowest)                    (your global config)         (agterm-scoped)             (UI wins)
```

- `<config dir>/ghostty.conf` (default `~/.config/agterm/ghostty.conf`, next to `keymap.conf`) is scoped to agterm only; the standalone Ghostty.app never reads it. Use it for keys you want in agterm but not everywhere.
- `~/.config/ghostty/config` is your global ghostty config, shared with Ghostty.app, and already in the chain.
- Values agterm emits from Settings load last and win over matching values in `ghostty.conf`. The [Ghostty config guide](https://agterm.com/docs#ghostty) lists the keys. Put everything else in `ghostty.conf`.

Edit `ghostty.conf` with **File ▸ Edit ghostty.conf…** (or the ⌃⇧P palette), which opens it in `$EDITOR` and reloads on exit, the same as Edit Keymap. After editing it elsewhere, apply it with **File ▸ Reload Config**, the action palette, or `agtermctl config reload`. A malformed line is skipped while the good ones still apply. The diagnostic count (shown in a banner and printed by `config.reload`, where `0` means a clean reload) covers every ghostty config source, not just `ghostty.conf`, because the diagnostics do not record which file they came from. Check the Console log for the offending line.

A reload applies most keys to your open terminals right away — colors, theme, `cursor-style`, `macos-option-as-alt`, and the mouse and clipboard keys all take effect on the visible pane. Two kinds of key cannot change for a terminal that is already running, though:

- **Layout keys** — `window-padding-x`, `window-padding-y`, and other size-affecting keys — do not re-apply to an open pane. libghostty re-derives a surface's padding only when it is first laid out, so a reload (and even resizing the window) leaves existing panes on their old padding. Open a new session or new window to pick up the change; the panes that were already open need a relaunch.
- **Spawn-time keys** — `term` and `shell-integration-features` — are read once when the shell starts, so a reload cannot change them for a shell that is already running. Open a new session, whose shell is spawned fresh, to apply them.

The full ghostty key reference is at <https://ghostty.org/docs/config>. One pair of values in it does not apply to agterm: the `ssh-env` and `ssh-terminfo` values of `shell-integration-features`. Ghostty implements both by replacing your `ssh` with a wrapper that calls the `ghostty` command-line tool absent from agterm's bundle, so in agterm the wrapper would fail on every connection. agterm forces those two values back off and keeps the rest of your `shell-integration-features` flags, so `ssh` stays the real `ssh`. If you need agterm's terminfo entry on a remote host, install it there once with `infocmp -x xterm-ghostty | ssh <host> 'tic -x -'`.

## A Live session came back as a fresh shell on Linux

Live mode is fixed when agterm starts.
After selecting **Preferences ▸ General ▸ Restore sessions ▸ Live sessions**, restart the app.
Linux requires zsh as the password-database login shell, Ghostty's bundled zsh integration, and the
executable zmx runtime bundled by the release packages or staged by `scripts/setup-linux.sh`.
If zmx is unavailable, agterm preserves the requested mode but safely starts ordinary shells.

Use `agtermctl tree --json` to inspect `backedByZmx` and `agtermctl zmx list` to compare running daemons
with their claimed panes.
Only local primary and split panes are eligible; scratch, overlay, Quick, and SSH-attached panes are
temporary or remote adapters.
A clean app quit leaves eligible daemons alive, while explicitly deleting a session, split, workspace, or
window kills its daemon after any undo grace period.
A reboot removes live daemons, so agterm recreates a missing pane from its last cleanly captured command.

`agtermctl zmx prune` removes only confirmed orphan daemons.
`agtermctl zmx kill --target <session> --pane left|right --force` explicitly ends one shown live pane.
An incomplete pane inventory reports an unknown claim and is never pruned speculatively.

## Copy/paste and shortcuts on a non-Latin or alternative layout

On Linux, agterm resolves shortcuts once per active layout, matching upstream macOS behavior.
ASCII-capable layouts remain semantic, so alternative Latin layouts and their shifted punctuation stay layout-local.
Layouts that cannot type the complete ASCII alphabet resolve every shortcut key by its physical ANSI position.
This keeps shortcuts such as Ctrl+Shift+J working after an English-to-Russian switch and also covers Greek or Hebrew positions that produce ASCII punctuation instead of letters.
Ctrl+Shift+Tab reverses the active Ctrl-Tab session cycle; Ctrl+Tab with additional modifiers remains reserved for that switcher.

⌘C and ⌘V copy and paste on any keyboard layout, non-Latin ones (Russian, Greek, and so on) included, because agterm binds them to the physical key positions rather than to the character a layout prints. The physical C and V keys then work no matter what those keys produce in the active layout.

The reason is that ghostty's own copy/paste binds match the produced character: on a Russian layout the physical V key yields `м`, so the built-in `super+v` bind never fires. The bundled agterm defaults add physical-key binds (`super+key_c`, `super+key_v`) that match by position instead.

On Linux the bundled defaults bind the terminal-convention chord the same way — `ctrl+shift+key_c`, `ctrl+shift+key_v`, and `ctrl+shift+key_a` — because bare Ctrl+C is SIGINT there. They match by physical position regardless of the produced glyph, so Ctrl+Shift+C/V/A keep working after switching to Russian, Greek, Hebrew, Arabic, or Thai.

On macOS, the physical `super+key_*` fallbacks always consume the key, even when there is nothing to act on: ⌘C with no selection does nothing at all, rather than reaching the running program.
That is deliberate.
The Edit menu disables Copy without a selection and Paste without pasteable content — on every layout — so those presses fall to the terminal's own bind, and a bind that declined them would let the chord through to key encoding.
A plain shell shows nothing either way, but under the kitty keyboard protocol, which Claude Code and other TUIs turn on, the program receives the chord as a key report and renders it as text — a stray `с` or `^[[1089;9u` in the prompt.
If you rebind copy or paste on macOS, do not add ghostty's `performable:` prefix for the same reason.

Linux deliberately keeps ghostty's `performable:` prefix on the bundled `ctrl+shift+key_c`, `ctrl+shift+key_v`, and `ctrl+shift+key_a` bindings.
When copy, paste, or select all cannot run, ghostty lets the chord fall through instead of consuming it.
Keep `performable:` on a Linux replacement if you want the same behavior; omit it only when you intentionally want an unavailable action to consume the chord.

The same distinction lets you remap any shortcut for your layout:

- A physical key name (`key_c`, `key_v`, `key_a`, and so on) matches the key's position, whatever character it prints.
- A bare letter (`c`, `v`) matches the character the active layout produces at that key.

If you use a Latin alternative layout (Dvorak, Colemak, AZERTY) and want ⌘C/⌘V at your layout's own C and V letters instead of the QWERTY physical positions, override them in `~/.config/agterm/ghostty.conf` with character-based binds, and unbind the physical defaults so the QWERTY positions are freed:

```
keybind = super+key_c=unbind
keybind = super+key_v=unbind
keybind = super+c=copy_to_clipboard
keybind = super+v=paste_from_clipboard
```

On Linux the same remap unbinds the `ctrl+shift+key_*` defaults instead. C, V, and A are three separate binds, so freeing and rebinding each one takes its own line:

```
keybind = ctrl+shift+key_c=unbind
keybind = ctrl+shift+key_v=unbind
keybind = ctrl+shift+key_a=unbind
keybind = ctrl+shift+c=copy_to_clipboard
keybind = ctrl+shift+v=paste_from_clipboard
keybind = ctrl+shift+a=select_all
```

Reload with **File ▸ Reload Config** or `agtermctl config reload`. The keybind syntax is at <https://ghostty.org/docs/config/keybind/reference>.

## Other common issues

- **`agtermctl: command not found`.** Install it from Help ▸ Install Command Line Tool… (it symlinks into `/usr/local/bin`). You can also call it by its full path inside the app bundle: `agterm.app/Contents/MacOS/agtermctl`.
- **No desktop notifications.** Check **Settings ▸ Notifications ▸ Show notification banners** first — when it is off, `agtermctl notify` still reports success and the unseen-count badge still tracks, but nothing is posted to macOS. Since agterm 0.17.0 the command says so, answering `badge updated, but "Show notification banners" is off, so no banner was posted` instead of a bare `ok`. macOS must also have granted permission (System Settings ▸ Notifications ▸ agterm), and Do Not Disturb / a Focus mode suppresses banners system-wide.

  To tell "never posted" from "posted but not shown", run `agtermctl notify "test"` and check two things: `agtermctl tree --json` — a rising `unseen` on the target session proves the command reached the notification path — and the log below, which now records every posted and every suppressed notification.
- **A permission prompt carrying agterm's name, or a tool that cannot get one.** Command-line tools request Automation, Camera, Microphone, Contacts, Calendars, Reminders, Photos, Location, Bluetooth, local network, speech recognition, system administration and system audio recording *through* agterm, so the prompt names agterm rather than the tool. A dismissed prompt is not re-offered, the tool just keeps failing (`osascript` reports "Not authorized to send Apple events"). See [Why agterm asks for camera, microphone and the rest](#why-agterm-asks-for-camera-microphone-and-the-rest) for why, what a grant then covers, and where to change your answer.
- **A command cannot read `~/Downloads`, `~/Desktop` or `~/Documents`.** Those folders are protected by macOS itself, separately from the services above, and the grant is per application — another terminal reading them says nothing about agterm. See [A command cannot read ~/Downloads, ~/Desktop or ~/Documents](#a-command-cannot-read-downloads-desktop-or-documents).
- **Agent-status glyph does not update.** Install the hooks from Help ▸ Install Agent Status Hooks…. For shell-integrated agents, start a fresh shell so the `source` line added to your shell rc takes effect. For Pi, restart it or run `/reload` so it loads `~/.pi/agent/extensions/agterm-status.ts`; Pi status is only installed when `~/.pi/agent` already exists. For OpenCode, restart it so it loads `~/.config/opencode/plugins/agterm-status.js`; the plugin installs only when `~/.config/opencode` already exists. The hooks call `agtermctl session status`, so `agtermctl` must resolve first (see above).
- **Agent-status glyph updates the wrong session.** One session's glyph blinks while the work happens in another — typically when agents run inside tmux (or a tmux-backed session manager such as agent-deck). The working process inherited another session's `AGTERM_SESSION_ID`: the status hooks target whatever id is in their environment, and a long-lived daemon started from inside an agterm session (a tmux server is the usual carrier) captures that session's `AGTERM_*` variables into its global environment and passes them to every child it ever creates. Check `tmux show-environment -g | grep AGTERM` — if present, clear them with `tmux set-environment -g -r AGTERM_SESSION_ID` (and the other `AGTERM_*` names), then restart the affected panes. To avoid it, start such daemons with the variables scrubbed (`env -u AGTERM_SESSION_ID … <command>`) or from a terminal outside agterm.

## Every session restores to the directory it was created in

Sessions come back in the directory they were opened in rather than the one you left them in, the directory
shown under the session name never follows a `cd`, `session reveal` opens the wrong folder, and
`{AGT_SESSION_PWD}` in a custom command expands to the creation directory.

agterm learns a session's working directory only from OSC 7, which Ghostty's shell integration reports.
That integration is injected into the shell agterm spawns and does not survive that shell replacing itself.
A startup file that `exec`s another shell replaces it before it ever reaches a prompt, so the directory is
never reported at all and every consumer falls back to the one the session started in. Shell-wrapper
installers do exactly this: Amazon Q CLI, Kiro CLI and Fig add an `exec` block at the top of `.zshrc`.

To confirm it, `cd` somewhere in the session and run `agtermctl tree --json`: if the session's `cwd` does
not follow the `cd`, nothing is reporting it.

The fix is Ghostty's own recipe — load the integration explicitly, below the block that replaced your
shell:

```zsh
if [[ -n "$GHOSTTY_RESOURCES_DIR" ]]; then
  builtin source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
fi
```

It is a no-op in a shell that already loaded it, so it is safe to add unconditionally. bash, fish and
nushell have their own integration files in the same `shell-integration` directory. Removing the wrapper
works too.

Three neighbouring cases share the cause, and the block above covers all but the last:

- **`exec zsh` typed at a prompt** replaces a shell that has already reported, so the directory freezes
  where it was rather than never being set. The replacement reads `.zshrc`, so the block fixes it.
- **`sudo -E zsh` or any other nested shell** is a child rather than a replacement: the directory stays
  frozen while it runs, then the outer shell resumes reporting at its next prompt.
- **A shell running inside tmux** needs the block *and* a tmux setting. tmux is a terminal emulator rather
  than a passthrough, so the pane shell's report goes to tmux, which forwards it to agterm only with its
  `osc7` terminal feature on — and its default `terminal-features` does not grant that to `xterm-ghostty`.
  Add `set -as terminal-features ',xterm-ghostty:osc7'` to `~/.tmux.conf` as well, then restart the tmux
  server.

Restoring a running command has its own limit, unrelated to the block above: with **Restore running
commands on restart** on, a pane behind a wrapper does not come back running what it was running. The
program is on a second terminal the wrapper owns, which agterm cannot see into, so the capture never
reaches it. Pin what such a pane should re-run with `agtermctl session restore '<command>'`, which is read
back on `tree` and wins over the capture.

## ⌘-hover does not underline links inside tmux or vim

Inside a program that has turned mouse reporting on, ⌘-hover stops underlining URLs, the pointer stays a
text bar instead of becoming a hand, and ⌘-click opens nothing. All four go together, and they come back
the moment you leave that program.

This is not a bug. libghostty detects links only while the foreground program has mouse reporting off, so
a program that captures the mouse takes link handling with it. Ghostty.app behaves the same way. It is
per-program, not a property of any category of app: `tmux` with `mouse on` and stock `vim` (whose
`defaults.vim` sets `mouse=a`) both suppress it, while an agent CLI that never touches mouse reporting
leaves links working normally.

Hold shift as well — ⌘⇧-hover and ⌘⇧-click — to bypass the capture without changing any setting. A program
can claim shift for itself with `XTSHIFTESCAPE`, in which case add `mouse-shift-capture = never` to
`~/.config/agterm/ghostty.conf` so shift always wins.

To turn mouse reporting off for every program instead, set `mouse-reporting = false` in the same file.
Selection and links then always work, at the cost of mouse support inside programs that wanted it — mouse
scrolling in `tmux`, clicking to position the cursor in `vim`.

## Claude Code's question or permission prompt stops responding after switching apps

While Claude Code shows an interactive prompt (a question menu or a permission dialog), switching to another app and back can leave that prompt unresponsive to the keyboard: the arrow keys and Return do nothing. The regular Claude Code prompt and the shell are unaffected, so you can still type there.

This is a Claude Code bug, not an agterm bug. When a window regains focus, agterm sends the standard terminal focus-in report (`ESC[I`, DEC private mode 1004), which any terminal does once an application turns focus reporting on. Claude Code's dialog input handler consumes that report instead of treating it as focus state, which wedges the prompt. It is tracked upstream as [anthropics/claude-code#72188](https://github.com/anthropics/claude-code/issues/72188); the mouse-click variant is [#72273](https://github.com/anthropics/claude-code/issues/72273).

agterm is behaving correctly: it emits paired focus-in and focus-out reports with nothing stray, and it follows the macOS focus-first convention, so a click that refocuses the window only focuses it and is not forwarded into the terminal. The trigger is the focus report itself, so any terminal with focus reporting on is affected the same way.

Workaround until the upstream fix: answer the prompt before switching away, or if you have already returned to a stuck prompt, press `Esc` to dismiss it and let Claude Code re-ask.

## Why agterm asks for camera, microphone and the rest

agterm's code signature carries seven resource-access entitlements: Automation (Apple Events), camera,
microphone, contacts, calendars, location and photos. agterm never touches any of them itself, and the
`NSxxxUsageDescription` strings in `Info.plist` say so.

They are there for the programs you run inside a session. macOS treats agterm as the *responsible app* for
what it spawns, so when a command-line tool asks for the microphone, the request is charged to agterm. This
is attribution, not inheritance: the entitlement has to sit on agterm precisely because the child does not
get one of its own. Under hardened runtime, which agterm is signed with, a missing entitlement does not
produce a denial. `tccd` refuses to prompt at all, records nothing, and agterm never appears in the matching
Privacy pane, so there is no way to approve it by hand either. The tool just fails, with nothing pointing at
the cause. Ghostty, kitty, iTerm2 and Macterm ship the same seven; WezTerm ships those plus Bluetooth.

**They grant nothing on their own.** An entitlement only makes the request possible. Every service is still
off until you approve it, and the first request raises the standard macOS prompt.

**What a grant gives away.** The answer is recorded against agterm, not against the command that asked for
it. Approve the camera once and every program in every session can use it from then on, with no further
prompt and no identity of its own, for as long as macOS attributes it to agterm. Code running as a
compromised agterm has the same access. That is the trade for running arbitrary tools in a terminal that can
obtain permissions at all, and it is worth knowing before approving something you only meant for one tool.

**Changing your mind.** Grants and denials both live in System Settings ▸ Privacy & Security under the
matching service, listed as agterm, for example Automation ▸ agterm. A dismissed prompt is not re-offered,
so if a tool keeps failing after you dismissed one, that is where to fix it.

## A command cannot read ~/Downloads, ~/Desktop or ~/Documents

`ls ~/Downloads` fails for a directory that belongs to you, and another terminal on the same Mac lists it
without complaint.

Those three folders, along with removable and network volumes, are protected by macOS directly. It is a
different mechanism from the section above: agterm is not sandboxed, and unlike the services listed there no
missing entitlement can suppress this family's prompt. macOS defines an optional usage-description string per
folder and agterm ships none, so the prompt carries macOS's own wording rather than agterm's. What matters is
that the answer is recorded against the application macOS holds responsible. Approving kitty or
Terminal says nothing about agterm, so a Mac where every other terminal reads the folder can still refuse
this one, and as with the services above a dismissed prompt is not re-offered and the command just keeps
failing.

Grant it in System Settings ▸ Privacy & Security ▸ Files & Folders, where agterm appears with a switch per
folder once something in a session has asked. Full Disk Access covers all of them at once and accepts agterm
from the + button without waiting for a request, at the cost of giving every program you ever run in a
session that same reach — the section above covers what a grant gives away.

To tell a privacy denial from ordinary permission bits, run `/bin/ls -la ~/Downloads` — the real `ls`,
against the folder itself, rather than a replacement such as `eza`. A privacy denial usually reads as
`Operation not permitted` and ordinary permission bits as `Permission denied`, and some replacements print
the same wording for both.

## Reporting a problem

Collect this before filing:

- agterm version (Agterm ▸ About Agterm).
- macOS version.
- The exact steps, what you expected, and what happened instead.
- A log excerpt from the `log show` command above, covering the moment you reproduced it.
- The relevant `keymap.conf` lines, if it is keymap-related.

Scrub anything private (tokens, internal hostnames, usernames embedded in paths) before sharing.

If you run a coding agent inside agterm (Claude Code or Codex with the agterm skill installed), it can help you write and file the report: it drafts an issue for a bug, or a Discussion for a feature request or question, shows it to you first, and never posts without your go-ahead.

Otherwise open one directly:

- Bug: <https://github.com/umputun/agterm/issues/new>
- Idea or question: <https://github.com/umputun/agterm/discussions/new>
