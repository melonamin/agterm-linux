import Foundation
import agtermCore

@MainActor var gHooks: LinuxHooks?

/// GTK's main loop owns hook state; the shared scheduler owns ordering and queue limits.
@MainActor
final class LinuxHooks {
    private let scheduler = HookScheduler(launcher: LinuxHookLauncher())
    private var diagnostics: [KeymapDiagnostic] = []
    private var path: URL

    init(library: WindowLibrary, configDirectory: URL) {
        path = ConfigPaths.hooksPath(configDirectory: configDirectory)
        scheduler.onFailure = { entry, detail in
            gController?.showToast("Hook \(entry.kind.rawValue) failed: \(detail)")
        }
        library.onControlEvent = { [scheduler] event in scheduler.dispatch(event) }
        reload(configDirectory: configDirectory)
    }

    @discardableResult
    func reload(configDirectory: URL) -> Int {
        path = ConfigPaths.hooksPath(configDirectory: configDirectory)
        do {
            let parsed = parseHooksConf(try String(contentsOf: path, encoding: .utf8))
            diagnostics = parsed.diagnostics
            scheduler.apply(parsed.hooks)
        } catch {
            diagnostics = FileManager.default.fileExists(atPath: path.path)
                ? [KeymapDiagnostic(line: 0, message: "could not read hooks.conf: \(error.localizedDescription)")]
                : []
            scheduler.apply(Hooks())
        }
        return diagnostics.count
    }

    func list() -> ControlHooks {
        ControlHooks(path: path.path,
                     diagnostics: diagnostics.map { ControlKeymapDiagnostic(line: $0.line, message: $0.message) },
                     hooks: scheduler.status)
    }
}

@MainActor
extension AppController {
    func reloadHooks() -> ControlResponse {
        guard let hooks = gHooks else { return err("hooks are unavailable") }
        let count = hooks.reload(configDirectory: configDirectory())
        return ControlResponse(ok: true, result: ControlResult(count: count))
    }

    func listHooks() -> ControlResponse {
        guard let hooks = gHooks else { return err("hooks are unavailable") }
        return ControlResponse(ok: true, result: ControlResult(hooks: hooks.list()))
    }
}

/// Launch one shell per event and finish on GLib's main thread after stdin closes and the child exits.
/// The control server ignores SIGPIPE, so a hook exiting before reading yields EPIPE to the writer.
@MainActor
private final class LinuxHookLauncher: HookLauncher {
    func launch(entry: HookEntry, event: ControlEvent,
                onDeliveryFailure: @escaping @MainActor @Sendable (String) -> Void,
                onExit: @escaping @MainActor @Sendable (Int32) -> Void) throws -> Int32 {
        var environment = gdkEnvironment.restoringChildEnvironment(ProcessInfo.processInfo.environment)
        environment["AGT_EVENT_KIND"] = event.kind.rawValue
        environment["AGT_EVENT_STATUS"] = event.payload.status ?? ""
        environment["AGT_EVENT_HOST"] = event.payload.host ?? ""
        environment["AGT_SESSION_ID"] = event.session ?? ""
        environment["AGT_WORKSPACE_ID"] = event.workspace ?? ""
        environment["AGT_WINDOW_ID"] = event.window ?? ""
        environment["AGT_SOCKET"] = gControlServer.resolvedSocketPath
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path
        environment["PATH"] = CommandPath.widened(environment["PATH"], bundledCLIDirectory: executableDirectory)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", entry.command]
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let data = try JSONEncoder().encode(event) + Data("\n".utf8)
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EPIPE) {
                // A hook may exit without reading its event; its exit status is the outcome.
            } catch {
                let detail = error.localizedDescription
                runOnMain { MainActor.assumeIsolated { onDeliveryFailure(detail) } }
            }
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            let status = process.terminationStatus
            runOnMain { MainActor.assumeIsolated { onExit(status) } }
        }
        return process.processIdentifier
    }
}
