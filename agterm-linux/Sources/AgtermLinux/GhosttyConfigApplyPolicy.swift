/// How a rebuilt ghostty config reaches live surfaces on a hard reload.
///
/// The app-level update is the single base application: pinned libghostty propagates
/// `ghostty_app_update_config` to every surface. Per-surface work only reasserts surface-specific
/// state (session background/watermark overlays and per-pane font sizes). A second per-surface pass
/// over the same base config would double the underlying update for every terminal on GTK's main path.
enum GhosttyConfigApplyPolicy {
    enum SurfaceState: Equatable {
        /// Automatic appearance reconciliation restores complete per-session overlays.
        case sessionOverlay
        /// Explicit config reloads stay watermark-only.
        case watermarkOnly
    }

    static func surfaceState(preserveSessionConfig: Bool) -> SurfaceState {
        preserveSessionConfig ? .sessionOverlay : .watermarkOnly
    }

    /// One app-level base application followed by exactly one state reassert per surface,
    /// across every window, in window order.
    static func apply<Surface>(
        surfacesByWindow: [[Surface]],
        preserveSessionConfig: Bool,
        updateAppBaseConfig: () -> Void,
        reassertState: (Surface, SurfaceState) -> Void
    ) {
        updateAppBaseConfig()
        let state = surfaceState(preserveSessionConfig: preserveSessionConfig)
        for surfaces in surfacesByWindow {
            for surface in surfaces {
                reassertState(surface, state)
            }
        }
    }
}
