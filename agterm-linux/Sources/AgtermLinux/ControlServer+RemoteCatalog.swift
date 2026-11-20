import Foundation
import agtermCore

private final class LinuxCatalogResponse: @unchecked Sendable {
    var response: ControlResponse?
}

extension ControlServer {
    /// Runs on a socket/file-page worker. The worker waits for the reply while GTK keeps draining its main loop.
    func performCatalogRequest(_ request: ControlRequest) -> ControlResponse? {
        if request.cmd == .windowRemoteOpen { return openRemoteCatalog(request) }
        if request.cmd == .sessionRemoteNew { return createRemoteSession(request) }
        let commands: Set<Command> = RemoteOperation.structuralCommands.union([
            .sessionDetach, .sessionReattach, .workspaceDetach, .workspaceReattach, .windowRemoteDismiss,
            .recentList, .recentClear, .recentOpen, .sessionUndo,
        ])
        guard commands.contains(request.cmd) else { return nil }
        let box = LinuxCatalogResponse(), ready = DispatchSemaphore(value: 0)
        runOnMain {
            MainActor.assumeIsolated {
                guard case .controller(let controller?) = Self.route(for: request),
                      let catalog = LinuxRemoteCatalogs.windows[controller.windowID] else { ready.signal(); return }
                if RemoteOperation.structuralCommands.contains(request.cmd), RemoteOperation.runsLocally(request, in: controller.store) {
                    ready.signal(); return
                }
                self.runCatalogRequest(request, controller: controller, catalog: catalog) { response in
                    box.response = response
                    ready.signal()
                }
            }
        }
        ready.wait()
        return box.response
    }

