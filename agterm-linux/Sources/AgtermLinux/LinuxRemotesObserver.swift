import CGtk
import Foundation
import agtermCore

/// Watch the file and its nearest directory so atomic saves and initially absent files are observed.
@MainActor
final class LinuxRemotesObserver {
    static let shared = LinuxRemotesObserver()
    private var url: URL?
    private var monitors: [URL: OpaquePointer] = [:]
    private var issues = 0
    private let debounce = Debouncer()

    func watch(_ url: URL) {
        guard self.url != url else { return }
        self.url = url
        issues = (try? RemotesFile.load(at: url).diagnostics.count) ?? 1
        arm()
    }

    func changed() {
        debounce.schedule(after: 0.1) { [weak self] in
            guard let self, let url = self.url else { return }
            let count = (try? RemotesFile.load(at: url).diagnostics.count) ?? 1
            if self.issues == 0, count > 0 {
                NotificationManager.send(title: "Attach Remote", body: "\(count) issue\(count == 1 ? "" : "s") in remotes.conf")
            }
            self.issues = count
            self.arm()
            for controller in gWindows.values { controller.refreshPaletteContents() }
        }
    }

    private func arm() {
        guard let url else { return }
        var paths: Set<URL> = [url, nearestDirectory(url)]
        let resolved = url.resolvingSymlinksInPath()
        paths.insert(resolved)
        paths.insert(nearestDirectory(resolved))
        // Keep directory watches armed across refreshes; replacing them can miss a rapid follow-up save.
        for (path, monitor) in Array(monitors) {
            let directory = (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if paths.contains(path), directory { continue }
            g_file_monitor_cancel(cast(monitor))
            g_object_unref(RAW(monitor))
            monitors[path] = nil
        }
        for path in paths {
            guard monitors[path] == nil else { continue }
            let file = g_file_new_for_path(path.path)
            defer { g_object_unref(RAW(file)) }
            guard let pointer = g_file_monitor(file, agterm_file_monitor_watch_moves(), nil, nil) else { continue }
            let monitor = OpaquePointer(pointer)
            monitors[path] = monitor
            connect(monitor, "changed", unsafeBitCast(onRemotesFileChanged, to: GCallback.self))
        }
    }

    private func nearestDirectory(_ url: URL) -> URL {
        var parent = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
            parent.deleteLastPathComponent()
        }
        return parent
    }
}

private let onRemotesFileChanged: @MainActor @convention(c)
    (OpaquePointer?, OpaquePointer?, OpaquePointer?, GFileMonitorEvent, gpointer?) -> Void = { _, _, _, _, _ in
        LinuxRemotesObserver.shared.changed()
    }
