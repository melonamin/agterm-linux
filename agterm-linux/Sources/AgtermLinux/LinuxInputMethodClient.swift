import CGtk

/// The surface's retained widget keeps this owner alive through the final unrealize/destroy signals.
@MainActor
final class LinuxInputMethodClient {
    let context = OpaquePointer(gtk_im_multicontext_new())

    isolated deinit {
        gtk_im_context_set_client_widget(cast(context), nil)
        g_object_unref(RAW(context))
    }

    func bind(to widget: OpaquePointer) {
        // Install before the surface's realize handler, which can focus the new terminal.
        connect(widget, "realize", unsafeBitCast(inputMethodRealize, to: GCallback.self), RAW(context))
        connect(widget, "unrealize", unsafeBitCast(inputMethodUnrealize, to: GCallback.self), RAW(context))
    }
}

private let inputMethodRealize: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { widget, data in
    // IBus queues an idle on focus-in. Its client must have a live native surface whenever that idle runs.
    gtk_im_context_set_client_widget(cast(data.map(OpaquePointer.init)), W(widget))
}

private let inputMethodUnrealize: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    // GTK unrealizes before unrooting; a queued IBus idle now sees no client instead of a NULL surface.
    gtk_im_context_set_client_widget(cast(data.map(OpaquePointer.init)), nil)
}
