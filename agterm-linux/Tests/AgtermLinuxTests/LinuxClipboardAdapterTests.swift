import CGtk
import Foundation
import Testing
@testable import AgtermLinux

private struct RawItem {
    let mime: String?
    let data: [UInt8]?
}

/// Lends `raw` the way libghostty does: every pointer dies when `body` returns.
private func withContents<R>(_ raw: [RawItem], _ body: (UnsafeBufferPointer<ghostty_clipboard_content_s>) -> R) -> R {
    let mimes = raw.map { $0.mime.flatMap { strdup($0) } }
    let buffers = raw.map { item in
        item.data.map { bytes in
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: max(bytes.count, 1))
            for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
            return buffer
        }
    }
    defer {
        mimes.forEach { free($0) }
        buffers.forEach { $0?.deallocate() }
    }
    let contents = raw.indices.map { index in
        ghostty_clipboard_content_s(mime: UnsafePointer(mimes[index]), data: UnsafePointer(buffers[index]),
                                    len: raw[index].data?.count ?? 0)
    }
    return contents.withUnsafeBufferPointer(body)
}

private func withMimes<R>(_ raw: [String?], _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) -> R) -> R {
    let copies = raw.map { $0.flatMap { strdup($0) } }
    defer { copies.forEach { free($0) } }
    return copies.map { UnsafePointer($0) }.withUnsafeBufferPointer(body)
}

/// Stands in for the engine's complete and deny entry points. Copies inside the call: the adapter frees
/// every pointer as soon as `complete` returns.
private final class EngineStandIn {
    struct Delivery: Equatable {
        let surface: ghostty_surface_t
        let state: UnsafeMutableRawPointer?
        let items: [ClipboardItem]
        let available: [String]
        let confirmed: Bool
        let remember: Bool
    }

    struct Denial: Equatable {
        let surface: ghostty_surface_t
        let state: UnsafeMutableRawPointer?
    }

    private(set) var deliveries: [Delivery] = []
    private(set) var denials: [Denial] = []

    func complete(_ surface: ghostty_surface_t, _ payload: UnsafePointer<ghostty_clipboard_complete_s>,
                  _ state: UnsafeMutableRawPointer?) {
        let completion = payload.pointee
        // a nil `data` drops the item, because the engine would slice it as non-null
        let items = UnsafeBufferPointer(start: completion.contents, count: completion.contents_len).compactMap { item -> ClipboardItem? in
            guard let mime = item.mime, let data = item.data else { return nil }
            return ClipboardItem(mime: String(cString: mime), data: Data(bytes: data, count: item.len))
        }
        let available = UnsafeBufferPointer(start: completion.available, count: completion.available_len).compactMap {
            $0.map { String(cString: $0) }
        }
        deliveries.append(Delivery(surface: surface, state: state, items: items, available: available,
                                   confirmed: completion.confirmed, remember: completion.remember))
    }

    func deny(_ surface: ghostty_surface_t, _ state: UnsafeMutableRawPointer?) {
        denials.append(Denial(surface: surface, state: state))
    }
}

@Suite("Linux clipboard adapter")
struct LinuxClipboardAdapterTests {
    private let surface = UnsafeMutableRawPointer(bitPattern: 0x100)!
    private let state = UnsafeMutableRawPointer(bitPattern: 0x200)
    private let binary: [UInt8] = [0x89, 0x00, 0xFF, 0x00]
    private let items = [
        ClipboardItem(mime: "text/plain", data: Data("café".utf8)),
        ClipboardItem(mime: "image/png", data: Data([0x89, 0x00, 0xFF, 0x00])),
        ClipboardItem(mime: "application/x-empty", data: Data()),
    ]

    @Test("items keep text and NUL-bearing binary bytes to their explicit length")
    func copiesBytes() {
        let copied = withContents([
            RawItem(mime: "text/plain", data: Array("café".utf8)),
            RawItem(mime: "image/png", data: binary),
        ]) { LinuxClipboardAdapter.copyItems($0.baseAddress, count: $0.count) }

        #expect(copied == [items[0], items[1]])
    }

