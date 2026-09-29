# X11 / Wayland support matrix

`agterm-linux` is a GTK4 / libadwaita app, so GDK abstracts the display backend. It runs on **both**
Wayland (the native, preferred backend) and X11 (via XWayland or a native X server). GDK auto-selects
Wayland on a Wayland session; force X11 with `GDK_BACKEND=x11 agterm-linux`.

## Matrix

| Behavior | Wayland | X11 | Notes |
|---|:---:|:---:|---|
| Window + chrome (CSD header/footer) | ✅ | ✅ | GTK4 client-side decorations with a full-height native resizable sidebar divider; Hyprland omits client-side window buttons and leaves those actions to compositor bindings |
| GL terminal rendering (GtkGLArea + libghostty) | ✅ | ✅ | **verified** — typed output (`echo X11RENDERTEST`) renders on both; no GL-context errors, but on GTK ≥ 4.16 only because the app sets `GDK_DISABLE=gles-api,vulkan` before GTK initializes — see the GL delta below |
| Control channel (`agtermctl` over the unix socket) | ✅ | ✅ | backend-independent — **verified** (`session.new` / `session.type` reflect on screen under both) |
| Primary selection (copy-on-select, middle-click paste) | ✅ | ✅ | GTK abstracts `wl_primary_selection` (Wayland) / `PRIMARY` (X11); copy-on-select drives the same `ghostty` path on both |
| IME (compose / dead-keys / CJK) | ✅ | ✅ | `GtkIMMulticontext` → the Wayland `text-input` protocol or X11 XIM/ibus — verified on Wayland; X11 routes through the same `imContext` |
| HiDPI scaling | ✅ | ✅ | `gtk_widget_get_scale_factor` (Wayland fractional / X11 `Xft.dpi`); the surface is built at the device scale on both |
| Background translucency | ✅ | ✅ | the app makes the window node transparent + ghostty renders `background-opacity`; the **compositor composites** it on both |
| Background **blur** | compositor | compositor | NOT app-controllable on either — Hyprland (Wayland) / a compositing WM like picom (X11) blurs translucent windows if configured |

## Known deltas

- **GL context creation is an EGL problem, not a Wayland one** (GTK ≥ 4.16; observed on 4.22.4).
  On EGL, GDK builds its own paint context with the GLES API (`Creating EGL context version 3.0 … es:yes`),
  and libghostty's desktop-GL-only renderer then cannot realize the `GtkGLArea`'s sibling context — both
  desktop-GL attempts fail and every surface shows "failed to create a GL context".
  Switching backend does NOT avoid this: under `GDK_BACKEND=x11` (XWayland) GTK 4.22 still selects EGL,
  still builds a GLES paint context, and fails identically.
  Only forcing the GLX path (`GDK_BACKEND=x11 GDK_DISABLE=egl`) sidesteps it, because GLX has no
  GLES-preference path — so the honest statement is "fails on EGL, on both the Wayland and the X11 backend;
  works on GLX", not "fails on Wayland, works on X11".
  The app fixes it for every backend by disabling GDK's GLES API before GTK initializes (`LinuxGdkPolicy`,
  applied as the first statements of `main()`: `GDK_DISABLE=gles-api,vulkan` on GTK ≥ 4.16,
  `GDK_DEBUG=gl-disable-gles,vulkan-disable` on 4.14–4.15), which is what upstream ghostty's `setGtkEnv()`
  does as well.
  `vulkan` is in that pair for a second, independent reason and must not be trimmed as a startup-time
  nicety: GTK's Vulkan GSK renderer cannot import the desktop-GL GLArea texture and falls back to a
  per-frame CPU readback of the window that is retained forever — measured at ~400 MB/s under a sustained
  output flood, against flat RSS with the full pair set.
- **Wayland is preferred** (native; no XWayland translation layer). X11 runs through XWayland on a
  Wayland session, which is a compatibility path — fine for everyday use but a layer of indirection.
- **Blur is the compositor's job on both** — there is no app-controllable blur protocol on Wayland, and
  on X11 it depends on a compositing window manager. The app only requests translucency.
- **Window decorations**: GTK4 uses CSD on both. Under Hyprland the header and footer remain, but their
  close/minimize/maximize buttons are omitted to follow the compositor's window-management convention.
  A tiling WM that forces SSD on X11 may draw its own title bar around the CSD.

## Verified

Launch + render (chrome + GL terminal), a control-channel mutation reflecting on screen, zero GL-context
errors, and zero crashes — under both the Wayland backend and `GDK_BACKEND=x11`.

That zero-GL-context-errors claim is unconditional only up to GTK 4.15.
On GTK ≥ 4.16 it holds because the app disables GDK's GLES API itself: re-verified on GTK 4.22.4 with the
`GDK_DISABLE=gles-api,vulkan` assignment in place, every GL context in the process is desktop GL (`es:no`)
reporting GL 4.6 core / GLSL 4.60, GSK falls back from Vulkan to `GskGLRenderer`, and RSS holds flat under a
sustained output flood.
Without the assignment, the same GTK 4.22.4 fails on BOTH backends, since both resolve to EGL (see the GL
delta above).
