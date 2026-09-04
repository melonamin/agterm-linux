import CGtk
import Foundation

private let controllerContextKey = "agterm-controller-window-id"

private final class ControllerWidgetContext {
    let windowID: UUID

    init(windowID: UUID) {
        self.windowID = windowID
    }
}

private let releaseControllerWidgetContext: GDestroyNotify = { data in
    guard let data else { return }
    Unmanaged<ControllerWidgetContext>.fromOpaque(data).release()
}

@MainActor
func attachControllerContext(to object: OpaquePointer?, windowID: UUID) {
    guard let object else { return }
    let context = Unmanaged.passRetained(ControllerWidgetContext(windowID: windowID)).toOpaque()
    controllerContextKey.withCString {
        g_object_set_data_full(GOBJ(object), $0, context, releaseControllerWidgetContext)
    }
}

@MainActor
func controllerForObject(_ object: OpaquePointer?) -> AppController? {
    guard let object else { return nil }
    let data = controllerContextKey.withCString { g_object_get_data(GOBJ(object), $0) }
    guard let data else { return nil }
    let windowID = Unmanaged<ControllerWidgetContext>.fromOpaque(data).takeUnretainedValue().windowID
    return gWindows[windowID]
}

@MainActor
func controllerForWidget(_ widget: OpaquePointer?) -> AppController? {
    var current = widget
    while let node = current {
        if let controller = controllerForObject(node) { return controller }
        current = gtk_widget_get_parent(W(node)).map { OpaquePointer($0) }
    }
    return nil
}

@MainActor
func controllerForEventController(_ eventController: OpaquePointer?) -> AppController? {
    gtk_event_controller_get_widget(eventController).flatMap { controllerForWidget(OpaquePointer($0)) }
}
