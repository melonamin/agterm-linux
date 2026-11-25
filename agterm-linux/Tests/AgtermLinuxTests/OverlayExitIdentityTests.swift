import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Session overlay exit identity")
@MainActor
struct OverlayExitIdentityTests {
    final class OverlaySurface: TerminalSurface {
        var isRealized = true
        var paneToken: String { "" }
        func teardown() {}
        func promoteToPrimaryPane() {}
    }

    let store: AppStore
    let session: Session

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")
        let workspace = Workspace(name: "work", sessions: [])
        store = AppStore(workspaces: [workspace], selectedSessionID: nil,
                         persistence: PersistenceStore(directory: directory))
        session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
    }

    private func openProgram() -> OverlaySurface {
        #expect(store.openOverlay(session.id, command: "job"))
        let surface = OverlaySurface()
        session.overlaySurface = surface
        return surface
    }

    @Test("a current surface's exit closes its slot")
    func currentSurface() {
        let surface = openProgram()
        #expect(AppController.sessionOverlayExitCloses(surface, in: session))
    }

    @Test("a stale surface's exit leaves a replacement program overlay open")
    func replacementProgram() {
        let stale = openProgram()
        store.closeOverlay(session.id)
        _ = openProgram()
        #expect(!AppController.sessionOverlayExitCloses(stale, in: session))
    }

    @Test("a stale surface's exit leaves a replacement HTML overlay open")
    func replacementPage() {
        let stale = openProgram()
        store.closeOverlay(session.id)
        let page = HtmlOverlay(source: .file(path: "/tmp/a/report.html", grantRoot: nil))
        #expect(store.openHtmlOverlay(session.id, pane: nil, overlay: page, sizePercent: nil) == nil)
        #expect(!AppController.sessionOverlayExitCloses(stale, in: session))
    }

    @Test("a stale surface's exit leaves an emptied slot alone")
    func emptiedSlot() {
        let stale = openProgram()
        store.closeOverlay(session.id)
        #expect(!AppController.sessionOverlayExitCloses(stale, in: session))
        #expect(!AppController.sessionOverlayExitCloses(nil, in: session))
        #expect(!AppController.sessionOverlayExitCloses(stale, in: nil))
    }
}
