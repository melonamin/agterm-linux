import ArgumentParser
import agtermCore

extension Session {
    struct Seen: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Clear a session's unseen-notification badge without changing the selection or focus (idempotent).")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionSeen, target: target.target, args: options.withWindow())
        }
    }
}
