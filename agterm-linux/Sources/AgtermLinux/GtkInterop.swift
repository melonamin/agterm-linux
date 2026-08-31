// Low-level GTK4 C-interop helpers. GTK's GObject types import into Swift as
// distinct typed pointers; these reinterpret a stored OpaquePointer to the type
// a given GTK function expects (GObject pointers are layout-compatible).
import CGtk
import agtermCore

// GTK, GApplication, and GLib source callbacks are declared `@MainActor @convention(c)` at their
// definitions. The C APIs cannot express executor isolation, but these callbacks are synchronously
// delivered by the application-owned main context. Libghostty callbacks are intentionally excluded:
// they may arrive on worker threads and must copy/retain their payload before hopping to the main actor.

@inline(__always) func W(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkWidget>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func GLBR(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkListBoxRow>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func GLA(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkGLArea>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func WIN(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkWindow>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func APPW(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkApplication>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func ADWAPP(_ p: OpaquePointer?) -> UnsafeMutablePointer<AdwApplication>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func GAPP(_ p: OpaquePointer?) -> UnsafeMutablePointer<GApplication>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func GOBJ(_ p: OpaquePointer?) -> UnsafeMutablePointer<GObject>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func POPOVER(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkPopover>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func BUTTON(_ p: OpaquePointer?) -> UnsafeMutablePointer<GtkButton>? { p.map { UnsafeMutablePointer($0) } }
@inline(__always) func RAW(_ p: OpaquePointer?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }

/// Normalize a GTK constructor result (which inconsistently imports as optional or
/// non-optional `UnsafeMutablePointer<GtkWidget>`) to the `OpaquePointer?` we store.
@inline(__always) func op(_ p: UnsafeMutablePointer<GtkWidget>?) -> OpaquePointer? { p.map { OpaquePointer($0) } }

/// GTK4 parents own the sole reference to a sunk child: detaching one without a held
/// reference frees it, and re-adding it links freed memory into the tree.
func withWidgetRefHeld<T>(_ widget: OpaquePointer, _ body: () throws -> T) rethrows -> T {
    _ = g_object_ref(RAW(widget))
    defer { g_object_unref(RAW(widget)) }
    return try body()
}

/// Connect a GObject signal, passing `data` to the handler's trailing argument.
/// `handler` is a non-capturing `@convention(c)` function cast to `GCallback`.
func connect(_ instance: OpaquePointer?, _ signal: String, _ handler: GCallback?, _ data: UnsafeMutableRawPointer? = nil) {
    signal.withCString { _ = g_signal_connect_data(RAW(instance), $0, handler, data, nil, GConnectFlags(rawValue: 0)) }
}

/// Open a URI with the desktop's default handler — the single seam for every such launch in the app.
/// The context exists only to carry the GDK child-environment restore: with a NULL `GAppLaunchContext`
/// GIO spawns the handler from agterm's own environ, handing a GTK browser or editor agterm's renderer
/// constraints. A plain context (not `gdk_display_get_app_launch_context`) keeps the launch behaviour
/// identical to the NULL call, plus the overrides.
func launchDefaultHandler(forURI uri: String) {
    guard !gdkEnvironment.childRestore.isEmpty, let context = g_app_launch_context_new() else {
        uri.withCString { _ = g_app_info_launch_default_for_uri($0, nil, nil) }
        return
    }
    for (name, value) in gdkEnvironment.childRestore {
        name.withCString { cName in
            value.withCString { cValue in g_app_launch_context_setenv(context, cName, cValue) }
        }
    }
    uri.withCString { _ = g_app_info_launch_default_for_uri($0, context, nil) }
    g_object_unref(context)
}

// GDK modifier bit masks (GdkModifierType).
private let GDK_SHIFT: UInt32 = 1 << 0
private let GDK_CONTROL: UInt32 = 1 << 2
private let GDK_ALT: UInt32 = 1 << 3
private let GDK_SUPER: UInt32 = 1 << 26

/// Apply upstream agterm's per-layout shortcut policy to Linux XKB keycodes: ASCII-capable layouts
/// keep their produced base character; every key on a non-ASCII layout resolves by physical position.
func linuxShortcutKey(keycode: UInt32, produced: String?, layoutIsASCIICapable: Bool) -> String? {
    let base = produced?.first.map { String($0).lowercased() }.flatMap { $0 == " " ? nil : $0 }
    guard !layoutIsASCIICapable else { return base }
    if let physical = linuxLatinKey(forKeycode: keycode) { return physical }
    return keycode == 94 ? nil : base
}

private func linuxLatinKey(forKeycode keycode: UInt32) -> String? {
    switch keycode {
    case 24: return "q"
    case 25: return "w"
    case 26: return "e"
    case 27: return "r"
    case 28: return "t"
    case 29: return "y"
    case 30: return "u"
    case 31: return "i"
    case 32: return "o"
    case 33: return "p"
    case 34: return "["
    case 35: return "]"
    case 38: return "a"
    case 39: return "s"
    case 40: return "d"
    case 41: return "f"
    case 42: return "g"
    case 43: return "h"
    case 44: return "j"
    case 45: return "k"
    case 46: return "l"
    case 47: return ";"
    case 48: return "'"
    case 49: return "`"
    case 51: return "\\"
    case 52: return "z"
    case 53: return "x"
    case 54: return "c"
    case 55: return "v"
    case 56: return "b"
    case 57: return "n"
    case 58: return "m"
    case 59: return ","
    case 60: return "."
    case 61: return "/"
    case 10: return "1"
    case 11: return "2"
    case 12: return "3"
    case 13: return "4"
    case 14: return "5"
    case 15: return "6"
    case 16: return "7"
    case 17: return "8"
    case 18: return "9"
    case 19: return "0"
    case 20: return "-"
    case 21: return "="
    default: return nil
    }
}

struct ShortcutKeyMapEntry: Equatable {
    let group: Int
    let level: Int
    let keyval: UInt32
}

struct ShortcutKeyContext: Equatable {
    let activeGroup: Int
    let layoutIsASCIICapable: Bool
    let entries: [ShortcutKeyMapEntry]
}

func shortcutKeyContext(event: OpaquePointer?, keycode: UInt32) -> ShortcutKeyContext? {
    guard let event, let display = gdk_event_get_display(event) else { return nil }
    let activeGroup = Int(gdk_key_event_get_layout(event))
    guard let entries = shortcutKeyMapEntries(display: display, keycode: keycode) else { return nil }
    return ShortcutKeyContext(
        activeGroup: activeGroup,
        layoutIsASCIICapable: isASCIICapableShortcutLayout(activeGroup: activeGroup) {
            shortcutKeyMapEntries(display: display, keycode: $0) ?? []
        },
        entries: entries
    )
}

private func shortcutKeyMapEntries(
    display: OpaquePointer, keycode: UInt32
) -> [ShortcutKeyMapEntry]? {
    var keys: UnsafeMutablePointer<GdkKeymapKey>?
    var keyvals: UnsafeMutablePointer<UInt32>?
    var count: Int32 = 0
    let mapped = gdk_display_map_keycode(display, keycode, &keys, &keyvals, &count)
    defer {
        if let keys { g_free(keys) }
        if let keyvals { g_free(keyvals) }
    }
    guard mapped != 0, let keys, let keyvals, count > 0 else { return nil }

    return (0..<Int(count)).map { index in
        ShortcutKeyMapEntry(
            group: Int(keys[index].group),
            level: Int(keys[index].level),
            keyval: keyvals[index]
        )
    }
}

private let linuxANSIKeycodes: [UInt32] = Array(10...21) + Array(24...35) + Array(38...49) + [51] + Array(52...61)

func isASCIICapableShortcutLayout(
    activeGroup: Int,
    entriesForKeycode: (UInt32) -> [ShortcutKeyMapEntry]
) -> Bool {
    let keyvals = linuxANSIKeycodes.flatMap(entriesForKeycode)
        .filter { $0.group == activeGroup && $0.level == 0 }
        .map(\.keyval)
    let letters = Set(keyvals.compactMap { keyval -> UInt32? in
        let scalar = gdk_keyval_to_unicode(gdk_keyval_to_lower(keyval))
        return scalar >= 0x61 && scalar <= 0x7A ? scalar : nil
    })
    return letters.count == 26
}

func needsShortcutKeyContext(state: UInt32, leaderArmed: Bool) -> Bool {
    leaderArmed || state & (GDK_SHIFT | GDK_CONTROL | GDK_ALT | GDK_SUPER) != 0
}

/// Translate a GdkModifierType bitfield to ghostty's modifier flags.
func ghosttyMods(_ state: UInt32) -> ghostty_input_mods_e {
    var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if state & GDK_SHIFT != 0 { m |= GHOSTTY_MODS_SHIFT.rawValue }
    if state & GDK_CONTROL != 0 { m |= GHOSTTY_MODS_CTRL.rawValue }
    if state & GDK_ALT != 0 { m |= GHOSTTY_MODS_ALT.rawValue }
    if state & GDK_SUPER != 0 { m |= GHOSTTY_MODS_SUPER.rawValue }
    return ghostty_input_mods_e(rawValue: m)
}

/// Translate a GTK key press (`keyval` + `GdkModifierType state`) into the shared, host-free
/// `agtermCore.Chord` the keymap matcher consumes — or `nil` when the press is not a bindable base key
/// (a bare modifier, Escape, or an unsupported function/navigation key), so the caller can run its
/// fixed page-key fallback or pass the key through to libghostty.
///
/// Mirrors the macOS `NSEvent -> Chord` contract: the base is the unshifted layout character when the
/// layout can type the complete ASCII alphabet, otherwise the physical ANSI-position key. The modifier
/// set is exact because the matcher compares `mods` by `OptionSet` equality.
func shortcutChord(
    fromKeyval keyval: UInt32,
    keycode: UInt32,
    state: UInt32,
    context: @autoclosure () -> ShortcutKeyContext?
) -> Chord? {
    let mods = shortcutModifiers(state)
    if let named = namedShortcutChord(fromKeyval: keyval, mods: mods) {
        return named
    }
    if keyval == 0xFF1B { return nil }

    let legacyKeyval = legacyBaseKeyval(keyval, shifted: mods.contains(.shift))
    guard shortcutKeyString(for: legacyKeyval) != nil else { return nil }
    let keyContext = context()
    let producedKeyval = keyContext.flatMap {
        uniqueBaseKeyval(in: $0.activeGroup, entries: $0.entries)
    } ?? legacyKeyval
    let produced = shortcutKeyString(for: producedKeyval)
    guard let key = linuxShortcutKey(
        keycode: keycode,
        produced: produced,
        layoutIsASCIICapable: keyContext?.layoutIsASCIICapable ?? true
    ) else { return nil }
    return Chord(mods: mods, key: key)
}

private func shortcutModifiers(_ state: UInt32) -> Modifier {
    var mods: Modifier = []
    if state & GDK_CONTROL != 0 { mods.insert(.control) }
    if state & GDK_SHIFT != 0 { mods.insert(.shift) }
    if state & GDK_ALT != 0 { mods.insert(.option) }
    if state & GDK_SUPER != 0 { mods.insert(.command) }
    return mods
}

private func namedShortcutChord(fromKeyval keyval: UInt32, mods: Modifier) -> Chord? {
    switch keyval {
    case 0xFE20, 0xFF09, 0xFF89: return Chord(mods: mods, key: "tab")
    case 0x20, 0xFF80: return Chord(mods: mods, key: "space")
    case 0xFF0D, 0xFF8D: return Chord(mods: mods, key: "return")
    case 0xFF08, 0xFFFF: return Chord(mods: mods, key: "delete")
    case 0xFF51: return Chord(mods: mods, key: "left")
    case 0xFF52: return Chord(mods: mods, key: "up")
    case 0xFF53: return Chord(mods: mods, key: "right")
    case 0xFF54: return Chord(mods: mods, key: "down")
    default: return nil
    }
}

private func legacyBaseKeyval(_ keyval: UInt32, shifted: Bool) -> UInt32 {
    // GDK reports the shifted symbol as the keyval. Fold the common keyboard pairs back to their base
    // key so `shift+/`, `shift+=`, and `shift+5` match the same keymap vocabulary as macOS.
    if shifted {
        return [
            0x21: 0x31, 0x40: 0x32, 0x23: 0x33, 0x24: 0x34, 0x25: 0x35,
            0x5E: 0x36, 0x26: 0x37, 0x2A: 0x38, 0x28: 0x39, 0x29: 0x30,
            0x5F: 0x2D, 0x2B: 0x3D, 0x7B: 0x5B, 0x7D: 0x5D, 0x7C: 0x5C,
            0x3A: 0x3B, 0x22: 0x27, 0x3C: 0x2C, 0x3E: 0x2E, 0x3F: 0x2F,
            0x7E: 0x60,
        ][keyval] ?? keyval
    }
    return keyval
}

private func shortcutKeyString(for keyval: UInt32) -> String? {
    let u = gdk_keyval_to_unicode(gdk_keyval_to_lower(keyval))
    guard u >= 0x20, u != 0x7F, let scalar = Unicode.Scalar(u) else { return nil }
    let key = String(scalar).lowercased()
    guard key.count == 1, key != " " else { return nil }
    return key
}

private func uniqueBaseKeyval(in group: Int, entries: [ShortcutKeyMapEntry]) -> UInt32? {
    let bases = Set(entries.lazy.filter { $0.group == group && $0.level == 0 }.map(\.keyval))
    return bases.count == 1 ? bases.first : nil
}
