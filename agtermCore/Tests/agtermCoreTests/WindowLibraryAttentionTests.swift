import Foundation
import Observation
import Testing
@testable import agtermCore

@MainActor
final class WindowLibraryAttentionTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-attention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func addSession(to store: AppStore, status: AgentStatus) throws -> Session {
        let session = try #require(store.addSession(toWorkspace: store.workspaces[0].id, cwd: "/tmp"))
        store.setAgentIndicator(AgentIndicator(status: status), forSession: session.id)
        return session
    }

    @Test func attentionAcrossWindowsRanksStatusBeforeWindowOrder() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let firstStore = try #require(library.store(for: first))
        let second = library.newWindow(name: "second")
        let secondStore = try #require(library.store(for: second.id))
        let blocked = try addSession(to: secondStore, status: .blocked)
        let completed = try addSession(to: firstStore, status: .completed)
        let active = try addSession(to: firstStore, status: .active)

        let entries = library.attentionAcrossWindows

        #expect(entries.map(\.session.id) == [blocked.id, active.id, completed.id])
        #expect(entries.map(\.window.id) == [second.id, first, first])
    }

    @Test func attentionAcrossWindowsOrdersASharedRankNewestFirstAcrossWindows() throws {
        let library = WindowLibrary(directory: directory)
        let firstStore = try #require(library.activeStore)
        let second = library.newWindow(name: "second")
        let secondStore = try #require(library.store(for: second.id))
        let older = try addSession(to: firstStore, status: .blocked)
        let newer = try addSession(to: secondStore, status: .blocked)

        #expect(library.attentionAcrossWindows.map(\.session.id) == [newer.id, older.id])
    }

    @Test func attentionAcrossWindowsMatchesTheSingleWindowList() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        _ = try addSession(to: store, status: .completed)
        _ = try addSession(to: store, status: .blocked)
        _ = try addSession(to: store, status: .active)

        #expect(library.attentionAcrossWindows.map(\.session.id) == store.attentionSessions.map(\.id))
    }

    @Test func attentionAcrossWindowsSkipsClosedWindows() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let firstStore = try #require(library.store(for: first))
        let second = library.newWindow(name: "second")
        let secondStore = try #require(library.store(for: second.id))
        _ = try addSession(to: secondStore, status: .blocked)
        let kept = try addSession(to: firstStore, status: .completed)

        library.closeWindow(second.id)

        #expect(library.attentionAcrossWindows.map(\.session.id) == [kept.id])
    }

    @Test func attentionAcrossWindowsInvalidatesWhenABackgroundWindowCloses() throws {
        let library = WindowLibrary(directory: directory)
        let first = try #require(library.activeWindowID)
        let second = library.newWindow(name: "second")
        let secondStore = try #require(library.store(for: second.id))
        _ = try addSession(to: secondStore, status: .blocked)
        library.frontmostWindowID = first
        let fired = Flag()
        withObservationTracking {
            _ = library.attentionAcrossWindows
        } onChange: {
            fired.set()
        }

        library.closeWindow(second.id)

        #expect(fired.isSet)
        #expect(library.windows.count == 2)
        #expect(library.frontmostWindowID == first)
        #expect(library.attentionAcrossWindows.isEmpty)
    }

    @Test func attentionSubtitleNamesTheWindowOnlyWithSeveralOpen() throws {
        let library = WindowLibrary(directory: directory)
        let store = try #require(library.activeStore)
        let session = try addSession(to: store, status: .blocked)
        let single = try #require(library.attentionAcrossWindows.first)
        #expect(library.attentionSubtitle(single) == "workspace 1 · \(session.subtitleDetail)")

        let second = library.newWindow(name: "second")
        let entry = try #require(library.attentionAcrossWindows.first { $0.session.id == session.id })
        #expect(library.attentionSubtitle(entry) == "\(entry.window.name) · workspace 1 · \(session.subtitleDetail)")

        library.closeWindow(second.id)
        #expect(library.attentionSubtitle(entry) == "workspace 1 · \(session.subtitleDetail)")
    }

    private final class Flag: @unchecked Sendable {
        private(set) var isSet = false
        func set() { isSet = true }
    }
}
