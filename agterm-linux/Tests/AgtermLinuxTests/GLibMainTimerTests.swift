import CGtk
import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

/// The GLib implementation of `agtermCore`'s `MainTimer` seam — the code that makes deferred main-actor
/// work fire at all under `g_application_run`. Driven headlessly: `g_main_context_iteration` pumps the
/// default context directly, so there is no display, no `gtk_init`, and no `await` while the
/// process-global seam is swapped. Serialized because that seam (and the GLib default context) is global.
@MainActor
@Suite(.serialized)
struct GLibMainTimerTests {
    @Test func aScheduledFireRunsExactlyOnceOnTheGLibLoop() {
        withGLibMainTimer {
            var fired = 0
            MainTimer.schedule(after: 0) { fired += 1 }
            #expect(fired == 0)             // nothing runs until the loop is pumped
            pumpGLib(until: { fired > 0 })
            #expect(fired == 1)
            pumpGLib()                      // one-shot: the source removed itself, so it cannot re-fire
            #expect(fired == 1)
        }
    }

    @Test func cancellingBeforeTheTimeoutStopsTheFire() {
        withGLibMainTimer {
            var fired = 0
            let cancel = MainTimer.schedule(after: 0) { fired += 1 }
            cancel()
            pumpGLib()
            #expect(fired == 0)
        }
    }

    @Test func cancellingAfterTheFireIsInertAndLeavesOtherTimersAlone() {
        // `Debouncer.flush()` deliberately keeps a consumed cancel closure, so a stale cancel really is
        // invoked in production. It must be a no-op: the source removed itself when it fired
        // (`fired()` zeroes the id, and the `sourceID != 0` guard then skips `g_source_remove`), and a
        // timer armed in between must survive it.
        withGLibMainTimer {
            var firstFired = 0, secondFired = 0
            let cancelFirst = MainTimer.schedule(after: 0) { firstFired += 1 }
            pumpGLib(until: { firstFired > 0 })
            #expect(firstFired == 1)

            MainTimer.schedule(after: 0) { secondFired += 1 }   // may well reuse the first source's id
            cancelFirst()                                       // stale cancel: must be a no-op
            pumpGLib(until: { secondFired > 0 })
            #expect(secondFired == 1)
        }
    }

    @Test func outOfRangeDelaysAreClampedInsteadOfTrapping() {
        // `MainTimer.schedule` is public API taking any `TimeInterval`, and an unchecked `guint(...)` of a
        // negative, non-finite, or >49-day delay traps and takes the app down.
        withGLibMainTimer {
            var negativeFired = 0, infiniteFired = 0
            MainTimer.schedule(after: -5) { negativeFired += 1 }        // clamped to 0: fires next turn
            let cancelInfinite = MainTimer.schedule(after: .infinity) { infiniteFired += 1 }
            pumpGLib(until: { negativeFired > 0 })
            #expect(negativeFired == 1)
            #expect(infiniteFired == 0)                                 // parked at guint.max, never fires
            cancelInfinite()                                            // do not leave it on the loop
            pumpGLib()
            #expect(infiniteFired == 0)
        }
    }

    /// Installs the GLib seam for the duration of `body` and restores the previous one. Synchronous by
    /// type: `MainTimer.scheduleTimer` is a process-global static.
    private func withGLibMainTimer<R>(_ body: () throws -> R) rethrows -> R {
        let original = MainTimer.scheduleTimer
        defer { MainTimer.scheduleTimer = original }
        installGLibMainTimer()
        return try body()
    }

    /// Dispatches ready GLib sources without blocking, stopping early once `until` holds. Bounded so a
    /// timer that never becomes ready cannot hang the suite.
    private func pumpGLib(until done: () -> Bool = { false }, iterations: Int = 500) {
        for _ in 0..<iterations {
            if done() { return }
            _ = g_main_context_iteration(nil, 0)
        }
    }
}
