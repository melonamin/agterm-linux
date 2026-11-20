import Foundation
import agtermCore

/// Routes host-free spawn-pacer grants back to GTK surfaces without retaining closed panes.
@MainActor
final class LinuxSpawnRegistry {
    let pacer = SpawnPacer(mainTimer: MainTimer.self)
    private struct Entry { weak var surface: GhosttySurface? }
    private var entries: [UUID: Entry] = [:]

    init() {
        pacer.onGrant = { [weak self] key in self?.grant(key) }
    }

    func enqueue(_ surface: GhosttySurface, key: UUID, shouldPace: Bool) {
        guard shouldPace else {
            pacer.discard(key)
            return
        }
        entries[key] = Entry(surface: surface)
        surface.useSpawnPacer(pacer, key: key)
    }

    private func grant(_ key: UUID) {
        guard let surface = entries.removeValue(forKey: key)?.surface,
              surface.awaitingSpawnPermit else { return }
        surface.resumePacedSpawn()
    }

    func prioritize(_ surfaces: [GhosttySurface]) {
        pacer.prioritize(surfaces.compactMap(\.spawnKey))
    }

    func cancel(_ key: UUID) {
        entries[key] = nil
        pacer.cancel(key)
    }
}

@MainActor let gSpawnRegistry = LinuxSpawnRegistry()
