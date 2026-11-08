// `.claude/rules/libghostty.md` owns this contract.
import CGtk
import Foundation

struct GhosttySurfaceQuarantineRecord: @unchecked Sendable {
    let wrapper: GhosttySurface
    let storage: GhosttySurfaceConfigurationStorage?
    let configs: [ghostty_config_t]
    let owner: OpaquePointer
}

private func logRetainedGL(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

let gSurfaceQuarantine = LinuxSurfaceQuarantine<GhosttySurfaceQuarantineRecord>(log: logRetainedGL)

extension GhosttySurface: LinuxEngineSurfaceOwner {
    /// The ref covers exactly this creation. A re-realize never replaces it: old objects must not be drawn in a new context.
    func newSurfaceRetainingGLContext(_ app: ghostty_app_t, _ config: inout ghostty_surface_config_s) -> ghostty_surface_t? {
        guard let owner = gtk_gl_area_get_context(GLA(glArea)) else {
            logRetainedGL("agterm: GLArea has no GL context; surface not created")
            return nil
        }
        g_object_ref(RAW(owner))
        guard let created = ghostty_surface_new(app, &config) else {
            g_object_unref(RAW(owner))
            return nil
        }
        retainedGLOwner = owner
        return created
    }

    /// Touches no `glArea`: the widget may already be gone.
    func freeEngineSurface(_ engine: ghostty_surface_t) {
        guard let owner = retainedGLOwner else { preconditionFailure("a live surface always has a retained GL owner") }
        let result = LinuxRetainedGLTeardown.run(owner: owner, steps: retainedGLSteps(owner: owner, engine: engine))
        retainedGLOwner = nil
        if !result.free.calledFree { quarantine(owner: owner) }
        surface = nil
    }

    private func retainedGLSteps(owner: OpaquePointer, engine: ghostty_surface_t) -> LinuxRetainedGLTeardownSteps<OpaquePointer> {
        let skipFree = LinuxSurfaceFailureInjection.skipsGLFree(for: role)
        return LinuxRetainedGLTeardownSteps(
            displayIsOpen: { gdk_display_is_closed(gdk_gl_context_get_display(owner)) == 0 },
            current: { gdk_gl_context_get_current() },
            retain: { g_object_ref(RAW($0)) },
            release: { g_object_unref(RAW($0)) },
            makeCurrent: { context in
                if skipFree, context == owner { return false }
                gdk_gl_context_make_current(context)
                return gdk_gl_context_get_current() == context
            },
            clear: {
                if skipFree { return false }
                gdk_gl_context_clear_current()
                return gdk_gl_context_get_current() == nil
            },
            free: { ghostty_surface_free(engine) },
            log: logRetainedGL)
    }

    private func quarantine(owner: OpaquePointer) {
        let key = LinuxSurfaceQuarantine<GhosttySurfaceQuarantineRecord>.key(Unmanaged.passUnretained(self).toOpaque())
        gSurfaceQuarantine.transfer(key: key, storage: &configurationStorage, configs: &ownedConfigs) { storage, configs in
            GhosttySurfaceQuarantineRecord(wrapper: self, storage: storage, configs: configs, owner: owner)
        }
        onExit = nil
        onExitHeld = nil
    }

    func dischargeEngineSurface() {
        if let surface { freeEngineSurface(surface) }
    }
}

/// The `destroy` signal, GTK's last hold on the wrapper.
@MainActor
func surfaceWidgetDestroyed(_ data: UnsafeMutableRawPointer) {
    let reference = Unmanaged<GhosttySurface>.fromOpaque(data)
    LinuxSurfaceWidgetLifecycle.destroyed(reference.takeUnretainedValue()) {
        let key = LinuxSurfaceQuarantine<GhosttySurfaceQuarantineRecord>.key(data)
        if gSurfaceQuarantine.contains(key) { logRetainedGL("\(LinuxRetainedGLTeardown.logPrefix) quarantined widget destroyed") }
        reference.release()
    }
}
