import CGtk

@MainActor
private final class LinuxWidgetAction {
    let perform: @MainActor () -> Void
    init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
}

/// The button owns its callback until GObject disposal; the C signal never outlives its Swift context.
@MainActor
func connectAction(_ button: OpaquePointer, _ action: @escaping @MainActor () -> Void) {
    let context = LinuxWidgetAction(action)
    g_object_set_data_full(cast(button), "agterm-action", Unmanaged.passRetained(context).toOpaque(), releaseWidgetAction)
    connect(button, "clicked", unsafeBitCast(onWidgetAction as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
}

private let releaseWidgetAction: @convention(c) (gpointer?) -> Void = { data in
    if let data { Unmanaged<LinuxWidgetAction>.fromOpaque(data).release() }
}

private let onWidgetAction: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    guard let button, let data = g_object_get_data(cast(button), "agterm-action") else { return }
    Unmanaged<LinuxWidgetAction>.fromOpaque(data).takeUnretainedValue().perform()
}
