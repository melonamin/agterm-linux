import Foundation
import Testing
@testable import agtermCore

@MainActor
struct DebouncerTests {
    @Test func flushRunsOnlyLatestActionOnce() {
        let debouncer = Debouncer()
        var first = 0
        var second = 0
        // a long delay so the async dispatch can't fire before flush; flush is what runs it.
        debouncer.schedule(after: 100) { first += 1 }
        debouncer.schedule(after: 100) { second += 1 }
        debouncer.flush()
        #expect(first == 0)
        #expect(second == 1)
    }

    @Test func cancelDropsPendingAction() {
        let debouncer = Debouncer()
        var ran = 0
        debouncer.schedule(after: 100) { ran += 1 }
        debouncer.cancel()
        debouncer.flush() // nothing pending after cancel
        #expect(ran == 0)
    }

    @Test func flushWithNothingPendingIsNoOp() {
        let debouncer = Debouncer()
        debouncer.flush() // must not crash or run anything
        var ran = 0
        debouncer.schedule(after: 100) { ran += 1 }
        debouncer.flush()
        debouncer.flush() // second flush has nothing pending
        #expect(ran == 1)
    }

    @Test func scheduledActionFiresWhenTimerElapses() async {
        // exercise the asyncAfter timer -> fire() path (the other tests use a 100s delay + flush, so the
        // timer never runs); a short real delay lets the deferred dispatch fire on its own.
        let debouncer = Debouncer()
        await confirmation { confirmed in
            debouncer.schedule(after: 0.01) { confirmed() }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    @Test func reschedulingBeforeTimerFiresRunsOnlyLatestViaTimer() async {
        // rescheduling cancels the prior pending work, so only the latest action fires through the timer.
        let debouncer = Debouncer()
        var first = 0
        await confirmation { confirmedLatest in
            debouncer.schedule(after: 0.01) { first += 1 }
            debouncer.schedule(after: 0.01) { confirmedLatest() }
            try? await Task.sleep(for: .milliseconds(200))
        }
        #expect(first == 0) // the first action was cancelled by the reschedule, never fired
    }

    @Test func scheduleRoutesThroughInjectedTimerSeam() throws {
        // The GTK port replaces MainTimer's dispatch-main-queue default (never drained under a GLib main
        // loop) with a g_timeout_add timer; drive a fake timer to prove the Debouncer's schedule /
        // reschedule / fire route through that shared seam.
        try withFakeMainTimer { timers in
            let debouncer = Debouncer()
            var ran = 0
            debouncer.schedule(after: 5) { ran += 1 }
            #expect(timers.delays == [5])
            debouncer.schedule(after: 7) { ran += 10 } // reschedule cancels the first pending timer
            #expect(timers.cancelled == [0])
            timers.fire(try #require(timers.index(ofDelay: 7))) // the injected timer fires -> latest action only
            #expect(ran == 10)
        }
    }

    @Test func cancelAndFlushStopTheInjectedTimer() {
        withFakeMainTimer { timers in
            let debouncer = Debouncer()
            var ran = 0
            debouncer.schedule(after: 1) { ran += 1 }
            debouncer.cancel()
            #expect(timers.cancelled == [0])
            timers.fireEvenIfCancelled(0) // a stale fire after cancel finds no action — must be a no-op
            #expect(ran == 0)
            debouncer.schedule(after: 1) { ran += 10 }
            debouncer.flush() // flush cancels the timer and runs the action synchronously
            #expect(timers.cancelled == [0, 1])
            #expect(ran == 10)
            timers.fireEvenIfCancelled(1) // stale fire after flush: action already consumed
            #expect(ran == 10)
        }
    }

    @Test func actionCallingFlushReentrantlyIsSafeNoOp() {
        // fire() clears `action` before invoking it, so an action that re-entrantly flush()es is a no-op
        // rather than recursing or running twice.
        let debouncer = Debouncer()
        var ran = 0
        debouncer.schedule(after: 100) {
            ran += 1
            debouncer.flush() // re-entrant: nothing pending now, must not run the action again
        }
        debouncer.flush()
        #expect(ran == 1)
    }
}
