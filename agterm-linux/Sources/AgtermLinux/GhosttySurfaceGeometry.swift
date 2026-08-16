enum GhosttySurfaceGeometry {
    struct Size: Equatable {
        let width: UInt32
        let height: UInt32
    }

    struct Point: Equatable {
        let x: Double
        let y: Double
    }

    struct InitialSizeInputs {
        let gtkWidth: Int32
        let gtkHeight: Int32
        let scaleFactor: Int32
        let storedFallback: (width: Int32, height: Int32)?
        let deckFallback: (width: Int32, height: Int32)?
    }

    /// Size a surface is CREATED at: the widget's own allocation, else the stored frame estimate, else
    /// the deck allocation, else the historic clamp to one.
    ///
    /// A surface force-realized behind a hidden deck page reads `0x0` for itself because no layout pass
    /// has run yet. Both fallbacks use the same logical GTK units, so the content scale applies to
    /// whichever credible pair wins.
    static func initialBackingSize(
        gtkWidth: Int32,
        gtkHeight: Int32,
        scaleFactor: Int32,
        storedFallback: (width: Int32, height: Int32)?,
        deckFallback: (width: Int32, height: Int32)? = nil
    ) -> Size {
        let scale = UInt64(max(1, scaleFactor))
        return credibleSize((width: gtkWidth, height: gtkHeight), scale: scale)
            ?? credibleSize(storedFallback, scale: scale)
            ?? credibleSize(deckFallback, scale: scale)
            ?? Size(width: UInt32(clamping: scale), height: UInt32(clamping: scale))
    }

    /// The deterministic boundary used immediately after `ghostty_surface_new`: production supplies
    /// `ghostty_surface_set_size`, while tests supply a recorder and assert the exact initial dimensions.
    static func pushInitialSize(_ inputs: InitialSizeInputs, setSurfaceSize: (UInt32, UInt32) -> Void) {
        let viewport = initialBackingSize(
            gtkWidth: inputs.gtkWidth, gtkHeight: inputs.gtkHeight, scaleFactor: inputs.scaleFactor,
            storedFallback: inputs.storedFallback, deckFallback: inputs.deckFallback)
        setSurfaceSize(viewport.width, viewport.height)
    }

    /// The CHILD's usable box inside a chrome-bearing container: the size request minus the container's
    /// own measured chrome, per AXIS, keeping the RAW REQUEST for an unusable axis. Not in tension with
    /// `credibleSize`'s per-PAIR rule: this corrects ONE source in place, that one CHOOSES between two.
    static func contentSize(
        request: (width: Int32, height: Int32),
        chrome: (width: Int32, height: Int32)
    ) -> (width: Int32, height: Int32) {
        (width: contentExtent(request: request.width, chrome: chrome.width),
         height: contentExtent(request: request.height, chrome: chrome.height))
    }

    /// Both comparisons are ORDERED ahead of the subtraction, which is what keeps the function total:
    /// `Int32` arithmetic TRAPS, and `0 < chrome < request` leaves nothing to overflow. An
    /// untrustworthy measurement keeps the RAW REQUEST — a near-total subtraction would instead hand
    /// back a CREDIBLE tiny pair that `initialBackingSize` prefers over the deck fallback, the one-cell
    /// spawn this seam exists to prevent.
    private static func contentExtent(request: Int32, chrome: Int32) -> Int32 {
        guard chrome > 0, request > chrome else { return request }
        let content = request - chrome
        return content > chrome ? content : request
    }

    /// A size source counts only when BOTH dimensions are positive: taking one axis from the widget and
    /// the other from the fallback would produce a geometry neither source had — hence ONE optional pair.
    private static func credibleSize(_ size: (width: Int32, height: Int32)?, scale: UInt64) -> Size? {
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return Size(
            width: UInt32(clamping: UInt64(size.width) * scale),
            height: UInt32(clamping: UInt64(size.height) * scale)
        )
    }

    static func resizedViewport(widthPixels: Int32, heightPixels: Int32) -> Size {
        // GtkGLArea::resize reports the physical GL viewport, unlike gtk_widget_get_width/height.
        Size(width: UInt32(max(1, widthPixels)), height: UInt32(max(1, heightPixels)))
    }

    static func pointerPosition(gtkX: Double, gtkY: Double) -> Point {
        // The embedded libghostty API applies its content scale to pointer coordinates internally.
        Point(x: gtkX, y: gtkY)
    }
}
