import CGtk
import Testing
@testable import AgtermLinux

/// Pins the release point of the reparent guard on a plain `GObject`: no display, no `gtk_init`.
@Suite("GTK reparent ref guard")
struct WidgetRefHoldTests {
    @Test func theHeldReferenceOutlivesTheParentsAndIsReleasedAtScopeExit() throws {
        // The return is an IUO pointer; `OpaquePointer(_:)` would resolve to the failable init and yield
        // `OpaquePointer?`, which the non-optional helper parameter rejects — unwrap explicitly.
        let raw = try #require(g_object_new_with_properties(GType(80) /* G_TYPE_OBJECT */, 0, nil, nil))
        let object = OpaquePointer(raw)
        let slot = UnsafeMutablePointer<gpointer?>.allocate(capacity: 1)
        slot.initialize(to: RAW(object))
        defer {
            if slot.pointee != nil { g_object_remove_weak_pointer(GOBJ(object), slot) }
            slot.deinitialize(count: 1)
            slot.deallocate()
        }
        g_object_add_weak_pointer(GOBJ(object), slot)

        let answer = withWidgetRefHeld(object) { () -> Int in
            g_object_unref(RAW(object))
            #expect(slot.pointee != nil)
            return 7
        }

        #expect(answer == 7)
        #expect(slot.pointee == nil)
    }
}
