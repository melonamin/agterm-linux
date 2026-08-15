---
worth: later
where: agterm/Views/Palette.swift:386
added: 2026-08-09
---
# palette hover tint can strand on a row the pointer has left

`PaletteRow.hovering` is written only from `.onHover`, which fires on pointer transit. The palette's list
is not static: every keystroke re-runs `updateFiltered()` and every arrow key calls `proxy.scrollTo`, so
rows move under a stationary pointer without any hover event. The wash can then sit on a row the pointer
is no longer over, beside the real keyboard selection, on the surface whose whole job is type-and-Enter.
It self-heals on the next mouse move.

Accepted rather than solved when the hover went in (#408 / PR #414). Both fixes considered were worse than
the symptom: hoisting hover to `CommandPalette` so `updateFiltered()` can clear it repaints every row in
the lazy stack per mouse move, undoing the diffing boundary `PaletteRow` was split out for in #314; and
suppressing hover while a keyboard selection exists makes it vanish the moment an arrow key is touched.
VS Code and Raycast both behave this way too.

Nobody has reported hitting it. Dropped from `0.08` to `0.04` after review, which makes a stale wash much
less likely to read as a second selection. Worth revisiting only if it actually misleads in use, or if
SwiftUI grows a hover API that reports on content change rather than pointer transit.
