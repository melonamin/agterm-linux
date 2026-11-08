# File pages on Linux

Ctrl-click a local image, Markdown, HTML, source, configuration, text, or log path to open it over its session.
Paths under `/home`, relative paths against the pane's directory, and `path:line[:column]` locations are supported.
The literal filename wins when a file actually includes a colon or trailing punctuation.
Ctrl+Shift-click reveals a local file in the desktop file manager.
Remote-pane paths remain remote and are never read from the viewer's disk.

## Text, search, and changes

```sh
agtermctl session overlay open --text ./main.swift --line 42
agtermctl session overlay search 'func main'
agtermctl session overlay search --next
agtermctl session overlay search --close
agtermctl session overlay open --text ./review.diff
agtermctl session overlay changes --next
agtermctl session overlay changes --prev
```

Text pages use the upstream bundled renderer for line numbers, syntax highlighting, and diff change navigation.
Diff files color each file's code in its own language over the added and removed row bands.
The find box, `/`, Ctrl+F, Return/Shift+Return, and `n`/`N` operate on the visible text page.
Diff pages expose previous/next buttons and `[`/`]` shortcuts.
Control readback is `htmlOverlays[].text`, including the source, language, target line, search, and changes.
Files must be regular, valid UTF-8, contain no NUL, and fit the 4 MiB whole-file cap.
Files over 256 KiB remain readable without syntax highlighting.

## Following logs

```sh
agtermctl session overlay open --text ./server.log --tail 5000 --follow-file
agtermctl session overlay follow off
agtermctl session overlay follow on
```

A plain `.log` or `.out` click follows the file; a click with a line location opens a static page.
The reader takes at most 2 MiB from the end and keeps the requested tail.
Rotation, truncation, removal, recreation, and a temporarily binary tail are reported in the text node.
Scrolling up pauses following; `F` toggles it, `G`/End goes to the bottom, and `g`/Home to the top.
The follower uses one GLib timer only while following and visible.
Closing a page cancels its timer and invalidates reads still in flight.

## Content and remote presentation

Generated image, Markdown, text, and clicked HTML pages have no control bridge or file grant.
The app's renderer runs in an isolated WebKit script world; authored scripts and network resources are blocked.
Markdown embeds only bounded, validated pictures allowed by the origin's folder grant.
Clicked HTML uses the upstream inert-document policy.
The explicit `--html` command retains the existing HTML page API; upstream adds no separate document flag.

Image, Markdown, text, and HTML documents opened on a session presented by another instance travel through its page channel.
The origin validates every resource before sending it, and the viewer renders bounded bytes instead of reading the origin path locally.
Remote text pages are static: log following and control-driven search are refused rather than silently changed.

## Renderer boundary

Ghostty v1.4.0 uses Zig 0.17.0; the bundled zmx pin independently uses Zig 0.16.0.
The Linux embedded adapter keeps OpenGL creation, drawing, viewport ownership, and destruction on GTK's thread.
Render-thread work requests a host draw and never calls through GTK's thread-local OpenGL table.
Hidden panes retain GPU resources, preserving the Linux bridge's existing context-lifetime contract.
Upstream's native EGL frame export and macOS display-link lifecycle do not replace the GTK embedded interface.
