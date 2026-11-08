"""Read pixels from the UI runner's private X display without changing focus."""

import ctypes
import os
import subprocess

import gi

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, GLib  # noqa: E402


class XImage(ctypes.Structure):
    _fields_ = [
        ("width", ctypes.c_int), ("height", ctypes.c_int),
        ("xoffset", ctypes.c_int), ("format", ctypes.c_int),
        ("data", ctypes.c_void_p), ("byte_order", ctypes.c_int),
        ("bitmap_unit", ctypes.c_int), ("bitmap_bit_order", ctypes.c_int),
        ("bitmap_pad", ctypes.c_int), ("depth", ctypes.c_int),
        ("bytes_per_line", ctypes.c_int), ("bits_per_pixel", ctypes.c_int),
        ("red_mask", ctypes.c_ulong), ("green_mask", ctypes.c_ulong),
        ("blue_mask", ctypes.c_ulong),
    ]


def capture(path=None):
    """Return a packed RGB pixbuf of the Xvfb root, optionally saving a PNG."""
    display_name = os.environ.get("DISPLAY")
    if not display_name:
        raise RuntimeError("Visual checks require an explicit private DISPLAY")
    width, height = map(int, subprocess.check_output(
        ["xdotool", "getdisplaygeometry"], text=True).split())
    xlib = ctypes.CDLL("libX11.so.6")
    xlib.XOpenDisplay.argtypes = [ctypes.c_char_p]
    xlib.XOpenDisplay.restype = ctypes.c_void_p
    xlib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    xlib.XDefaultRootWindow.restype = ctypes.c_ulong
    xlib.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int,
                              ctypes.c_int, ctypes.c_uint, ctypes.c_uint,
                              ctypes.c_ulong, ctypes.c_int]
    xlib.XGetImage.restype = ctypes.POINTER(XImage)
    xlib.XDestroyImage.argtypes = [ctypes.POINTER(XImage)]
    xlib.XCloseDisplay.argtypes = [ctypes.c_void_p]
    display = xlib.XOpenDisplay(display_name.encode())
    if not display:
        raise RuntimeError(f"Cannot open private display {display_name}")
    image = None
    try:
        image = xlib.XGetImage(display, xlib.XDefaultRootWindow(display), 0, 0,
                              width, height, ctypes.c_ulong(-1).value, 2)
        if not image:
            raise RuntimeError("XGetImage failed")
        info = image.contents
        if (info.bits_per_pixel, info.byte_order, info.red_mask,
                info.green_mask, info.blue_mask) != (32, 0, 0xFF0000, 0xFF00, 0xFF):
            raise RuntimeError("Visual checks require the runner's 24-bit Xvfb screen")
        raw = ctypes.string_at(info.data, info.bytes_per_line * height)
        rgb = bytearray(width * height * 3)
        for y in range(height):
            row = raw[y * info.bytes_per_line:y * info.bytes_per_line + width * 4]
            start = y * width * 3
            rgb[start:start + width * 3:3] = row[2::4]
            rgb[start + 1:start + width * 3:3] = row[1::4]
            rgb[start + 2:start + width * 3:3] = row[0::4]
        pixbuf = GdkPixbuf.Pixbuf.new_from_bytes(
            GLib.Bytes.new(bytes(rgb)), GdkPixbuf.Colorspace.RGB, False,
            8, width, height, width * 3)
        if path:
            pixbuf.savev(str(path), "png", [], [])
        return pixbuf
    finally:
        if image:
            xlib.XDestroyImage(image)
        xlib.XCloseDisplay(display)
