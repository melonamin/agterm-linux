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
    /// UTF-8 goes first because some clients take the first match.
    static func gdkRepresentations(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.flatMap { item in
            item.mime == textMime ? [ClipboardItem(mime: utf8TextMime, data: item.data), item] : [item]
        }
    }
}
