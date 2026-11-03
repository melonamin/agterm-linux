# Linux visual validation

Build the app and CLI, then run the native GTK suite:

```sh
cd agterm-linux && swift build
cd ..
scripts/test-linux-ui.sh
```

The runner uses the host GTK, libadwaita, WebKitGTK, and libghostty.
It creates a private Xvfb display and D-Bus session with disposable HOME, state, and sockets.
Keyboard and pointer events stay on that display.
It does not use a VM or activate the user's desktop windows.
Desktop URI handlers resolve to a disposable GIO fixture, so browser and keyring windows cannot take test input.
The child-environment scenario installs its own handler to verify desktop dispatch separately.

The suite first decodes every bundled symbolic SVG.
Missing SVG loader support fails before the app starts.
Ubuntu and Debian require `librsvg2-common` at runtime.

The visual regressions complement the accessibility and control assertions:

| Scenario | Rendered behavior checked |
| --- | --- |
| `ask-visual` | Opaque forms over contrasting real HTML pages; centered and bounded long messages; wrapped choices; editable answers; pane widths above ordinary terminals and session covers |
| `overlay-visual` | Floating HTML and program overlays actually disappear and return after Hide/Show, for percentage and point dimensions; hidden processes retain their content |
| `palette-lifecycle` | A palette opened by an action retains search and Escape handling after its predecessor is destroyed; resource metadata is excluded from theme choices |
| `companion-layout` | Parent/peer alignment, nested companion indentation, stable row heights, working disclosure buttons, and unindented flagged layouts at normal and large sidebar fonts |
| `ibus-lifecycle` | A private real IBus daemon, four focused-workspace deletions through the confirmation dialog, and keyboard input after the removed clients are gone; requires IBus's GTK4 module |
| `companion-identity` | Real programs duplicated through both the GUI and socket use the copy's session/pane IDs in their environment and explicit arguments |
| `upstream-v0391` | Companion/tint menus, forms, overlay controls, and real modifier clicks on HUD links across split panes |

Capture artifacts and app stderr are written to `artifacts/linux-ui/` by default.
Set `AGTERM_UI_ARTIFACT_DIR` to preserve them elsewhere.
For a focused run, set `AGTERM_ATSPI_SCENARIO` to one of the scenario names above.
The standard suite fixes its display scale at 1 to keep pointer coordinates consistent across hosts.

Before visual acceptance, also inspect light and dark themes at normal and doubled scale, a small window,
large interface fonts, the toolbar modes, sidebar and status states, palettes and popovers, all Preferences pages,
split/swap/zoom, scratch and quick terminals, dashboard, backgrounds, overlays, native file dialogs, and About.
Inspect actual screenshots: a successful control response or an accessible widget does not prove that it is visible.

Xvfb uses software rendering and does not exercise a Wayland compositor's window placement, desktop notification
appearance, GPU driver, global shortcuts, physical suspend/resume, or network transitions.
Keep those limitations separate from verified GTK behavior.
