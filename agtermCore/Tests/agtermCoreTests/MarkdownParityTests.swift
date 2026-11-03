import Foundation
import Testing
@testable import agtermCore

/// These cases exercise the CommonMark structures a string-based Linux fallback misreads.
/// They apply to the Darwin implementation as well as the portable parser adapter.
struct MarkdownParityTests {
    @Test func infoKeepsInlineBlockMarkersAndDecodesNamedEntities() throws {
        let spans = try SessionInfo.make(source: "# step &ouml; **ready**", markdown: true, hideAfter: 0).get().spans
        #expect(spans == [SessionInfoSpan(text: "# step ö "), SessionInfoSpan(text: "ready", bold: true)])
    }

    @Test func nestedEmphasisAndEscapedMarkersKeepTheirTraits() throws {
        let spans = try SessionInfo.make(source: #"***ready*** \_literal\_"#, markdown: true, hideAfter: 0).get().spans
        #expect(spans == [SessionInfoSpan(text: "ready", bold: true, italic: true), SessionInfoSpan(text: " _literal_")])
    }

    @Test func imageLookingTextInCodeDoesNotCauseAFileRead() {
        let source = "`![inline](hidden.png)`\n\n```md\n![fenced](also-hidden.png)\n```\n\n    ![indented](third.png)"
        #expect(MarkdownPage.imageReferences(in: source, folder: "/tmp").isEmpty)
    }

    @Test func referenceImagesAndBalancedDestinationsKeepDocumentOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-parity-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.resolvingSymlinksInPath().path
        let source = "![nested [alt]](shot(a).png \"a title\") ![ref][key]\n\n[KEY]: second.png\n"
        #expect(MarkdownPage.imageReferences(in: source, folder: root) == [
            MarkdownPage.Image(reference: "shot(a).png", path: root + "/shot(a).png"),
            MarkdownPage.Image(reference: "second.png", path: root + "/second.png"),
        ])
    }
}
