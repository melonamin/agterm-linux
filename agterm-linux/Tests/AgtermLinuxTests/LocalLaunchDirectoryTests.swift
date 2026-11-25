import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@MainActor
@Suite("local launch directory")
struct LocalLaunchDirectoryTests {
    enum Site: CaseIterable, Sendable {
        case sessionOverlay, leftPaneOverlay, split, scratch, newSession, quickTerminal

        @MainActor
        func resolve(_ session: Session, home: String) -> String {
            switch self {
            case .sessionOverlay: AppController.overlayLaunchCwd(session, pane: nil, home: home)
            case .leftPaneOverlay: AppController.overlayLaunchCwd(session, pane: .left, home: home)
            case .split: AppController.splitLaunchCwd(session, home: home)
            case .scratch: AppController.scratchLaunchCwd(session, home: home)
            case .newSession:
                AppController.newSessionCwd(settings: AppSettings(newSessionDirectory: "currentSession"),
                                            activeSession: session, home: home)
            case .quickTerminal: AppController.quickTerminalCwd(activeSession: session, home: home)
            }
        }
    }

    private static let home = "/home/agterm-test"
    private static let remotePath = "/nonexistent-agterm-remote/\(UUID().uuidString)"

    private func session(remote: Bool, reported: String) -> Session {
        let session = Session(initialCwd: reported, remoteHost: remote ? "far" : nil)
        session.leftOverlay = PaneOverlay(command: "revdiff")
        return session
    }

    @Test("a remote path missing here starts the local launch in HOME", arguments: Site.allCases)
    func remoteMissingPathFallsBackToHome(site: Site) {
        #expect(site.resolve(session(remote: true, reported: Self.remotePath), home: Self.home) == Self.home)
    }

    @Test("a remote path that exists here is kept", arguments: Site.allCases)
    func remoteExistingPathIsKept(site: Site) {
        let local = FileManager.default.temporaryDirectory.path
        #expect(site.resolve(session(remote: true, reported: local), home: Self.home) == local)
    }

    @Test("a local session keeps its reported path verbatim", arguments: Site.allCases)
    func localSessionUnchanged(site: Site) {
        #expect(site.resolve(session(remote: false, reported: Self.remotePath), home: Self.home) == Self.remotePath)
    }

    @Test("each site reads its own reported input")
    func eachSiteReadsItsOwnInput() {
        let reported = FileManager.default.temporaryDirectory.path
        let session = session(remote: true, reported: Self.remotePath)
        session.currentCwd = reported
        session.initialSplitCwd = Self.remotePath
        #expect(AppController.splitLaunchCwd(session, home: Self.home) == Self.home)
        #expect(AppController.scratchLaunchCwd(session, home: Self.home) == reported)
        #expect(AppController.quickTerminalCwd(activeSession: session, home: Self.home) == reported)
        #expect(AppController.newSessionCwd(settings: AppSettings(newSessionDirectory: "currentSession"),
                                            activeSession: session, home: Self.home) == reported)
        session.initialSplitCwd = nil
        #expect(AppController.splitLaunchCwd(session, home: Self.home) == reported)
    }

    @Test("an explicit overlay --cwd is kept verbatim on a remote session", arguments: [nil, OverlayPane.left])
    func explicitOverlayCwdBypassesTheRemoteRule(pane: OverlayPane?) {
        let session = session(remote: true, reported: Self.remotePath)
        session.overlayCwd = Self.remotePath
        session.leftOverlay = PaneOverlay(command: "revdiff", cwd: Self.remotePath)
        #expect(AppController.overlayLaunchCwd(session, pane: pane, home: Self.home) == Self.remotePath)
    }

    @Test("with no active session the quick terminal and a new session start in HOME")
    func noActiveSessionStartsInHome() {
        #expect(AppController.quickTerminalCwd(activeSession: nil, home: Self.home) == Self.home)
        #expect(AppController.newSessionCwd(settings: AppSettings(newSessionDirectory: "currentSession"),
                                            activeSession: nil, home: Self.home) == Self.home)
    }

    @Test("the new-session setting still decides before the remote rule")
    func newSessionSettingStillApplies() {
        let session = session(remote: true, reported: FileManager.default.temporaryDirectory.path)
        #expect(AppController.newSessionCwd(settings: AppSettings(), activeSession: session, home: Self.home) == Self.home)
        #expect(AppController.newSessionCwd(settings: AppSettings(newSessionDirectory: "custom",
                                                                  newSessionCustomDirectory: Self.remotePath),
                                            activeSession: session, home: Self.home) == Self.remotePath)
    }
}
