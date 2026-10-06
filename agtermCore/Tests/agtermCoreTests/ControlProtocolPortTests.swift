import Foundation
import Testing
@testable import agtermCore

struct ControlProtocolPortTests {
    @Test func carriedRequestsRoundTrip() throws {
        for request in [
            ControlRequest(cmd: .recentClear),
            ControlRequest(cmd: .sessionResize, args: ControlArgs(pane: "left", ratioDelta: 0.05)),
            ControlRequest(cmd: .sessionResize, args: ControlArgs(pane: "bottom", ratioDelta: 0.05)),
        ] {
            let data = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
        }
    }

    @Test func paneResizeDecodesWireFields() throws {
        let data = Data(#"{"cmd":"session.resize","target":"active","args":{"ratioDelta":0.05,"pane":"right"}}"#.utf8)
        let request = try JSONDecoder().decode(ControlRequest.self, from: data)
        #expect(request.cmd == .sessionResize)
        #expect(request.args?.ratio == nil)
        #expect(request.args?.ratioDelta == 0.05)
        #expect(request.args?.pane == "right")
    }
}
