import CGtk
import Foundation

struct ClipboardConfirmation: Equatable, Sendable {
    let items: [ClipboardItem]
    let available: [String]
}

/// The C side of the clipboard callbacks: copies libghostty's borrowed payloads into Swift values, packs
/// completions, and owns the GDK providers. `LinuxClipboardPolicy` makes the decisions.
enum LinuxClipboardAdapter {
    typealias Completion = (ghostty_surface_t, UnsafePointer<ghostty_clipboard_complete_s>, UnsafeMutableRawPointer?) -> Void
    typealias Denial = (ghostty_surface_t, UnsafeMutableRawPointer?) -> Void

    private static func engineCompletion(_ surface: ghostty_surface_t, _ complete: UnsafePointer<ghostty_clipboard_complete_s>,
                                         _ state: UnsafeMutableRawPointer?) {
        ghostty_surface_complete_clipboard_request(surface, complete, state)
    }

    private static func engineDenial(_ surface: ghostty_surface_t, _ state: UnsafeMutableRawPointer?) {
        ghostty_surface_deny_clipboard_request(surface, state)
    }

    // MARK: - Copying borrowed payloads

    static func copyMimes(_ mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int) -> [String] {
        UnsafeBufferPointer(start: mimes, count: mimes == nil ? 0 : count).compactMap { $0.map { String(cString: $0) } }
    }

    /// A nil `data` is a zero-length item, never a dropped one: core reports `DONE` to the program right
    /// after the write callback, so a dropped representation is a false success.
    static func copyItems(_ items: UnsafePointer<ghostty_clipboard_content_s>?, count: Int) -> [ClipboardItem] {
        UnsafeBufferPointer(start: items, count: items == nil ? 0 : count).compactMap { item in
            guard let mime = item.mime else { return nil }
            let data = item.data.map { Data(bytes: $0, count: item.len) } ?? Data()
            return ClipboardItem(mime: String(cString: mime), data: data)
        }
    }

    static func copyConfirmation(_ confirm: ghostty_clipboard_confirm_s) -> ClipboardConfirmation {
        ClipboardConfirmation(items: copyItems(confirm.contents, count: confirm.contents_len),
                              available: copyMimes(confirm.available, count: confirm.available_len))
    }