    @MainActor
    private func runCatalogRequest(_ request: ControlRequest, controller: AppController, catalog: LinuxRemoteCatalog,
                                   completion: @escaping @MainActor (ControlResponse) -> Void) {
        let mirror = catalog.mirror
        switch request.cmd {
        case .windowRemoteDismiss:
            catalog.actions.dismissUnknown()
            completion(controller.ok())
        case .sessionDetach, .workspaceDetach:
            if request.cmd == .sessionDetach {
                switch controller.resolveSessionResponse(request.target) {
                case .failure(let response): completion(response)
                case .success(let id): mirror.detach(sessions: [id]); completion(controller.ok(id))
                }
            } else {
                switch controller.resolveWorkspaceResponse(request.target) {
                case .failure(let response): completion(response)
                case .success(let id): mirror.detach(workspace: id); completion(controller.ok(id))
                }
            }
        case .sessionReattach, .workspaceReattach:
            let workspace = request.cmd == .workspaceReattach
            let candidates = mirror.detachedItems.filter { ($0.kind == .workspace) == workspace }.map(\.id)
            switch ControlResolve.resolve(request.target ?? "", candidates: candidates, active: nil) {
            case .resolved(let id):
                let error = workspace ? mirror.reattach(workspace: id) : mirror.reattach(session: id)
                completion(error.map(controller.err) ?? controller.ok(id))
            case .ambiguous(let ids):
                completion(controller.err(ControlResolve.ambiguousMessage(noun: workspace ? "workspace" : "session",
                                                                          target: request.target ?? "", hits: ids)))
            case .notFound: completion(controller.err("no such detached \(workspace ? "workspace" : "session")"))
            }
        case .recentList where catalog.actions.recentItems != nil:
            completion(ControlResponse(ok: true, result: ControlResult(recent: catalog.actions.recentItems)))
        case .sessionUndo, .recentOpen, .recentClear:
            let operation: RemoteOperation
            if request.cmd == .sessionUndo {
                guard let id = request.target, !id.isEmpty else { return completion(controller.err("session.undo requires --target with the undo id a close answered")) }
                operation = .undoClose(id)
            } else { operation = request.cmd == .recentOpen ? .reopenRecent(request.target) : .clearRecent }
            switch catalog.actions.prepare(operation) {
            case .refused(let response): completion(response)
            case .ready(let prepared): catalog.actions.send(prepared, launch: catalog.runPooled, completion: completion)
            }
        case .recentList:
            guard let argv = try? RemoteSession.controlCommand(host: catalog.host, arguments: ["recent", "list"]) else {
                return completion(controller.err("invalid host"))
            }
            LinuxRemoteCatalog.run(argv) { result in
                completion((try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)))
                    ?? ControlResponse(ok: false, error: "the origin did not answer"))
            }
        default: catalog.perform(request, completion: completion)
        }
    }

    private func openRemoteCatalog(_ request: ControlRequest) -> ControlResponse {
        guard let host = request.args?.host, (try? RemoteSession.treeCommand(host: host)) != nil else {
            return ControlResponse(ok: false, error: "window.remote.open requires a valid host")
        }
        let choice: Result<ControlWindowNode?, LinuxOriginError>
        switch remoteOrigin(host: host, requested: request.args?.originWindow) {
        case .failure(let failure): return ControlResponse(ok: false, error: failure.message)
        case .success(let value): choice = .success(value)
        }
        guard case .success(let origin) = choice else { return ControlResponse(ok: false, error: "no origin window") }
        return companionOnMain {
            let info = gLibrary.newRemoteWindow(host: host, originWindow: origin.flatMap { UUID(uuidString: $0.id) }, originName: origin?.name)
            openWindow(info.id)
            return ControlResponse(ok: true, result: ControlResult(id: info.id.uuidString))
        }
    }

    /// A headless host has no origin window; a GUI host chooses one explicitly or through the native picker.
    private func remoteOrigin(host: String, requested: String?) -> Result<ControlWindowNode?, LinuxOriginError> {
        guard let argv = try? RemoteSession.controlCommand(host: host, arguments: ["version"]) else {
            return .failure(.init(message: "invalid host"))
        }
        let result = LinuxRemoteCommand.run(argv, deadline: 8)
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)), reply.ok else {
            return .failure(.init(message: "\(host) did not answer"))
        }
        switch RemoteSessionCreate.originKind(reply.result, host: host) {
        case .failure(let refusal): return .failure(.init(message: refusal.message))
        case .success(.server):
            return requested == nil ? .success(nil) : .failure(.init(message: "\(host) runs agterm-server, which has no windows to name"))
        case .success(.mac): break
        }
        guard let argv = try? RemoteSession.controlCommand(host: host, arguments: ["window", "list"]) else {
            return .failure(.init(message: "invalid host"))
        }
        let windowsResult = LinuxRemoteCommand.run(argv, deadline: 8)
        let windows = (try? JSONDecoder().decode(ControlResponse.self, from: Data(windowsResult.stdout.utf8)))?.result?.windows ?? []
        return RemoteOriginWindow.choose(host: host, windows: windows, requested: requested)
            .map(Optional.some).mapError { .init(message: $0.message) }
    }

    private func createRemoteSession(_ request: ControlRequest) -> ControlResponse {
        let create: RemoteSessionCreate
        switch RemoteSessionCreate.parse(request) {
        case .failure(let failure): return ControlResponse(ok: false, error: failure.message)
        case .success(let value): create = value
        }
        let destination = LinuxRemoteDestination()
        let checked = companionOnMain {
            guard case .controller(let controller?) = Self.route(for: request), !controller.store.isRemoteWindow,
                  let workspace = controller.store.currentWorkspaceID,
                  let name = controller.store.workspaces.first(where: { $0.id == workspace })?.name else {
                return ControlResponse(ok: false, error: "no local workspace to attach into")
            }
            destination.window = controller.windowID
            destination.workspace = workspace
            destination.name = name
            return controller.ok()
        }
        guard checked.ok, let window = destination.window, let workspace = destination.workspace else { return checked }
        let origin: RemoteSessionCreate.Origin
        switch remoteOrigin(host: create.host, requested: create.originWindow) {
        case .failure(let refusal): return ControlResponse(ok: false, error: refusal.message)
        case .success(let node): origin = node.map { .mac(window: $0.id) } ?? .server
        }
        guard let argv = try? RemoteSession.controlCommand(host: create.host,
            arguments: create.arguments(origin: origin, workspaceName: create.workspaceName ?? destination.name)) else {
            return ControlResponse(ok: false, error: "invalid host")
        }
        let result = LinuxRemoteCommand.run(argv, deadline: 8)
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
            return ControlResponse(ok: false, error: "\(create.host) gave no answer; whether the session was created is unknown")
        }
        guard reply.ok, let id = reply.result?.id else { return reply }
        guard let argv = try? RemoteSession.treeCommand(host: create.host) else { return reply }
        let deadline = Date().addingTimeInterval(20)
        repeat {
            let result = LinuxRemoteCommand.run(argv, deadline: 8)
            if let tree = (try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)))?.result?.remote,
               tree.sessions.contains(where: { $0.id == id }) {
                return companionOnMain {
                    guard let controller = gWindows[window], controller.store.workspaces.contains(where: { $0.id == workspace }) else {
                        return ControlResponse(ok: false, error: "the destination workspace closed; the session remains on \(create.host)")
                    }
                    return controller.attachRemoteSession(host: create.host, session: id, tree: tree, placementWorkspace: workspace)
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return ControlResponse(ok: false, error: "session \(id) was created on \(create.host), but could not be attached")
    }
}

private final class LinuxRemoteDestination: @unchecked Sendable {
    var window: UUID?
    var workspace: UUID?
    var name = ""
}

private struct LinuxOriginError: Error {
    let message: String
}
