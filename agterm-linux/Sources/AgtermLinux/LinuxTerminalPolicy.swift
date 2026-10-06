enum GhosttyDefaults {
    /// Bundled libghostty defaults for the Linux port — semantic parity with
    /// `agterm/Resources/ghostty-defaults.conf`, adapted to Linux conventions
    /// (Ctrl+Shift instead of Cmd, since bare Ctrl+C is SIGINT). Loaded first by
    /// `GhosttyApp.writeDefaultsConf()` (after the dynamic `term = …` line), so
    /// the user's `<configDir>/ghostty.conf` still overrides every key — the same
    /// 4-layer config stack macOS uses (bundled → global → scoped → settings).
    static let baseConfLines = """
    # widen libghostty's default 2px inner padding to 8px horizontally and 6px
    # vertically, matching upstream macOS. on Linux the GtkGLArea carries no
    # margin of its own (see GhosttySurface), so libghostty's inner padding is
    # the only one applied to the terminal content.
    window-padding-x = 8
    window-padding-y = 6

    # keep the cursor a steady block everywhere. the shell-integration `cursor`
    # feature otherwise flips it to a bar at the prompt and back to a block
    # while a command runs, which reads as an inconsistent cursor; no-cursor
    # stops the shell from emitting the shape-change escapes so it stays at the
    # block default. no-title stops ghostty's shell integration from
    # auto-setting the terminal title to the abbreviated cwd on every prompt
    # (the `…/a/b/c` path), which would always override the sidebar's
    # cwd-basename name. OSC 7 (cwd reporting) and OSC 133 (prompt detection)
    # are separate shell-integration features and remain enabled — only
    # `cursor` and `title` are disabled.
    cursor-style = block
    shell-integration-features = no-cursor,no-title

    # disable ghostty's click-to-move-cursor at the shell prompt. with shell
    # integration (OSC 133) a click in the prompt input emits arrow keys to
    # move the shell cursor to the clicked column, but a double-click to SELECT
    # a word (e.g. a branch name shown in the prompt) fires it too, jerking the
    # cursor to the start of the line so a following paste lands in the wrong
    # place. this governs only the shell-prompt click; a TUI's own mouse
    # reporting (vim/htop/etc.) is a separate path and is unaffected.
    cursor-click-to-move = false

    # Linux uses Ctrl+Shift (not Cmd) for terminal copy/paste/select-all:
    # bare Ctrl+C is SIGINT, so the platform convention is Ctrl+Shift+C/V/A —
    # the same default libghostty ships, but expressed as physical-key
    # (`key_c`/`key_v`/`key_a`) triggers that match by keycode (the physical
    # position) regardless of the produced character. this mirrors the upstream
    # macOS bundled defaults that use `super+key_*` for the same reason: a
    # bare-letter bind matches the produced character and stops firing the
    # moment the active layout types a non-Latin glyph (Cyrillic `с`, Greek
    # `σ`, Hebrew `ו`, etc.). the physical-key form works on any layout, so
    # copy/paste/select-all keep working on Russian, Greek, Hebrew, Arabic,
    # and Thai without a user-side `ghostty.conf` override. `performable:`
    # keeps ghostty's default fall-through — Ctrl+Shift+C does nothing when
    # there is no selection (so ^C SIGINT still works in that case), and a
    # Dvorak/Colemak user who wants their own letter positions can re-bind
    # these in `<configDir>/ghostty.conf` since that file loads after the
    # bundled defaults.
    keybind = performable:ctrl+shift+key_c=copy_to_clipboard
    keybind = performable:ctrl+shift+key_v=paste_from_clipboard
    keybind = performable:ctrl+shift+key_a=select_all

    """
}
