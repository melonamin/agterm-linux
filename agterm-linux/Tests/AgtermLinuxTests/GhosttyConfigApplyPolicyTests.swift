import Testing
@testable import AgtermLinux

@Suite("Ghostty config apply policy")
struct GhosttyConfigApplyPolicyTests {
    private struct Surface: Equatable {
        let id: Int
        /// Whether this surface carries surface-specific state that must survive a reload
        /// (a session background/watermark overlay) and therefore reasserts with an underlying
        /// per-surface config update.
        let carriesOverlayState: Bool
    }

    private final class UnderlyingUpdateCounters {
        var appBaseUpdates = 0
        var surfaceOverlayUpdates: [Int: Int] = [:]
        var reassertedSurfaces: [Int] = []

        func underlyingUpdatesPerSurface(surfaceCount: Int) -> [Int] {
            (0..<surfaceCount).map { surfaceOverlayUpdates[$0, default: 0] }
        }
    }

    @Test("a hard reload drives exactly one underlying base update, app level, for every window and surface")
    func singleBaseApplicationAcrossWindowsAndSurfaces() {
        let layout: [[Surface]] = [
            [Surface(id: 0, carriesOverlayState: true), Surface(id: 1, carriesOverlayState: false),
             Surface(id: 2, carriesOverlayState: true)],
            [Surface(id: 3, carriesOverlayState: false)],
            [],   // a window with no live surfaces must not change the counts
        ]
        let counters = UnderlyingUpdateCounters()

        GhosttyConfigApplyPolicy.apply(
            surfacesByWindow: layout,
            preserveSessionConfig: false,
            updateAppBaseConfig: { counters.appBaseUpdates += 1 },
            reassertState: { surface, state in
                counters.reassertedSurfaces.append(surface.id)
                guard state == .watermarkOnly else { return }
                // the reassert is the only per-surface work; it updates underlying config only
                // where surface-specific overlay state exists
                if surface.carriesOverlayState {
                    counters.surfaceOverlayUpdates[surface.id, default: 0] += 1
                }
            })

        // pinned libghostty propagates the single app-level update to every surface: one base
        // application per surface, with no second per-surface pass over the same config
        #expect(counters.appBaseUpdates == 1)
        // each surface is visited exactly once, in window order
        #expect(counters.reassertedSurfaces == [0, 1, 2, 3])
        // only surfaces carrying overlay state get an additional underlying update, one each
        #expect(counters.surfaceOverlayUpdates[0] == 1)
        #expect(counters.surfaceOverlayUpdates[2] == 1)
        #expect(counters.surfaceOverlayUpdates[1] == nil)
        #expect(counters.surfaceOverlayUpdates[3] == nil)
    }

    @Test("appearance reconciliation reasserts complete session overlays on every surface")
    func appearanceChangeReassertsSessionOverlays() {
        let layout: [[Surface]] = [
            [Surface(id: 0, carriesOverlayState: true)],
            [Surface(id: 1, carriesOverlayState: true), Surface(id: 2, carriesOverlayState: false)],
        ]
        var appBaseUpdates = 0
        var reasserts: [Int: GhosttyConfigApplyPolicy.SurfaceState] = [:]
        var overlayUpdates = 0

        GhosttyConfigApplyPolicy.apply(
            surfacesByWindow: layout,
            preserveSessionConfig: true,
            updateAppBaseConfig: { appBaseUpdates += 1 },
            reassertState: { surface, state in
                reasserts[surface.id] = state
                if surface.carriesOverlayState { overlayUpdates += 1 }
            })

        #expect(appBaseUpdates == 1)
        #expect(reasserts.count == 3)
        #expect(reasserts.values.allSatisfy { $0 == .sessionOverlay })
        #expect(overlayUpdates == 2)
    }

    @Test("a single-window single-surface reload stays at one base application")
    func singleSurfaceReload() {
        var appBaseUpdates = 0
        var reassertCount = 0

        GhosttyConfigApplyPolicy.apply(
            surfacesByWindow: [[Surface(id: 0, carriesOverlayState: false)]],
            preserveSessionConfig: false,
            updateAppBaseConfig: { appBaseUpdates += 1 },
            reassertState: { _, state in
                #expect(state == .watermarkOnly)
                reassertCount += 1
            })

        #expect(appBaseUpdates == 1)
        #expect(reassertCount == 1)
    }

    @Test("surface state follows the reload kind")
    func surfaceStateSelection() {
        #expect(GhosttyConfigApplyPolicy.surfaceState(preserveSessionConfig: true) == .sessionOverlay)
        #expect(GhosttyConfigApplyPolicy.surfaceState(preserveSessionConfig: false) == .watermarkOnly)
    }
}