    static func requestKind(_ request: ghostty_clipboard_request_e) -> ClipboardRequestKind {
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ: .osc52Read
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE: .osc52Write
        case GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ: .kittyRead
        case GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE: .kittyWrite
        case GHOSTTY_CLIPBOARD_REQUEST_LIST: .list
        default: .paste
        }
    }

    // MARK: - Completing requests

    /// Everything handed to `deliver` is freed when it returns, which the engine's borrow allows.
    static func complete(_ surface: ghostty_surface_t, items: [ClipboardItem], available: [String],
                         state: UnsafeMutableRawPointer?, confirmed: Bool = false,
                         using deliver: Completion = engineCompletion) {
        var strings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            strings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }

        var contents: [ghostty_clipboard_content_s] = []
        for item in items {
            guard let mime = strdup(item.mime) else { continue }
            strings.append(mime)
            // the engine slices `data` as a non-null pointer, zero-length items included
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(item.data.count, 1), alignment: 1)
            buffers.append(buffer)
            item.data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: item.data.count)
            contents.append(ghostty_clipboard_content_s(
                mime: mime, data: buffer.assumingMemoryBound(to: CChar.self), len: item.data.count))
        }

        var mimes: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let copy = strdup(mime) else { continue }
            strings.append(copy)
            mimes.append(UnsafePointer(copy))
        }

        contents.withUnsafeBufferPointer { contentsBuffer in
            mimes.withUnsafeBufferPointer { mimesBuffer in
                var completion = ghostty_clipboard_complete_s(
                    contents: contentsBuffer.baseAddress, contents_len: contentsBuffer.count,
                    available: mimesBuffer.baseAddress, available_len: mimesBuffer.count,
                    confirmed: confirmed, remember: false)
                deliver(surface, &completion, state)
            }
        }
    }

    /// The prompt's answer. `liveSurface` is read only when it arrives, because a pointer taken earlier
    /// dangles once the pane closes under the prompt. A closed pane gets neither call: the request state
    /// then leaks in the engine, and no C API frees it without the surface.
    static func confirmationAnswer(liveSurface: @escaping () -> ghostty_surface_t?, payload: ClipboardConfirmation,
                                   state: UnsafeMutableRawPointer?, complete deliver: @escaping Completion = engineCompletion,
                                   deny: @escaping Denial = engineDenial) -> (Bool) -> Void {
        { allowed in
            guard let surface = liveSurface() else { return }
            guard allowed else {
                deny(surface, state)
                return
            }
            complete(surface, items: payload.items, available: payload.available, state: state, confirmed: true, using: deliver)
        }
    }

    // MARK: - GDK

    /// `SELECTION` is copy-on-select and `PRIMARY` is OSC 52 `p`; GDK has one primary clipboard for both.
    static func gdkClipboard(for loc: ghostty_clipboard_e) -> OpaquePointer? {
        guard let display = gdk_display_get_default() else { return nil }
        if loc == GHOSTTY_CLIPBOARD_SELECTION || loc == GHOSTTY_CLIPBOARD_PRIMARY {
            return gdk_display_get_primary_clipboard(display)
        }
        return gdk_display_get_clipboard(display)
    }

    /// What `gdk_clipboard_read_text_async` would find, without fetching content. Asking for `text/plain`
    /// alone would miss a clipboard offering only a charset form or an X11 atom.
    static func advertisesText(_ clipboard: OpaquePointer) -> Bool {
        guard let formats = gdk_clipboard_get_formats(clipboard) else { return false }
        // the union consumes the reference it is given and returns a new one
        let readable = gdk_content_formats_union_deserialize_gtypes(gdk_content_formats_ref(formats))
        defer { gdk_content_formats_unref(readable) }
        return gdk_content_formats_contain_gtype(readable, GType(64) /* G_TYPE_STRING */) != 0
    }

    static func advertisesURIList(_ clipboard: OpaquePointer) -> Bool {
        guard let formats = gdk_clipboard_get_formats(clipboard) else { return false }
        return LinuxClipboardPolicy.uriListMime.withCString { gdk_content_formats_contain_mime_type(formats, $0) != 0 }
    }

    /// `read` owns the surface reference from here and always completes on the main thread.
    static func readText(_ clipboard: OpaquePointer, _ read: ClipboardTextRead) {
        gdk_clipboard_read_text_async(
            clipboard, nil,
            { source, result, data in
                let read = Unmanaged<ClipboardTextRead>.fromOpaque(data!).takeRetainedValue()
                defer { read.retained.release() }
                var text: String?
                if let source, let raw = gdk_clipboard_read_text_finish(OpaquePointer(source), result, nil) {
                    let value = String(cString: raw)
                    g_free(raw)
                    text = LinuxClipboardPolicy.readableText(value, advertisesURIList: read.advertisesURIList)
                }
                MainActor.assumeIsolated { read.finish(text: text) }
            },
            Unmanaged.passRetained(read).toOpaque()
        )
    }

    /// GDK ownership: the bytes provider takes its own `GBytes` reference, the union takes over its child
    /// providers and copies the array, and `gdk_clipboard_set_content` borrows the provider.
    static func setClipboard(_ items: [ClipboardItem], loc: ghostty_clipboard_e) {
        guard let clipboard = gdkClipboard(for: loc), let provider = contentProvider(for: items) else { return }
        defer { g_object_unref(provider) }
        if gdk_clipboard_set_content(clipboard, provider) == 0 {
            LinuxStructuredLogger(category: "Clipboard").notice("gdk_clipboard_set_content refused \(items.count) item(s)")
        }
    }

    private static func contentProvider(for items: [ClipboardItem]) -> UnsafeMutablePointer<GdkContentProvider>? {
        var providers = LinuxClipboardPolicy.gdkRepresentations(items).map(bytesProvider)
        guard providers.count > 1 else { return providers.first ?? nil }
        return gdk_content_provider_new_union(&providers, gsize(providers.count))
    }

    private static func bytesProvider(_ item: ClipboardItem) -> UnsafeMutablePointer<GdkContentProvider>? {
        let bytes = item.data.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        return item.mime.withCString { gdk_content_provider_new_for_bytes($0, bytes) }
    }
}

/// A started text read, carried through GDK's async callback.
final class ClipboardTextRead: @unchecked Sendable {
    let state: UnsafeMutableRawPointer?
    let retained: RetainedGhosttySurface
    let list: Bool
    let advertisesURIList: Bool

    init(state: UnsafeMutableRawPointer?, retained: RetainedGhosttySurface, list: Bool, advertisesURIList: Bool) {
        self.state = state
        self.retained = retained
        self.list = list
        self.advertisesURIList = advertisesURIList
    }

    /// Rereads the live surface, which a teardown during the GDK read frees. The orphaned request state
    /// then leaks: no C API frees it without the surface.
    @MainActor func finish(text: String?) {
        guard let surface = retained.surface.surface else { return }
        let completion = LinuxClipboardPolicy.textCompletion(text: text, list: list)
        LinuxClipboardAdapter.complete(surface, items: completion.items, available: completion.available, state: state)
    }
}
