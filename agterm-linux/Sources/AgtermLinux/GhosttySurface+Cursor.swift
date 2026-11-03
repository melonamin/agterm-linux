import CGtk

@MainActor
extension GhosttySurface {
    /// Zero-based cursor column, calibrated against the viewport's first cell so user-configured padding
    /// cancels out. Geometry is sampled again after the IME point to reject a concurrent resize/font change.
    func readCursorColumn() -> Int? {
        guard let surface else { return nil }
        var selection = ghostty_selection_s()
        let origin = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_EXACT,
            x: 0,
            y: 0
        )
        selection.top_left = origin
        selection.bottom_right = origin
        selection.rectangle = false
        var probe = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &probe) else { return nil }
        let columnZeroX = probe.tl_px_x
        ghostty_surface_free_text(surface, &probe)
        guard columnZeroX >= 0 else { return nil }

        let size = ghostty_surface_size(surface)
        let scale = Double(gtk_widget_get_scale_factor(W(glArea)))
        guard scale > 0, size.cell_width_px > 0, size.columns > 0 else { return nil }
        let cellWidth = Double(size.cell_width_px) / scale
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let after = ghostty_surface_size(surface)
        guard after.cell_width_px == size.cell_width_px, after.columns == size.columns else { return nil }
        let column = Int(((x - columnZeroX) / cellWidth).rounded(.down))
        guard column >= 0, column < Int(size.columns) else { return nil }
        return column
    }
}
