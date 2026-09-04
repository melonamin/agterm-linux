import Foundation
import Testing
@testable import AgtermLinux

@Suite("Linux overlay exit capture")
struct LinuxOverlayExitCaptureTests {
    @Test("capture consumes the wrapper status file")
    func consumeStatus() throws {
        let file = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("agterm-overlay-capture-\(UUID().uuidString)")
        try "23\n".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(LinuxOverlayExitCapture.consume(file) == 23)
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test("malformed capture is still removed")
    func consumeMalformedStatus() throws {
        let file = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("agterm-overlay-capture-\(UUID().uuidString)")
        try "not a status\n".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(LinuxOverlayExitCapture.consume(file) == nil)
        #expect(!FileManager.default.fileExists(atPath: file))
    }
}
