import CGtk
import Foundation
import agtermCore

/// GDK reads complete on GTK's main context. Borrowed lists, strings and PNG bytes are copied in the callback.
@MainActor
enum LinuxPasteClipboard {
    nonisolated static func dropOffer(_ raw: String) -> PasteOffer {
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") }
        let urls = lines.compactMap { URL(string: $0) }.filter { $0.scheme != nil }
        if !urls.isEmpty, urls.count == lines.count { return PasteOffer(urls: urls) }
        return PasteOffer(text: ShellEscape.dropPayload(raw))
    }
    private final class Read {
        let reply: @MainActor (PasteOffer) -> Void
        init(_ reply: @escaping @MainActor (PasteOffer) -> Void) { self.reply = reply }
    }

    static func read(_ reply: @escaping @MainActor (PasteOffer) -> Void) {
        guard let clipboard = LinuxClipboardAdapter.gdkClipboard(for: GHOSTTY_CLIPBOARD_STANDARD),
              let formats = gdk_clipboard_get_formats(clipboard) else { return reply(PasteOffer()) }
        let read = Read(reply)
        if LinuxClipboardAdapter.advertisesURIList(clipboard) || gdk_content_formats_contain_gtype(formats, gdk_file_list_get_type()) != 0 {
            gdk_clipboard_read_value_async(clipboard, gdk_file_list_get_type(), 0, nil, { source, result, data in
                MainActor.assumeIsolated {
                    let read = Unmanaged<Read>.fromOpaque(data!).takeRetainedValue()
                    let value = gdk_clipboard_read_value_finish(OpaquePointer(source), result, nil)
                    read.reply(PasteOffer(urls: value.map(LinuxPasteClipboard.files) ?? []))
                }
            }, Unmanaged.passRetained(read).toOpaque())
        } else if LinuxClipboardAdapter.advertisesText(clipboard) {
            gdk_clipboard_read_text_async(clipboard, nil, { source, result, data in
                MainActor.assumeIsolated {
                    let read = Unmanaged<Read>.fromOpaque(data!).takeRetainedValue()
                    let raw = gdk_clipboard_read_text_finish(OpaquePointer(source), result, nil)
                    defer { g_free(raw) }
                    read.reply(PasteOffer(text: raw.map { String(cString: $0) }))
                }
            }, Unmanaged.passRetained(read).toOpaque())
        } else {
            gdk_clipboard_read_texture_async(clipboard, nil, { source, result, data in
                MainActor.assumeIsolated {
                    let read = Unmanaged<Read>.fromOpaque(data!).takeRetainedValue()
                    let texture = gdk_clipboard_read_texture_finish(OpaquePointer(source), result, nil)
                    defer { if let texture { g_object_unref(UnsafeMutableRawPointer(texture)) } }
                    read.reply(PasteOffer(image: texture.flatMap(LinuxPasteClipboard.png)))
                }
            }, Unmanaged.passRetained(read).toOpaque())
        }
    }

    static func png(_ texture: OpaquePointer) -> Data? {
        guard let bytes = gdk_texture_save_to_png_bytes(texture) else { return nil }
        defer { g_bytes_unref(bytes) }
        var size: gsize = 0
        guard let pointer = g_bytes_get_data(bytes, &size) else { return nil }
        return Data(bytes: pointer, count: Int(size))
    }

    static func files(_ value: UnsafePointer<GValue>) -> [URL] {
        guard let boxed = g_value_get_boxed(value), let list = gdk_file_list_get_files(OpaquePointer(boxed)) else { return [] }
        // The returned list and GFiles are borrowed from GdkFileList.
        var urls: [URL] = []
        var node: UnsafeMutablePointer<GSList>? = list
        while let current = node {
            if let pointer = current.pointee.data, let raw = g_file_get_uri(OpaquePointer(pointer)) {
                if let url = URL(string: String(cString: raw)) { urls.append(url) }
                g_free(raw)
            }
            node = current.pointee.next
        }
        return urls
    }
}
