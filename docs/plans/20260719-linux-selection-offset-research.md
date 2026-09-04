# Linux terminal selection offset research

## Outcome

The Linux selection offset was caused by scaling GTK pointer coordinates twice at the embedded libghostty
C API boundary.
GTK event controllers report positions in widget coordinates.
The Linux port multiplied those positions by the GTK scale factor before calling
`ghostty_surface_mouse_pos`, but the embedded implementation applies its stored content scale internally.
At 2x scale, a pointer halfway down the widget was therefore reported at the bottom of libghostty's grid,
placing the selection well below the cursor.

Surface sizes use a different contract.
`gtk_widget_get_width/height` are logical widget dimensions and need conversion to backing pixels during
surface creation, while `GtkGLArea::resize` already reports the physical GL viewport and must pass through.
Scaling the resize callback again makes the PTY larger than the visible terminal, leaving its prompt in
unreachable rows rather than scrollback.

## Evidence

- The reported environment is Wayland on a 5120x2880 monitor with `GDK_SCALE=2`.
- GTK event controllers and gestures report positions in the attached widget's coordinate system.
  GTK also documents widget allocation sizes as widget units rather than device pixels.
  See [GTK coordinate systems](https://docs.gtk.org/gtk4/coordinates.html).
- `GtkGLArea::resize` reports viewport width and height and fires once on realization and after realized-size
  changes.
  See [`Gtk.GLArea::resize`](https://docs.gtk.org/gtk4/signal.GLArea.resize.html).
- GTK's `GtkGLArea` implementation allocates its framebuffer as `widget width/height * scale`, then emits
  those backing-pixel values through `resize` and uses them for `glViewport`.
  See GTK's [`gtkglarea.c`](https://gitlab.gnome.org/GNOME/gtk/-/blob/main/gtk/gtkglarea.c).
- The pinned Ghostty GTK frontend calls the core directly, so it scales pointer positions before that call.
  See Ghostty's pinned [`surface.zig`](https://github.com/ghostty-org/ghostty/blob/4dcb09ada0c0909717d92547623b26eafa50ca8a/src/apprt/gtk/class/surface.zig).
- The embedded C API adds another adapter layer: its `cursorPosCallback` explicitly converts unscaled host
  coordinates to pixels using the content scale.
  See Ghostty's pinned [`embedded.zig`](https://github.com/ghostty-org/ghostty/blob/4dcb09ada0c0909717d92547623b26eafa50ca8a/src/apprt/embedded.zig).
- Upstream's embedded macOS host follows this contract: it sends logical view coordinates to
  `ghostty_surface_mouse_pos` and backing dimensions to `ghostty_surface_set_size`.

## Implemented fix

Keep each boundary in the units expected by the embedded API:

1. Pass GTK motion and click coordinates through unchanged; embedded libghostty scales them internally.
2. Convert the initial logical widget allocation to backing pixels with the GTK scale factor.
3. Pass `GtkGLArea::resize` viewport pixels through without applying the scale again.
4. Keep `ghostty_surface_set_content_scale` unchanged for libghostty's DPI and coordinate conversion.

## Regression coverage and verification

- `GhosttySurfaceGeometryTests` pins all three contracts: initial scale 1/2 backing conversion,
  resize-viewport pass-through, and unscaled pointer positions.
- An isolated Wayland instance with `GDK_SCALE=2`, separate state, a separate control socket, and a unique
  application ID confirmed selection stays under the cursor before resize.
- The same hands-on run confirmed long output can scroll back to the prompt after the resize-unit correction.
- Shared core behavior and the control API are unchanged; this is Linux GTK/libghostty adapter work only.
