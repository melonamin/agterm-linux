import Foundation
import Testing
@testable import AgtermLinux

@Suite("Linux clipboard policy — GDK representations")
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
}
