import CGtk

/// Resolves the desktop accessibility preference without putting GTK types into the shared core.
/// GTK 4.22+ exposes the specific reduced-motion preference; older supported GTK versions only expose
/// the broader animation switch. Either request disables the decorative status-glyph pulse.
enum LinuxReduceMotionPolicy {
    static func prefersReducedMotion(
        interfaceReducedMotion: Bool?, animationsEnabled: Bool
    ) -> Bool {
        interfaceReducedMotion == true || !animationsEnabled
    }

    static func blinkCSS(prefersReducedMotion: Bool) -> String {
        if prefersReducedMotion {
            return ".agterm-blink { animation: none; }"
        }
        return ".agterm-blink { animation: agterm-blink-pulse 1.2s ease-in-out infinite; }"
    }
}

@MainActor
func linuxPrefersReducedMotion(_ settings: OpaquePointer?) -> Bool {
    guard let settings else { return false }

    var reducedMotion: gint = 0
    let hasReducedMotion = "gtk-interface-reduced-motion".withCString {
        agterm_object_get_enum_property(GOBJ(settings), $0, &reducedMotion) != 0
    }

    var animationsEnabled: gboolean = 1
    _ = "gtk-enable-animations".withCString {
        agterm_object_get_boolean_property(GOBJ(settings), $0, &animationsEnabled)
    }

    return LinuxReduceMotionPolicy.prefersReducedMotion(
        interfaceReducedMotion: hasReducedMotion ? reducedMotion == 1 : nil,
        animationsEnabled: animationsEnabled != 0)
}
