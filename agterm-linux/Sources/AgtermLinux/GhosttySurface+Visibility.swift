import CGtk

@MainActor
extension GhosttySurface {
    func installVisibilityTracking() {
        let data = Unmanaged.passUnretained(self).toOpaque()
        for signal in ["map", "unmap"] {
            connect(glArea, signal, unsafeBitCast(onSurfaceVisibilityChanged as @convention(c)
                (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), data)
        }
    }

    func syncRendererVisibility() {
        guard let surface else { return }
        let visible = gtk_widget_get_mapped(W(glArea)) != 0
        ghostty_surface_set_occlusion(surface, visible)
        if visible { ghostty_surface_refresh(surface) }
    }
}

private let onSurfaceVisibilityChanged: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    Unmanaged<GhosttySurface>.fromOpaque(data).takeUnretainedValue().syncRendererVisibility()
}
