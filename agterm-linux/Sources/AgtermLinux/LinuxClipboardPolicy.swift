import Foundation
import agtermCore

/// One clipboard representation. Binary-safe: text stays bytes too, so a write never re-encodes it.
struct ClipboardItem: Equatable, Sendable {
    let mime: String
    let data: Data
}

enum ClipboardRequestKind: CaseIterable, Sendable {
    case paste, list, osc52Read, osc52Write, kittyRead, kittyWrite
}

/// Host-free decisions behind the libghostty clipboard callbacks. A missing surface or clipboard is not
/// modeled here: the callback answers those `UNSUPPORTED`.
enum LinuxClipboardPolicy {
    enum ReadPlan: Equatable {
        case unavailable
        case listOnly
        case text(list: Bool)
    }

    static let textMime = "text/plain"
    static let utf8TextMime = "text/plain;charset=utf-8"
    static let uriListMime = "text/uri-list"

    /// A file-manager copy reads as POSIX paths, like macOS. The callback gets no request kind, so the
    /// clipboard's formats are what tell that from literal `file://` text, which round-trips unchanged.
    static func readableText(_ text: String, advertisesURIList: Bool) -> String {
        guard advertisesURIList else { return text }
        return PasteDecoder.posixPaths(fromURIList: text) ?? text
    }

    /// Reads serve text only: binary representations are never fetched from the clipboard.
    static func readPlan(mimes: [String], list: Bool) -> ReadPlan {
        if mimes.contains(textMime) { return .text(list: list) }
        return list ? .listOnly : .unavailable
    }

    /// `text` nil still yields a zero-length item: `UNAVAILABLE` never starts a request, so an OSC 52 reader
    /// would wait for a reply that never comes.
    static func textCompletion(text: String?, list: Bool) -> (items: [ClipboardItem], available: [String]) {
        ([ClipboardItem(mime: textMime, data: Data((text ?? "").utf8))], list ? listing(hasText: text != nil) : [])
    }

    static func listing(hasText: Bool) -> [String] {
        hasText ? [textMime] : []
    }

    /// Nil kinds complete unprompted: a paste has no permission to ask for, and a listing reads no content.
    static func access(for kind: ClipboardRequestKind) -> ClipboardAccess? {
        switch kind {
        case .osc52Read, .kittyRead: .read
        case .osc52Write, .kittyWrite: .write
        case .paste, .list: nil
        }
    }

    /// Bare `text/plain` defaults to ASCII, so a provider offering only it garbles non-ASCII text in
    /// readers that want UTF-8, and on X11 loses `UTF8_STRING`, which GDK derives from the charset form.
    /// UTF-8 goes first because some clients take the first match. A GDK union serves a MIME from its first
    /// provider, so an alias must never sit beside the client's own charset form.
    static func gdkRepresentations(_ items: [ClipboardItem]) -> [ClipboardItem] {
        if items.contains(where: { $0.mime == utf8TextMime }) { return items }
        return items.flatMap { item in
            item.mime == textMime ? [ClipboardItem(mime: utf8TextMime, data: item.data), item] : [item]
        }
    }
}
