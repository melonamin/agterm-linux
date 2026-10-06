import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@MainActor
@Suite("HTML overlay page bridge")
struct LinuxHtmlOverlayBridgeTests {
    private static let token = "page-token"
    private static let origin = HtmlBridgePage(window: "W1", session: UUID(), pane: .right)

    private final class Calls {
        var requests: [ControlRequest] = []
        var replies: [(json: String?, error: String?)] = []
    }

    private func send(_ request: Any, token: String = token, origin: HtmlBridgePage? = origin,
                      response: ControlResponse? = ControlResponse(ok: true), calls: Calls) {
        let envelope: [String: Any] = ["token": token, "request": request]
        let message = (try? JSONSerialization.data(withJSONObject: envelope)).flatMap { String(data: $0, encoding: .utf8) }
        var dispatch: LinuxHtmlBridgeDispatch?
        if let response {
            dispatch = { request, reply in
                calls.requests.append(request)
                reply(response)
            }
        }
        LinuxHtmlOverlayBridge.handle(message, token: Self.token, origin: origin, dispatch: dispatch) { json, error in
            calls.replies.append((json, error))
        }
    }

    @Test func aMessageWithoutThePageTokenIsRefusedAsAFrame() {
        let calls = Calls()
        send(["cmd": "tree"], token: "other", calls: calls)
        LinuxHtmlOverlayBridge.handle(nil, token: Self.token, origin: Self.origin, dispatch: nil) { json, error in
            calls.replies.append((json, error))
        }
        #expect(calls.requests.isEmpty)
        #expect(calls.replies.map(\.error) == ["requests from frames are refused", "requests from frames are refused"])
    }

    @Test func aPageThatLeftItsSlotIsAnsweredClosed() {
        let calls = Calls()
        send(["cmd": "tree"], origin: nil, calls: calls)
        #expect(calls.requests.isEmpty)
        #expect(calls.replies.map(\.error) == ["page closed"])
    }

    @Test func aBodyThatIsNotAnObjectIsAnInvalidRequest() {
        let calls = Calls()
        send("tree", calls: calls)
        #expect(calls.replies.map(\.error) == ["invalid request"])
    }

    @Test func anUnknownCommandReadsAsTheSocketsDecodeError() throws {
        let calls = Calls()
        send(["cmd": "no.such"], calls: calls)
        let error = try #require(calls.replies.first?.error)
        #expect(error.hasPrefix("invalid request: "))
        #expect(calls.requests.isEmpty)
    }

    @Test(arguments: ["zmx.present", "zmx.reset", "session.overlay.job.run"])
    func streamAndAfterReplyCommandsAreRefused(cmd: String) {
        let calls = Calls()
        send(["cmd": cmd], calls: calls)
        #expect(calls.requests.isEmpty)
        #expect(calls.replies.map(\.error) == ["\(cmd) cannot be sent from a page"])
    }

    @Test func anUntargetedSubmitAnswersThePagesOwnSlot() throws {
        let calls = Calls()
        send(["cmd": "session.overlay.submit", "args": ["value": "main"]], calls: calls)
        let request = try #require(calls.requests.first)
        #expect(request.cmd == .sessionOverlaySubmit)
        #expect(request.target == Self.origin.session.uuidString)
        #expect(request.args?.pane == "right")
        #expect(request.args?.value == "main")
        #expect(calls.replies.count == 1)
    }

    @Test func theReplyCarriesTheResultAsJSON() throws {
        let calls = Calls()
        send(["cmd": "tree"], response: ControlResponse(ok: true, result: ControlResult(id: "S1", text: "hi")), calls: calls)
        #expect(calls.requests.first?.args?.window == "W1")
        let json = try #require(calls.replies.first?.json)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        #expect(object == ["id": "S1", "text": "hi"])
        #expect(calls.replies.first?.error == nil)
    }

    @Test func aFailedCommandRejectsWithItsError() {
        let calls = Calls()
        send(["cmd": "session.rename", "args": ["name": "x"]], response: ControlResponse(ok: false, error: "no such session"),
             calls: calls)
        #expect(calls.replies.count == 1)
        #expect(calls.replies.first?.json == nil)
        #expect(calls.replies.first?.error == "no such session")
    }

    @Test func noDispatchAnswersUnavailable() {
        let calls = Calls()
        send(["cmd": "tree"], response: nil, calls: calls)
        #expect(calls.replies.map(\.error) == ["control is unavailable"])
    }

    @Test func bothScriptsSendThePageTokenThroughTheAgtermHandler() {
        let adapter = LinuxHtmlOverlayBridge.adapterScript(token: "T-1")
        let helper = LinuxHtmlOverlayBridge.helperScript(token: "T-1")
        for script in [adapter, helper] {
            #expect(script.contains("window.webkit.messageHandlers.agterm"))
            #expect(script.contains("{token: 'T-1', request: body}"))
        }
        #expect(helper.contains("Object.defineProperty(window, 'agterm'"))
        #expect(adapter.contains("data-agterm-into"))
    }
}
