import Foundation
import Testing
@testable import agtermCore

/// The host timer seam's own contract: what a swapped-in host implementation receives, and what the
/// shipped Dispatch default does. `withFakeMainTimer` (shared fixture) owns every seam swap — its body is
/// synchronous by type, so a parallel test's timer can never land on a fake.
@MainActor
struct MainTimerTests {
    @Test func scheduleForwardsDelayAndFireToTheInjectedSeam() throws {
        try withFakeMainTimer { timers in
            var ran = 0
            let cancel = MainTimer.schedule(after: 2.5) { ran += 1 }
            #expect(timers.delays == [2.5])
            #expect(ran == 0)          // nothing runs until the host timer fires
            timers.fire(try #require(timers.index(ofDelay: 2.5)))
            #expect(ran == 1)
            cancel()                   // cancelling after the fire is the caller's business, not a crash
        }
    }

    @Test func scheduleReturnsTheSeamsCancelClosure() {
        withFakeMainTimer { timers in
            let cancel = MainTimer.schedule(after: 1) {}
            #expect(timers.cancelled.isEmpty)
            cancel()
            #expect(timers.cancelled == [0])   // exactly one cancel per invocation — no swallow
            cancel()
            #expect(timers.cancelled == [0, 0])
        }
    }

    @Test func eachScheduleGetsItsOwnIndependentCancel() throws {
        try withFakeMainTimer { timers in
            var ran: [String] = []
            let cancelFirst = MainTimer.schedule(after: 0.1) { ran.append("first") }
            _ = MainTimer.schedule(after: 0.3) { ran.append("second") }
            #expect(timers.delays == [0.1, 0.3])
            cancelFirst()
            #expect(timers.cancelled == [0])   // cancelling one pending timer leaves the other armed
            timers.fire(try #require(timers.index(ofDelay: 0.3)))
            #expect(ran == ["second"])
        }
    }

    @Test func aNegativeDelayReachesTheSeamUnmodified() {
        // The wrapper must not clamp: clamping belongs to the callers that own a meaning for it
        // (`schedulePendingCloseFinalization`'s grace) and to the host implementation, which is where an
        // unsigned conversion could trap. Pinning it here keeps a "helpful" clamp from being added blind.
        withFakeMainTimer { timers in
            MainTimer.schedule(after: -1) {}
            #expect(timers.delays == [-1])
        }
    }

    @Test func defaultSeamFiresThroughTheDispatchMainQueue() async {
        // The shipped default schedules on the dispatch main queue, which the test runtime drains (and
        // AppKit drains on macOS) — the fire itself is what is asserted here. Main-ACTOR execution is not
        // asserted at runtime because it is already a compile-time fact (the seam's fire closure is
        // `@MainActor`); a `Thread.isMainThread` check would be wrong anyway — swift-testing's main-actor
        // executor is not the process main thread on Linux. Polled rather than slept-through: a fixed wait
        // goes flaky under a loaded parallel suite.
        var fired = false
        MainTimer.schedule(after: 0.01) { fired = true }
        for _ in 0..<200 {
            if fired { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(fired)
    }

    @Test func defaultSeamCancelStopsTheFire() async {
        // A sentinel armed at the same delay carries the negative: once IT has fired, a working
        // (uncancelled) timer would have fired too, so `ran == 0` means cancelled — not merely slow.
        var ran = 0
        var sentinelFired = false
        let cancel = MainTimer.schedule(after: 0.01) { ran += 1 }
        cancel()
        MainTimer.schedule(after: 0.01) { sentinelFired = true }
        for _ in 0..<200 {
            if sentinelFired { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(sentinelFired)
        #expect(ran == 0)
    }
}
