---
worth: yes
where: agterm-linux/tests/atspi_smoke.py:512
added: 2026-09-04
---
# AT-SPI pointer helpers apply the CSD frame inset to buttons only

`mouse_click` subtracts the frame's negative WINDOW origin for `PUSH_BUTTON` accessibles alone, on the
observation that rows and labels already report outer-window coordinates. On a Manjaro host under the
Xvfb/Openbox runner they do not: rows report WINDOW y 85/116/147 and their labels 89/120/151 (31px
pitch) against a frame whose own WINDOW origin is about -16,-16, while a screenshot puts the pixels
~16px lower; the computed click for row three, xdotool origin (170,100) + label (94,151) + 10 = screen
(264,261), lands on the bottom edge of row two. The
drag (`:613`) and press-hold (`:741`) paths add `origin + local` with no inset at all. Scenarios survive
through `calibrate_row_click`'s `dy` sweep, which is why the debt first became fatal in
`sidebar-incremental`: a miss there opens the row above's context menu, and every later probe lands on
that popover.

Fix is one shared X11 conversion for click, drag and press-hold — resolve the target's frame, subtract
its WINDOW origin, add the active X window origin — with `dy` kept as a residual fallback. Normalizing
`mouse_click` alone would zero `row_dy` while the other two paths still expect it. Verify against label,
list item, entry, button and frame targets, and run all 34 scenarios; the Wayland path is unaffected.
