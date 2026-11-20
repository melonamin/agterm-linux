import Foundation
import Glibc
import Testing
@testable import AgtermLinux

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var all: [String] { lock.withLock { stored } }

    func append(_ line: String) {
        lock.withLock { stored.append(line) }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int { lock.withLock { stored } }

    func increment() {
        lock.withLock { stored += 1 }
    }
}

private struct Record {
    let storage: GhosttySurfaceConfigurationStorage?
    let configs: [Int]
}

@Suite("surface quarantine")
struct LinuxSurfaceQuarantineTests {
    private let key: UInt = 0xDEAD_0000

    @Test("insertion is idempotent and a key is never dereferenced")
    func idempotentInsert() {
        let quarantine = LinuxSurfaceQuarantine<String>(log: { _ in })

        quarantine.insert("first", key: key)
        quarantine.insert("second", key: key)

        #expect(quarantine.count == 1)
        #expect(quarantine.contains(key))
        #expect(!quarantine.contains(key + 1))
    }

    @Test("each dropped kind logs once with the prefix")
    func droppedOnce() {
        let lines = Lines()
        let quarantine = LinuxSurfaceQuarantine<String>(log: lines.append)

        quarantine.dropped("MOUSE_SHAPE")
        quarantine.dropped("MOUSE_SHAPE")
        quarantine.dropped("SET_TITLE")

        #expect(lines.all == ["agterm: retained GL context: dropped MOUSE_SHAPE", "agterm: retained GL context: dropped SET_TITLE"])
    }

    @Test("an entry check logs only for a quarantined key")
    func entryCheck() {
        let lines = Lines()
        let quarantine = LinuxSurfaceQuarantine<String>(log: lines.append)

        #expect(!quarantine.drops(key, kind: "close"))
        #expect(lines.all.isEmpty)

        quarantine.insert("record", key: key)

        #expect(quarantine.drops(key, kind: "close"))
        #expect(lines.all == ["agterm: retained GL context: dropped close"])
    }

    @Test("a write prompt quarantined while shown writes nothing on Allow")
    func writePrompt() {
        let lines = Lines()
        let quarantine = LinuxSurfaceQuarantine<String>(log: lines.append)
        var writes = 0
        let answer = quarantine.writeAnswer(key: key) { writes += 1 }

        quarantine.insert("record", key: key)
        answer(true)

        #expect(writes == 0)
        #expect(lines.all == ["agterm: retained GL context: dropped clipboard write"])
    }

    @Test("a live write prompt writes on Allow only")
    func liveWritePrompt() {
        let quarantine = LinuxSurfaceQuarantine<String>(log: { _ in })
        var writes = 0
        let answer = quarantine.writeAnswer(key: key) { writes += 1 }

        answer(false)
        #expect(writes == 0)

        answer(true)
        #expect(writes == 1)
    }

    @Test("a close hop queued before quarantine runs no exit capture and no onExit")
    func closeHop() {
        let quarantine = LinuxSurfaceQuarantine<String>(log: { _ in })
        let exits = Counter()
        let hop = quarantine.exitHop(key: key) { exits.increment() }

        quarantine.insert("record", key: key)
        hop()

        #expect(exits.value == 0)
    }

    @Test("a close hop for a live surface runs")
    func liveCloseHop() {
        let quarantine = LinuxSurfaceQuarantine<String>(log: { _ in })
        let exits = Counter()

        quarantine.exitHop(key: key) { exits.increment() }()

        #expect(exits.value == 1)
    }

    @Test("configuration storage moves to the record and the release lines find nothing")
    func storageTransfer() throws {
        var deallocations = 0
        let quarantine = LinuxSurfaceQuarantine<Record>(log: { _ in })
        var storage = GhosttySurfaceConfigurationStorage(
            workingDirectory: "/tmp", command: "true", initialInput: nil, environment: ["A": "B"],
            deallocate: { pointer in
                deallocations += 1
                free(pointer)
            })
        let transferred = try #require(storage)
        var configs = [1, 2]
        var freedConfigs = 0

        quarantine.transfer(key: key, storage: &storage, configs: &configs) { Record(storage: $0, configs: $1) }
        configs.forEach { _ in freedConfigs += 1 }
        configs = []
        storage?.release()
        storage = nil

        #expect(deallocations == 0)
        #expect(freedConfigs == 0)
        #expect(!transferred.isReleased)

        quarantine.transfer(key: key, storage: &storage, configs: &configs) { Record(storage: $0, configs: $1) }

        #expect(quarantine.count == 1)
        #expect(deallocations == 0)
    }
}