    @Test("a zero-length item and a nil-data item stay, a nil-MIME item goes")
    func copiesEdgeItems() {
        let copied = withContents([
            RawItem(mime: "application/x-empty", data: []),
            RawItem(mime: "application/x-absent", data: nil),
            RawItem(mime: nil, data: binary),
            RawItem(mime: "image/png", data: binary),
        ]) { LinuxClipboardAdapter.copyItems($0.baseAddress, count: $0.count) }

        #expect(copied == [
            ClipboardItem(mime: "application/x-empty", data: Data()),
            ClipboardItem(mime: "application/x-absent", data: Data()),
            items[1],
        ])
    }

    @Test("a copied item outlives a rewrite of the borrowed bytes")
    func copiesAreOwned() {
        let copied = withContents([RawItem(mime: "image/png", data: binary)]) { contents in
            let copy = LinuxClipboardAdapter.copyItems(contents.baseAddress, count: contents.count)
            UnsafeMutablePointer(mutating: contents[0].data!).initialize(repeating: 0x21, count: contents[0].len)
            return copy
        }

        #expect(copied == [items[1]])
    }

    @Test("a nil array copies to nothing whatever the count says")
    func nilArrays() {
        #expect(LinuxClipboardAdapter.copyItems(nil, count: 3).isEmpty)
        #expect(LinuxClipboardAdapter.copyMimes(nil, count: 3).isEmpty)
    }

    @Test("MIME copies skip nil entries")
    func copiesMimes() {
        let copied = withMimes(["text/plain", nil, "image/png"]) { LinuxClipboardAdapter.copyMimes($0.baseAddress, count: $0.count) }

        #expect(copied == ["text/plain", "image/png"])
    }

    @Test("a confirmation with no items and no listing copies empty")
    func emptyConfirmation() {
        let confirm = ghostty_clipboard_confirm_s(contents: nil, contents_len: 0, available: nil, available_len: 0,
                                                  name: nil, can_remember: false)

        #expect(LinuxClipboardAdapter.copyConfirmation(confirm) == ClipboardConfirmation(items: [], available: []))
    }

    @Test("a confirmation with one item and no listing copies the item")
    func singleItemConfirmation() {
        let copied = withContents([RawItem(mime: "text/plain", data: Array("café".utf8))]) { contents in
            LinuxClipboardAdapter.copyConfirmation(ghostty_clipboard_confirm_s(
                contents: contents.baseAddress, contents_len: contents.count, available: nil, available_len: 0,
                name: nil, can_remember: false))
        }

        #expect(copied == ClipboardConfirmation(items: [items[0]], available: []))
    }

    @Test("a confirmation with several items copies them and its listing in order")
    func severalItemConfirmation() {
        let available = ["text/plain", "image/png"]
        let copied = withContents([
            RawItem(mime: "text/plain", data: Array("café".utf8)),
            RawItem(mime: "image/png", data: binary),
            RawItem(mime: "application/x-empty", data: []),
        ]) { contents in
            withMimes(available) { mimes in
                LinuxClipboardAdapter.copyConfirmation(ghostty_clipboard_confirm_s(
                    contents: contents.baseAddress, contents_len: contents.count,
                    available: mimes.baseAddress, available_len: mimes.count, name: nil, can_remember: false))
            }
        }

        #expect(copied == ClipboardConfirmation(items: items, available: available))
    }

    @Test("every engine request kind maps, and an unknown one is a paste")
    func requestKinds() {
        #expect(LinuxClipboardAdapter.requestKind(GHOSTTY_CLIPBOARD_REQUEST_PASTE) == .paste)
        #expect(LinuxClipboardAdapter.requestKind(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ) == .osc52Read)
        #expect(LinuxClipboardAdapter.requestKind(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE) == .osc52Write)
        #expect(LinuxClipboardAdapter.requestKind(GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ) == .kittyRead)
        #expect(LinuxClipboardAdapter.requestKind(GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE) == .kittyWrite)
        #expect(LinuxClipboardAdapter.requestKind(GHOSTTY_CLIPBOARD_REQUEST_LIST) == .list)
        #expect(LinuxClipboardAdapter.requestKind(ghostty_clipboard_request_e(rawValue: 99)) == .paste)
    }

    @Test("complete delivers every item, the listing and the confirmation to the engine")
    func completeRoundTrip() {
        let engine = EngineStandIn()

        LinuxClipboardAdapter.complete(surface, items: items, available: ["text/plain", "image/png"], state: state,
                                       confirmed: true, using: engine.complete)

        #expect(engine.deliveries == [EngineStandIn.Delivery(
            surface: surface, state: state, items: items, available: ["text/plain", "image/png"],
            confirmed: true, remember: false)])
    }

    @Test("a listing-only completion is unconfirmed and carries no items")
    func completeListing() {
        let engine = EngineStandIn()

        LinuxClipboardAdapter.complete(surface, items: [], available: ["text/plain"], state: state, using: engine.complete)

        #expect(engine.deliveries == [EngineStandIn.Delivery(
            surface: surface, state: state, items: [], available: ["text/plain"], confirmed: false, remember: false)])
    }

    @Test("a surface closed under the prompt calls neither complete nor deny", arguments: [true, false])
    func closedSurfaceResolution(allowed: Bool) {
        let engine = EngineStandIn()
        var live: ghostty_surface_t? = surface
        let answer = LinuxClipboardAdapter.confirmationAnswer(liveSurface: { live },
                                                              payload: ClipboardConfirmation(items: items, available: []), state: state,
                                                              complete: engine.complete, deny: engine.deny)

        live = nil
        answer(allowed)

        #expect(engine.deliveries.isEmpty)
        #expect(engine.denials.isEmpty)
    }

    @Test("an allowed prompt completes the payload as confirmed")
    func allowedResolution() {
        let engine = EngineStandIn()
        let answer = LinuxClipboardAdapter.confirmationAnswer(liveSurface: { surface },
                                                              payload: ClipboardConfirmation(items: items, available: ["text/plain"]), state: state,
                                                              complete: engine.complete, deny: engine.deny)

        answer(true)

        #expect(engine.deliveries == [EngineStandIn.Delivery(
            surface: surface, state: state, items: items, available: ["text/plain"], confirmed: true, remember: false)])
        #expect(engine.denials.isEmpty)
    }

    @Test("a refused prompt denies and completes nothing")
    func refusedResolution() {
        let engine = EngineStandIn()
        let answer = LinuxClipboardAdapter.confirmationAnswer(liveSurface: { surface },
                                                              payload: ClipboardConfirmation(items: items, available: []), state: state,
                                                              complete: engine.complete, deny: engine.deny)

        answer(false)

        #expect(engine.denials == [EngineStandIn.Denial(surface: surface, state: state)])
        #expect(engine.deliveries.isEmpty)
    }
}
