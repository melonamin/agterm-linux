import CGtk
import agtermCore
import Foundation

@MainActor
extension GhosttySurface {
    /// Reserve the one exit transition for an explicit zmx kill. The later libghostty child-exit action
    /// becomes inert, so the already-finalized daemon cannot close or promote the pane twice.
    func claimProcessExit() -> Bool {
        guard !didHandleProcessExit else { return false }
        didHandleProcessExit = true
        finishExitCodeCapture()
        onExit = nil
        return true
    }

    func useSpawnPacer(_ pacer: SpawnPacer, key: UUID) {
        spawnPacer = pacer
        spawnKey = key
    }

    func expediteSpawn() {
        guard let spawnPacer, let spawnKey else { return }
        spawnPacer.expedite(spawnKey)
    }

    func resumePacedSpawn() {
        guard awaitingSpawnPermit else { return }
        awaitingSpawnPermit = false
        createSurface()
    }

    func resolveLaunchSeed() {
        guard let provider = launchSeed else { return }
        launchSeed = nil
        let seed = provider.resolve(isSplitPane ? .right : .left)
        command = seed.command
        initialInput = seed.initialInput
        waitAfterCommand = seed.waitAfterCommand
    }

    /// The live foreground-process argv (via `/proc/<pid>/cmdline`), or nil at the shell prompt — the
    /// Linux analogue of macOS's KERN_PROCARGS2 capture, used for `tree` introspection / restore.
    func foregroundCommand(zmxSnapshot: LinuxZmxForegroundResolver.Snapshot?) -> [String]? {
        guard let argv = foregroundArgv(zmxSnapshot: zmxSnapshot),
              !CommandRestore.isIdleShell(argv: argv, extra: loginShellName) else { return nil }
        return argv
    }

    /// The foreground process classified for control-tree reporting. Unlike restore capture, a shell is
    /// retained as `foregroundShell` so clients can distinguish an idle prompt from a missing process read.
    func paneForeground(zmxSnapshot: LinuxZmxForegroundResolver.Snapshot?) -> CommandRestore.PaneForeground? {
        guard let argv = foregroundArgv(zmxSnapshot: zmxSnapshot) else { return nil }
        return CommandRestore.paneForeground(argv: argv, extra: loginShellName)
    }

    var loginShellName: String? {
        let shell = env["SHELL"] ?? ProcessInfo.processInfo.environment["SHELL"]
        return shell.map(CommandRestore.basename)
    }

    private func foregroundArgv(zmxSnapshot: LinuxZmxForegroundResolver.Snapshot?) -> [String]? {
        guard let surface,
              let pid = LinuxZmxForegroundResolver.paneForegroundPID(
                  backedByZmx: backedByZmx, paneIdentity: UUID(uuidString: paneToken), snapshot: zmxSnapshot,
                  localForeground: { Int32(exactly: ghostty_surface_foreground_pid(surface)) }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/cmdline")),
              let argv = CommandRestore.parseProcCmdline(data) else { return nil }
        return argv
    }
}
