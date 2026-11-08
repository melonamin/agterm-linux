import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux clipboard policy")
struct LinuxClipboardPolicyTests {
    private let plain = ClipboardItem(mime: LinuxClipboardPolicy.textMime, data: Data("cafe".utf8))
    private let utf8 = ClipboardItem(mime: LinuxClipboardPolicy.utf8TextMime, data: Data("café".utf8))

    /// `gdk_content_provider_new_union` writes a MIME from the first provider supporting it.
    private func served(_ mime: String, by items: [ClipboardItem]) -> Data? {
        items.first { $0.mime == mime }?.data
    }

    @Test("an explicit charset form after text/plain keeps its bytes")
    func explicitCharsetAfterPlain() {
        let representations = LinuxClipboardPolicy.gdkRepresentations([plain, utf8])

        #expect(representations == [plain, utf8])
        #expect(served(plain.mime, by: representations) == plain.data)
        #expect(served(utf8.mime, by: representations) == utf8.data)
    }

    @Test("an explicit charset form before text/plain keeps its bytes")
    func explicitCharsetBeforePlain() {
        let representations = LinuxClipboardPolicy.gdkRepresentations([utf8, plain])

        #expect(representations == [utf8, plain])
        #expect(served(plain.mime, by: representations) == plain.data)
        #expect(served(utf8.mime, by: representations) == utf8.data)
    }

    @Test("a charset form alone gains no bare text/plain")
    func charsetAlone() {
        let representations = LinuxClipboardPolicy.gdkRepresentations([utf8])

        #expect(representations == [utf8])
        #expect(served(plain.mime, by: representations) == nil)
    }

    @Test("text/plain alone is offered as UTF-8 first, with the same bytes")
    func plainAlone() {
        let representations = LinuxClipboardPolicy.gdkRepresentations([plain])

        #expect(representations.map(\.mime) == [utf8.mime, plain.mime])
        #expect(served(plain.mime, by: representations) == plain.data)
        #expect(served(utf8.mime, by: representations) == plain.data)
    }

    @Test("other representations keep their position and bytes around either text form")
    func otherRepresentationsUntouched() {
        let png = ClipboardItem(mime: "image/png", data: Data([0x89, 0x00, 0xFF]))

        #expect(LinuxClipboardPolicy.gdkRepresentations([png, plain, utf8]) == [png, plain, utf8])
        #expect(LinuxClipboardPolicy.gdkRepresentations([png, plain]).map(\.mime) == [png.mime, utf8.mime, plain.mime])
    }

    @Test("an advertised uri-list converts file:// text to POSIX paths")
    func uriListConverts() {
        let copied = "# copied files\r\nfile:///tmp/one%20two\r\nfile:///tmp/three\r\n"

        #expect(LinuxClipboardPolicy.readableText(copied, advertisesURIList: true) == "/tmp/one two /tmp/three")
    }

    @Test("without an advertised uri-list, file:// text round-trips")
    func literalFileURLRoundTrips() {
        for text in ["file:///tmp/example", "file:///tmp/one%20two\nfile:///tmp/three\n"] {
            #expect(LinuxClipboardPolicy.readableText(text, advertisesURIList: false) == text)
        }
    }

    @Test("ordinary text is unchanged whether or not a uri-list is advertised")
    func ordinaryTextUnchanged() {
        for text in ["plain", "file:///tmp/one\nplain", "# only a comment\n", ""] {
            #expect(LinuxClipboardPolicy.readableText(text, advertisesURIList: false) == text)
            #expect(LinuxClipboardPolicy.readableText(text, advertisesURIList: true) == text)
        }
    }

    @Test("a read plan follows the requested text MIME and the list flag")
    func readPlans() {
        let text = LinuxClipboardPolicy.textMime

        #expect(LinuxClipboardPolicy.readPlan(mimes: [text], list: false) == .text(list: false))
        #expect(LinuxClipboardPolicy.readPlan(mimes: ["image/png", text], list: false) == .text(list: false))
        #expect(LinuxClipboardPolicy.readPlan(mimes: [text], list: true) == .text(list: true))
        #expect(LinuxClipboardPolicy.readPlan(mimes: [], list: true) == .listOnly)
        #expect(LinuxClipboardPolicy.readPlan(mimes: ["image/png"], list: true) == .listOnly)
        #expect(LinuxClipboardPolicy.readPlan(mimes: [], list: false) == .unavailable)
        #expect(LinuxClipboardPolicy.readPlan(mimes: ["image/png"], list: false) == .unavailable)
    }

    @Test("an empty clipboard still completes with a zero-length text item and lists nothing")
    func emptyClipboardCompletion() {
        let empty = [ClipboardItem(mime: LinuxClipboardPolicy.textMime, data: Data())]

        #expect(LinuxClipboardPolicy.textCompletion(text: nil, list: false).items == empty)
        #expect(LinuxClipboardPolicy.textCompletion(text: nil, list: true).items == empty)
        #expect(LinuxClipboardPolicy.textCompletion(text: "", list: false).items == empty)
        #expect(LinuxClipboardPolicy.textCompletion(text: nil, list: true).available.isEmpty)
    }

    @Test("a text completion carries the UTF-8 bytes and lists formats only when asked")
    func textCompletion() {
        let text = LinuxClipboardPolicy.textMime
        let listed = LinuxClipboardPolicy.textCompletion(text: "café", list: true)
        let unlisted = LinuxClipboardPolicy.textCompletion(text: "café", list: false)

        #expect(listed.items == [ClipboardItem(mime: text, data: utf8.data)])
        #expect(listed.available == [text])
        #expect(unlisted.items == listed.items)
        #expect(unlisted.available.isEmpty)
    }

    @Test("only content access prompts, in the request's direction")
    func accessPerKind() {
        let expected: [ClipboardRequestKind: ClipboardAccess?] = [
            .paste: nil, .list: nil, .osc52Read: .read, .kittyRead: .read, .osc52Write: .write, .kittyWrite: .write,
        ]

        #expect(Set(expected.keys) == Set(ClipboardRequestKind.allCases))
        for (kind, access) in expected {
            #expect(LinuxClipboardPolicy.access(for: kind) == access, "\(kind)")
        }
    }
}
