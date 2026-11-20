#!/usr/bin/env python3
"""Reject a GTK runtime that finds symbolic icons but cannot decode their SVG files."""

import pathlib
import sys

import gi

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, GLib  # noqa: E402

icons = sorted(pathlib.Path(sys.argv[1]).rglob("*-symbolic.svg"))
if not icons:
    raise SystemExit("No bundled symbolic icons found")
for icon in icons:
    try:
        image = GdkPixbuf.Pixbuf.new_from_file(str(icon))
    except GLib.Error as error:
        raise SystemExit(
            "SVG icon decoding failed; install the platform SVG loader "
            f"(Ubuntu/Debian: librsvg2-common): {error}"
        ) from error
    if image.get_width() <= 0 or image.get_height() <= 0:
        raise SystemExit(f"SVG icon has no drawable pixels: {icon}")
print(f"OK: decoded all {len(icons)} bundled symbolic SVG icons")
