---
worth: yes
where: agterm-linux/Sources/AgtermLinux/AppControllerZoom.swift:74
added: 2026-08-31
---
# Linux terminal zoom blanks the surface permanently

`hostZoomedSurface` unparents `surface.rootWidget` into an `AdwToolbarView`. The unparent unrealizes the
`GtkGLArea` and GTK destroys its `GdkGLContext`; the re-add realizes a NEW one, but `GhosttySurface`
connects `realize` and no `unrealize`, and `realize()`'s `createSurface()` no-ops on an existing surface,
so libghostty keeps drawing into the destroyed context. `refresh()` cannot repair it, and zoom exit does
not recover: the session is dead on screen from the first zoom onward.

Measured with byte-identical numbers on three builds, including the tip predating the GtkPaned ref-guard
work, so it is not that work's doing. Isolated Xvfb instance, framebuffer captures: the
pane before zoom inks 0.4697; zoom show inks 0.4385, which is the zoom chrome alone, with an echo repaint
diff of exactly 0.0; zoom exit inks 0.4393 with the same 0.0 diff. The split arm behaves the same
(0.4385/0.0, then both panes 0.2926/0.3812 at 0.0). App stderr carries no `GTK_IS_`, assertion or GL
lines, and the shell stays alive — a live shell rendering into a dead context.

Two candidate fixes: a stable per-session zoom slot the surface never leaves, visibility only (the shape
`layoutSplit` uses for the paned slots), or an `unrealize` handler on `GhosttySurface` that tears the
libghostty surface down so the next `realize()` rebuilds it.

`dashboard-modal`, `hidden-toolbar` and `chrome-focus-buttons` assert AT-SPI structure and never pixels,
which is why it survived. `GhosttySurface.realize()` now logs `GLArea re-realized over a live surface`,
which is the cheap signal for this class; `split-primary-exit` asserts on it, and the runner-wide tripwire
is deliberately absent until this is fixed, since it would red every zoom scenario.
