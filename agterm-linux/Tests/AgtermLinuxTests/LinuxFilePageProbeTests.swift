import Foundation
import Glibc
import Testing
import agtermCore
@testable import AgtermLinux

struct LinuxFilePageProbeTests {
    private static let png = """
    iVBORw0KGgoAAAANSUhEUgAAAAIAAAADAQMAAACDJEzCAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwA
    AAAGUExURf8AAP///0EdNBEAAAABYktHRAH/Ai3eAAAAB3RJTUUH6gsCEw0u0coFdQAAAAtJREFUCNdjYAABAAAGAAFm9MlsAAAAAE
    lFTkSuQmCC
    """
    private static let jpeg = """
    /9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8Q
    EBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ
    EBAQEBAQEBD/wAARCAADAAIDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAV
    AQEBAAAAAAAAAAAAAAAAAAAHCf/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/ADoDFU3/2Q==
    """
    private static let fixtures = [
        "png": png,
        "jpeg": jpeg,
        "gif": "R0lGODlhAgADAPAAAP8AAAAAACH5BAAAAAAAIf8LSW1hZ2VNYWdpY2sOZ2FtbWE9MC40NTQ1NDUALAAAAAACAAMAAAIChF8AOw==",
        "webp": "UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoCAAMAAgA0JaACdLoB+AADsAD+8MQL/yC5YXXI1/8gP+QH/ID/+PIAAAA=",
    ]

    @Test(arguments: ["png", "jpeg", "gif", "webp"])
    func formatsAreIdentifiedFromBytesAndKeepOriginalDimensions(_ format: String) throws {
        try withDirectory { root in
            let encoded = try #require(Self.fixtures[format])
            let data = try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
            let path = root.appendingPathComponent("wrong-extension.bin")
            try data.write(to: path)
            let (probe, original) = try ImageProbe.load(path: path.path).get()
            #expect(probe.pixelWidth == 2)
            #expect(probe.pixelHeight == 3)
            #expect(probe.mimeType == "image/\(format)")
            #expect(original == data)
        }
    }

    @Test func aSparseOversizedSymlinkIsRefusedBeforeReadingItsTarget() throws {
        try withDirectory { root in
            let target = root.appendingPathComponent("large.png")
            try Data().write(to: target)
            let handle = try FileHandle(forWritingTo: target)
            try handle.truncate(atOffset: UInt64(ImagePage.maxBytes + 1))
            try handle.close()
            let link = root.appendingPathComponent("link.png")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            guard case .failure(.tooLarge) = ImageProbe.load(path: link.path) else { Issue.record("oversized target accepted"); return }
        }
    }

    @Test func fifosAndDevicesAreRefusedWithoutReading() throws {
        try withDirectory { root in
            let fifo = root.appendingPathComponent("pipe.png").path
            #expect(mkfifo(fifo, 0o600) == 0)
            guard case .failure(.unreadable) = ImageProbe.load(path: fifo) else { Issue.record("FIFO accepted"); return }
            let link = root.appendingPathComponent("zero.png")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/dev/zero")
            guard case .failure(.unreadable) = ImageProbe.load(path: link.path) else { Issue.record("device accepted"); return }
        }
    }

    @Test func markupAndTruncatedHeadersCannotMasqueradeAsImages() throws {
        try withDirectory { root in
            for (index, data) in [Data("<svg><script>1</script></svg>".utf8), Data([0x89, 0x50, 0x4E, 0x47])].enumerated() {
                let path = root.appendingPathComponent("fake-\(index).png")
                try data.write(to: path)
                guard case .failure(.notAnImage) = ImageProbe.load(path: path.path) else { Issue.record("invalid image accepted"); continue }
            }
        }
    }

    @Test func pixelBombIsRejectedBeforeAFullDecode() throws {
        try withDirectory { root in
            var gif = try #require(Data(base64Encoded: Self.fixtures["gif"]!))
            gif.replaceSubrange(6..<10, with: [255, 255, 255, 255])
            let path = root.appendingPathComponent("bomb.gif")
            try gif.write(to: path)
            guard case .failure(.tooManyPixels) = ImageProbe.load(path: path.path) else {
                Issue.record("oversized pixel dimensions accepted")
                return
            }
        }
    }

    @Test func jpegOrientationChangesNaturalPointDimensions() throws {
        try withDirectory { root in
            var jpeg = try #require(Data(base64Encoded: Self.jpeg, options: .ignoreUnknownCharacters))
            let exif: [UInt8] = [
                0xFF, 0xE1, 0, 34, 69, 120, 105, 102, 0, 0, 73, 73, 42, 0, 8, 0, 0, 0,
                1, 0, 0x12, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0,
            ]
            jpeg.insert(contentsOf: exif, at: 2)
            let path = root.appendingPathComponent("rotated.jpg")
            try jpeg.write(to: path)
            let (probe, _) = try ImageProbe.load(path: path.path).get()
            #expect(probe.orientation == 6)
            #expect(probe.natural(scale: 1).width == 3)
            #expect(probe.natural(scale: 1).height == 2)
        }
    }

    @Test func markdownRefusesNonregularInputAndEmbedsOnlyContainedPictures() throws {
        try withDirectory { root in
            let folder = root.appendingPathComponent("docs")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let picture = folder.appendingPathComponent("picture.png")
            let data = try #require(Data(base64Encoded: Self.png, options: .ignoreUnknownCharacters))
            try data.write(to: picture)
            let outside = root.appendingPathComponent("outside.png")
            try data.write(to: outside)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.png"), withDestinationURL: outside)
            let markdown = folder.appendingPathComponent("guide.md")
            try "![yes](picture.png) ![again](./picture.png) ![no](escape.png) ![no](../outside.png)".write(
                to: markdown, atomically: true, encoding: .utf8)
            let probe = try MarkdownProbe.load(path: markdown.path).get()
            #expect(probe.images.uris.count == 1)
            #expect(probe.images.references.count == 2)
            let fifo = folder.appendingPathComponent("pipe.md").path
            #expect(mkfifo(fifo, 0o600) == 0)
            guard case .failure(.unreadable) = MarkdownProbe.load(path: fifo) else {
                Issue.record("Markdown FIFO accepted")
                return
            }
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linux-image-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
