import Foundation
import agtermCore

@MainActor
enum LinuxAttachedRestore {
    static var checking = Set<String>()
    static var pageClaims = Set<UUID>()
    static var pageRefusals = Set<UUID>()

    static func checkTerminals() {
        let rows = gWindows.values.flatMap { $0.store.workspaces.flatMap(\.sessions) }
            .filter { $0.awaitsOriginCheck && $0.content == .terminal && !$0.ended }
        for host in Set(rows.compactMap(\.remoteHost)) where checking.insert(host).inserted {
            guard let argv = try? RemoteSession.treeCommand(host: host) else { checking.remove(host); continue }
            LinuxRemoteCatalog.run(argv) { result in
                guard let tree = (try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)))?.result?.remote else {
                    return retry(host)
                }
                let listed = Set(tree.sessions.map { $0.id.lowercased() })
                guard rows.contains(where: { $0.remoteHost == host && !listed.contains(($0.remoteSessionID ?? "").lowercased()) }),
                      let command = try? RemoteSession.controlCommand(host: host, arguments: ["zmx", "list"]) else {
                    return settle(host, listed: listed, inventory: nil)
                }
                LinuxRemoteCatalog.run(command) { result in
                    let inventory = (try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)))?.result?.zmx
                    settle(host, listed: listed, inventory: inventory)
                }
            }
        }
    }

    private static func settle(_ host: String, listed: Set<String>, inventory: ControlZmxInventory?) {
        let claimed = inventory?.inventoryComplete == true ? Set(inventory!.entries.compactMap { $0.sessionID?.lowercased() }) : nil
        var waiting = false
        for controller in gWindows.values {
            for row in controller.store.workspaces.flatMap(\.sessions)
                where row.awaitsOriginCheck && row.content == .terminal && row.remoteHost == host {
                let origin = (row.remoteSessionID ?? "").lowercased()
                if listed.contains(origin) || claimed?.contains(origin) == true {
                    row.awaitsOriginCheck = false
                } else if claimed != nil {
                    controller.store.closeEndedAttachedRow(row.id)
                } else { waiting = true }
            }
            controller.reconcile(focusActive: false)
        }
        if waiting { retry(host) } else { checking.remove(host) }
    }

    private static func retry(_ host: String) {
        MainTimer.schedule(after: 3) {
            checking.remove(host)
            checkTerminals()
        }
    }
}

@MainActor
extension AppController {
    func syncRemotePageRows() {
        for row in store.workspaces.flatMap(\.sessions) where row.content == .page && row.remoteHost != nil {
            let catalog = row.remotePresentation?.binding.catalogOwned == true
            guard row.awaitsOriginCheck || (catalog && (!row.overlayActive || row.htmlOverlay?.source.kind == .unreadable)),
                  !LinuxAttachedRestore.pageRefusals.contains(row.id),
                  LinuxAttachedRestore.pageClaims.insert(row.id).inserted,
                  let host = row.remoteHost, let origin = row.remotePresentation?.binding.remoteSessionID,
                  let argv = try? RemoteSession.controlCommand(host: host,
                    arguments: ["session", "overlay", "page-attach", "--target", origin]) else { continue }
            let id = row.id
            LinuxRemoteCatalog.run(argv) { [weak self, weak row] result in
                guard let self, let row, self.store.session(withID: id) === row else {
                    LinuxAttachedRestore.pageClaims.remove(id)
                    return
                }
                guard let response = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
                    if catalog { store.showCatalogPageRefusal("waiting for \(host)", inRow: id) }
                    MainTimer.schedule(after: 3) { [weak self] in
                        LinuxAttachedRestore.pageClaims.remove(id)
                        self?.syncRemotePageRows()
                    }
                    return
                }
                LinuxAttachedRestore.pageClaims.remove(id)
                guard response.ok, let page = response.result?.companionPage else {
                    row.awaitsOriginCheck = false
                    LinuxAttachedRestore.pageRefusals.insert(id)
                    if catalog { store.showCatalogPageRefusal(response.error ?? "the origin refused this page", inRow: id) } else {
                        store.setRemoteConnection(.failed(response.error ?? "the origin refused this page"), forSession: id)
                    }
                    return
                }
                let placed = placeRemotePage(page, host: host, originSession: origin,
                                             placement: catalog ? .catalog(id) : .existing(id), select: false)
                if !placed.ok, catalog { store.showCatalogPageRefusal(placed.error ?? "the page cannot be shown", inRow: id) }
            }
        }
    }
}
