import CGtk
import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@MainActor
@Suite(.serialized)
struct LinuxPageChannelTests {
    @Test func chunkedResourceUsesAPrivateSpoolAndRemovesItAfterDelivery() throws {
        let first = Data(repeating: 120, count: PageServeCodec.maxChunkBytes)
        let second = Data(repeating: 121, count: PageServeCodec.maxChunkBytes)
        let frames: [PageServeFrame] = [.head(id: 1, mimeType: "text/plain"), .chunk(id: 1, data: first),
                                         .chunk(id: 1, data: second), .end(id: 1)]
        let encoded = try frames.map { CommandRestore.shellQuotedLine([String(decoding: try PageServeCodec.encode($0), as: UTF8.self)]) }
        let script = "IFS= read -r request\nprintf '%s' " + encoded.joined(separator: " ") + "\nIFS= read -r ignored\n"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("helper.sh")
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        let channel = LinuxPageChannel()
        defer { channel.onClose = nil; channel.close() }
        var received: Data?, path: String?, mode: Int?
        channel.start(["/bin/sh", fixture.path])
        channel.fetch("/origin/page.txt") { result in
            guard case .success(let resource) = result else { return }
            received = try? Data(contentsOf: URL(fileURLWithPath: resource.path))
            mode = (try? FileManager.default.attributesOfItem(atPath: resource.path)[.posixPermissions] as? NSNumber)?.intValue
            path = resource.path
            #expect(resource.mime == "text/plain")
        }
        pump(until: { received != nil })
        #expect(received == first + second)
        #expect(mode == 0o600)
        if let path { #expect(!FileManager.default.fileExists(atPath: path)) }
    }

    @Test func helperEOFClosesTheChannelAndPendingRequests() {
        let channel = LinuxPageChannel()
        var closed = false, refused = false
        channel.onClose = { closed = true }
        channel.fetch("/origin/missing") { if case .failure = $0 { refused = true } }
        channel.start(["/bin/sh", "-c", "exit 0"])
        pump(until: { closed })
        #expect(closed)
        #expect(refused)
        channel.close()
    }

    @Test func cancellingAPartialResourceKeepsTheChannelUsable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready"), fixture = root.appendingPathComponent("helper.sh")
        func emit(_ frame: PageServeFrame) throws -> String {
            CommandRestore.shellQuotedLine(["printf", "%s", String(decoding: try PageServeCodec.encode(frame), as: UTF8.self)])
        }
        let script = try [
            "IFS= read -r request", emit(.head(id: 1, mimeType: "text/plain")),
            emit(.chunk(id: 1, data: Data("partial".utf8))), CommandRestore.shellQuotedLine(["touch", ready.path]),
            "IFS= read -r cancel", "case \"$cancel\" in *'\"kind\":\"cancel\"'*) ;; *) exit 3;; esac",
            emit(.failure(id: 1, error: PageServeFrame.cancelled)), "IFS= read -r request",
            emit(.head(id: 2, mimeType: "text/plain")), emit(.chunk(id: 2, data: Data("replacement".utf8))),
            emit(.end(id: 2)), "IFS= read -r ignored",
        ].joined(separator: "\n") + "\n"
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        let channel = LinuxPageChannel()
        defer { channel.close() }
        var cancelled = 0, body: String?
        channel.start(["/bin/sh", fixture.path])
        channel.fetch("/origin/partial") { if case .failure = $0 { cancelled += 1 } }
        pump(until: { FileManager.default.fileExists(atPath: ready.path) })
        #expect(FileManager.default.fileExists(atPath: ready.path))
        channel.cancelResources()
        channel.fetch("/origin/replacement") {
            if case .success(let resource) = $0 { body = try? String(contentsOfFile: resource.path, encoding: .utf8) }
        }
        pump(until: { body != nil })
        #expect(cancelled == 1)
        #expect(body == "replacement")
    }

    private func pump(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        while !done(), Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            usleep(1_000)
        }
    }
}
