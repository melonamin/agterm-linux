import Foundation
import Testing
@testable import agtermCore

/// The soft-close grace finalizer as seen through the `MainTimer` seam. `AppStoreCloseReselectionTests`
/// rides the REAL timer with a tiny grace; these pin the mechanism itself — that the finalizer is armed
/// through the host seam (never a bare `Task.sleep`, which the GLib main loop never runs) and that every
/// cancel site drops the pending entry instead of letting a late fire tear down a live session.
/// `withFakeMainTimer` (shared fixture) owns the swap; its body is synchronous by type.
@MainActor
struct PendingCloseTimerTests {
    @Test func softCloseSchedulesTheGraceDelayAndFinalizesWhenTheEntryFires() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let ws = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let surface = SpySurface()
        closing.surface = surface

        try withFakeMainTimer { timers in
            #expect(store.softCloseSession(closing.id, grace: 5))
            let grace = try #require(timers.index(ofDelay: 5))
            #expect(!store.workspaces.flatMap(\.sessions).contains { $0.id == closing.id })
            #expect(surface.teardownCount == 0) // still undoable, so the surfaces stay alive through the grace
            #expect(store.pendingCloseSummary?.kind == .session)

            timers.fire(grace)

            #expect(surface.teardownCount == 1)
            #expect(store.pendingCloseRecords.isEmpty)
            #expect(store.pendingCloseSummary == nil)
            #expect(recentClosed.load().contains { $0.session?.snapshot.id == closing.id }) // Open Recent keeps it
        }
    }

    @Test func aZeroOrNegativeGraceIsClampedToAnImmediateEntry() throws {
        // `grace` is caller-supplied on the public soft-close API, so 0 and negative values are reachable.
        // The clamp is load-bearing on the GLib host: a negative delay would otherwise reach an unsigned
        // millisecond conversion.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let zero = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let negative = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        let zeroSurface = SpySurface(), negativeSurface = SpySurface()
        zero.surface = zeroSurface
        negative.surface = negativeSurface

        try withFakeMainTimer { timers in
            #expect(store.softCloseSession(zero.id, grace: 0))
            #expect(store.softCloseSession(negative.id, grace: -1))
            #expect(timers.delays.filter { $0 == 0 }.count == 2) // both armed at exactly 0, none negative
            #expect(!timers.delays.contains { $0 < 0 })

            // the record is still undoable until the (immediate) entry actually fires
            #expect(zeroSurface.teardownCount == 0)
            let first = try #require(timers.index(ofDelay: 0))
            let second = try #require(timers.lastIndex(ofDelay: 0))
            timers.fire(first)
            timers.fire(second)
            #expect(zeroSurface.teardownCount == 1)
            #expect(negativeSurface.teardownCount == 1)
            #expect(store.pendingCloseRecords.isEmpty)
        }
    }

    @Test func undoPendingCloseCancelsTheGraceEntry() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let surface = SpySurface()
        closing.surface = surface

        try withFakeMainTimer { timers in
            #expect(store.softCloseSession(closing.id, grace: 5))
            let grace = try #require(timers.index(ofDelay: 5))
            #expect(store.undoPendingClose())
            #expect(timers.cancelled.contains(grace))

            timers.fireEvenIfCancelled(grace) // a host timer that fires anyway must not tear down the restored session
            #expect(surface.teardownCount == 0)
            #expect(store.workspaces.flatMap(\.sessions).contains { $0.id == closing.id })
        }
    }

    @Test func foldingAWorkspaceCloseCancelsTheSupersededEntry() throws {
        let store = makeStore()
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addWorkspace(name: "keep")
        let first = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/a"))
        let second = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/b"))
        let secondSurface = SpySurface()
        second.surface = secondSurface

        try withFakeMainTimer { timers in
            // close a session, then its workspace, then undo the session close so it lands in a rebuilt shell;
            // closing that shell folds the still-pending workspace record away — its timer must go with it.
            #expect(store.softCloseSession(first.id, grace: 5))
            let sessionClose = try #require(store.pendingCloseSummary?.id)
            #expect(store.softRemoveWorkspace(doomed.id, grace: 7))
            let superseded = try #require(timers.index(ofDelay: 7))
            #expect(store.undoPendingClose(sessionClose))
            #expect(store.softRemoveWorkspace(doomed.id, grace: 9))

            #expect(timers.cancelled.contains(superseded))
            // the folded record now owns those sessions; a late fire must not touch them
            timers.fireEvenIfCancelled(superseded)
            #expect(secondSurface.teardownCount == 0)
            #expect(store.pendingCloseRecords.count == 1)

            let folded = try #require(timers.index(ofDelay: 9))
            timers.fire(folded)
            #expect(secondSurface.teardownCount == 1)
            #expect(store.pendingCloseRecords.isEmpty)
        }
    }

    @Test func twoPendingClosesKeepIndependentGraceEntries() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let early = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let late = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        let earlySurface = SpySurface(), lateSurface = SpySurface()
        early.surface = earlySurface
        late.surface = lateSurface

        try withFakeMainTimer { timers in
            #expect(store.softCloseSession(early.id, grace: 5))
            #expect(store.softCloseSession(late.id, grace: 7))
            let earlyEntry = try #require(timers.index(ofDelay: 5))
            let lateEntry = try #require(timers.index(ofDelay: 7))
            #expect(store.pendingCloseRecords.count == 2)

            timers.fire(earlyEntry)   // fire() also asserts this entry was never cancelled out from under
            #expect(earlySurface.teardownCount == 1)
            #expect(lateSurface.teardownCount == 0)   // one grace expiring leaves the other record armed
            #expect(!timers.cancelled.contains(lateEntry))
            #expect(store.pendingCloseRecords.count == 1)

            timers.fire(lateEntry)
            #expect(lateSurface.teardownCount == 1)
            #expect(store.pendingCloseRecords.isEmpty)
        }
    }

    @Test func reclosingASessionAfterAnUndoArmsAFreshEntry() throws {
        // Each close mints a fresh record id, so `schedulePendingCloseFinalization`'s same-id replace is a
        // defensive guard; what a user can actually reach is close → undo → close, which must leave only
        // the newest entry able to finalize.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let closing = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let surface = SpySurface()
        closing.surface = surface

        try withFakeMainTimer { timers in
            #expect(store.softCloseSession(closing.id, grace: 5))
            let stale = try #require(timers.index(ofDelay: 5))
            #expect(store.undoPendingClose())
            #expect(store.softCloseSession(closing.id, grace: 7))
            let fresh = try #require(timers.index(ofDelay: 7))

            #expect(timers.cancelled.contains(stale))
            // the first close's timer is dead — it must not shorten the new grace window
            timers.fireEvenIfCancelled(stale)
            #expect(surface.teardownCount == 0)

            timers.fire(fresh)
            #expect(surface.teardownCount == 1)
            #expect(store.pendingCloseRecords.isEmpty)
        }
    }

    @Test func heldSessionIDsCoverEveryPendingCloseUntilItFinalizes() throws {
        // A host that owns terminal surfaces outside the store (the GTK deck) reaps the ones the visible
        // tree no longer names. `pendingHeldSessionIDs()` is what keeps a soft close out of that sweep for
        // the length of its undo window, so it must report every held id — single, batch and workspace —
        // and stop reporting one the moment the record is undone or finalized.
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        let kept = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let single = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let batchOne = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        let batchTwo = try #require(store.addSession(toWorkspace: ws.id, cwd: "/d"))
        let inWorkspace = try #require(store.addSession(toWorkspace: doomed.id, cwd: "/e"))

        try withFakeMainTimer { timers in
            #expect(store.pendingHeldSessionIDs().isEmpty)
            #expect(store.softCloseSession(single.id, grace: 5))
            let singleEntry = try #require(timers.index(ofDelay: 5))
            #expect(store.softCloseSessions([batchOne.id, batchTwo.id], grace: 7))
            #expect(store.softRemoveWorkspace(doomed.id, grace: 9))
            let workspaceEntry = try #require(timers.index(ofDelay: 9))

            // absent from the tree, still held — a host sweep keyed on the tree alone would kill these shells
            let visible = Set(store.workspaces.flatMap(\.sessions).map(\.id))
            #expect(visible == [kept.id])
            #expect(store.pendingHeldSessionIDs()
                == [single.id, batchOne.id, batchTwo.id, inWorkspace.id])

            #expect(store.undoPendingClose(try #require(store.pendingCloseSummary?.id)))
            #expect(!store.pendingHeldSessionIDs().contains(inWorkspace.id)) // back in the tree, no longer held
            #expect(store.workspaces.flatMap(\.sessions).contains { $0.id == inWorkspace.id })
            #expect(!timers.cancelled.contains(singleEntry))
            #expect(timers.cancelled.contains(workspaceEntry))

            timers.fire(singleEntry) // its grace expired: the surface is torn down, so the host may reap it
            #expect(store.pendingHeldSessionIDs() == [batchOne.id, batchTwo.id])

            store.finalizeAllPendingCloses()
            #expect(store.pendingHeldSessionIDs().isEmpty)
        }
    }

    @Test func quitFlushFinalizationCancelsEveryPendingGraceEntry() throws {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: ws.id, cwd: "/a"))
        let early = try #require(store.addSession(toWorkspace: ws.id, cwd: "/b"))
        let late = try #require(store.addSession(toWorkspace: ws.id, cwd: "/c"))
        let earlySurface = SpySurface(), lateSurface = SpySurface()
        early.surface = earlySurface
        late.surface = lateSurface

        try withFakeMainTimer { timers in
            #expect(store.softCloseSession(early.id, grace: 5))
            #expect(store.softCloseSession(late.id, grace: 7))
            let earlyEntry = try #require(timers.index(ofDelay: 5))
            let lateEntry = try #require(timers.index(ofDelay: 7))

            store.finalizeAllPendingCloses() // the quit flush: finalize now, do not wait out the graces

            #expect(earlySurface.teardownCount == 1)
            #expect(lateSurface.teardownCount == 1)
            #expect(store.pendingCloseRecords.isEmpty)
            #expect(timers.cancelled.contains(earlyEntry))
            #expect(timers.cancelled.contains(lateEntry))

            // late host fires after the flush must not tear a surface down twice
            timers.fireEvenIfCancelled(earlyEntry)
            timers.fireEvenIfCancelled(lateEntry)
            #expect(earlySurface.teardownCount == 1)
            #expect(lateSurface.teardownCount == 1)
        }
    }
}
