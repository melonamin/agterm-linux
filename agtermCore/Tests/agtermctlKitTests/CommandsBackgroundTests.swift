import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

struct CommandsBackgroundTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    private func validationMessage(_ argv: [String]) -> String? {
        do {
            _ = try Agtermctl.parseAsRoot(argv)
            return nil
        } catch {
            return Agtermctl.message(for: error)
        }
    }

    // MARK: - session background

    @Test func sessionBackgroundImage() throws {
        let expected = ControlRequest(cmd: .sessionBackground, target: "active",
                                      args: ControlArgs(mode: "image", path: "/tmp/bg.png"))
        #expect(try request(["session", "background", "image", "/tmp/bg.png"]) == expected)
    }

    @Test func sessionBackgroundImageWithOptions() throws {
        let expected = ControlRequest(cmd: .sessionBackground, target: "s1",
                                      args: ControlArgs(mode: "image", path: "/tmp/bg.png", opacity: 0.2,
                                                        fit: "cover", position: "top-left", repeats: true))
        let argv = ["session", "background", "image", "/tmp/bg.png", "--opacity", "0.2",
                    "--fit", "cover", "--position", "top-left", "--repeat", "--target", "s1"]
        #expect(try request(argv) == expected)
    }

    @Test func sessionBackgroundText() throws {
        let expected = ControlRequest(cmd: .sessionBackground, target: "active",
                                      args: ControlArgs(text: "DRAFT", mode: "text", color: "#ff0000", opacity: 0.15))
        let argv = ["session", "background", "text", "DRAFT", "--color", "#ff0000", "--opacity", "0.15"]
        #expect(try request(argv) == expected)
    }

    @Test func sessionBackgroundColor() throws {
        let expected = ControlRequest(cmd: .sessionBackground, target: "s1",
                                      args: ControlArgs(mode: "color", color: "#112233"))
        #expect(try request(["session", "background", "color", "#112233", "--target", "s1"]) == expected)
    }

    @Test func sessionBackgroundColorRejectsBadColor() {
        // assert the color validation (not some unrelated parse error) fired.
        #expect(validationMessage(["session", "background", "color", "red"])?.contains("color") == true)
        #expect(validationMessage(["session", "background", "color", "#fff"])?.contains("color") == true)
    }

    @Test func sessionBackgroundClear() throws {
        let expected = ControlRequest(cmd: .sessionBackground, target: "active", args: ControlArgs(mode: "clear"))
        #expect(try request(["session", "background", "clear"]) == expected)
    }

    @Test(arguments: [(["image", "/tmp/bg.png", "--pane", "right"], ControlArgs(mode: "image", pane: "right", path: "/tmp/bg.png")),
                      (["text", "PEER", "--pane", "split"], ControlArgs(text: "PEER", mode: "text", pane: "split")),
                      (["color", "#201414", "--pane", "left"], ControlArgs(mode: "color", pane: "left", color: "#201414")),
                      (["clear", "--pane", "scratch"], ControlArgs(mode: "clear", pane: "scratch"))])
    func sessionBackgroundPaneEncodesForEveryMode(argv: [String], args: ControlArgs) throws {
        #expect(try request(["session", "background"] + argv) == ControlRequest(cmd: .sessionBackground, target: "active", args: args))
        #expect(validationMessage(["session", "background"] + argv.dropLast() + ["middle"]) == "--pane must be left, right, or scratch")
    }

    @Test func sessionBackgroundRejectsBadFit() {
        #expect(validationMessage(["session", "background", "image", "/tmp/bg.png", "--fit", "fill"]) != nil)
    }

    @Test func sessionBackgroundRejectsBadPosition() {
        #expect(validationMessage(["session", "background", "text", "X", "--position", "middle"]) != nil)
    }

    @Test func sessionBackgroundRejectsOutOfRangeOpacity() {
        #expect(validationMessage(["session", "background", "image", "/tmp/bg.png", "--opacity", "1.5"]) != nil)
        #expect(validationMessage(["session", "background", "text", "X", "--opacity", "-0.2"]) != nil)
    }

    @Test func sessionBackgroundRejectsBadColor() {
        #expect(validationMessage(["session", "background", "text", "X", "--color", "red"]) != nil)
        #expect(validationMessage(["session", "background", "text", "X", "--color", "#fff"]) != nil)
    }

    @Test func sessionBackgroundAcceptsValidColor() throws {
        let expected = ControlRequest(cmd: .sessionBackground, target: "active",
                                      args: ControlArgs(text: "X", mode: "text", color: "#ff8800"))
        #expect(try request(["session", "background", "text", "X", "--color", "#ff8800"]) == expected)
    }

    @Test func sessionBackgroundRejectsEmptyAndTooLongText() {
        #expect(validationMessage(["session", "background", "text", ""]) != nil)
        #expect(validationMessage(["session", "background", "text",
                                   String(repeating: "A", count: WatermarkConfig.maxTextLength + 1)]) != nil)
    }

    @Test func sessionBackgroundImageRejectsControlCharPath() {
        // a newline in the path would smuggle an extra ghostty key into the per-surface overlay.
        #expect(validationMessage(["session", "background", "image", "x.png\nclipboard-read = allow\ny.png"]) != nil)
    }
}
