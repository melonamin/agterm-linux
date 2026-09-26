import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux dashboard presentation")
struct DashboardPresentationTests {
    private let first = DashboardMember(session: UUID(), surface: .primary)
    private let second = DashboardMember(session: UUID(), surface: .split)

    @Test("the latest click supersedes an older generation")
    func latestClickWins() {
        var intent = DashboardClickIntent()
        let firstGeneration = intent.begin(member: first)
        let secondGeneration = intent.begin(member: second)

        #expect(!intent.accepts(generation: firstGeneration, member: first))
        #expect(intent.accepts(generation: secondGeneration, member: second))
        #expect(DashboardClickIntent.delayMilliseconds == 180)
    }

    @Test("cancellation rejects an already scheduled click")
    func cancellationRejectsScheduledClick() {
        var intent = DashboardClickIntent()
        let generation = intent.begin(member: first)

        intent.cancel()

        #expect(!intent.accepts(generation: generation, member: first))
        #expect(intent.member == nil)
    }

    @Test("normal titles add only custom window names")
    func normalTitles() {
        #expect(LinuxModalTitle.normal(sessionName: nil, window: nil) == "Agterm")
        #expect(LinuxModalTitle.normal(
            sessionName: "build", window: WindowInfo(name: "window 3")) == "build")
        #expect(LinuxModalTitle.normal(
            sessionName: "build", window: WindowInfo(name: "release")) == "build — release")
    }

    @Test("dashboard titles add only custom window names")
    func dashboardTitles() {
        #expect(LinuxModalTitle.dashboard(window: nil) == "Dashboard")
        #expect(LinuxModalTitle.dashboard(window: WindowInfo(name: "window 3")) == "Dashboard")
        #expect(LinuxModalTitle.dashboard(window: WindowInfo(name: "release")) == "Dashboard — release")
    }
}
