import Foundation
import agtermCore

/// RemoteCompanionRequest is a companion the origin of a remote row is asked to create under its own session.
enum LinuxRemoteCompanionRequest: Sendable {
    case terminal(CompanionOptions)
    case duplicate
    case page(ControlSessionOverlayOpenOptions)

    var tint: SidebarTint? {
        if case .terminal(let options) = self { return options.tint }
        return nil
    }

    var command: Command {
        switch self {
        case .terminal: .sessionCompanionNew
        case .duplicate: .sessionCompanionDuplicate
        case .page: .sessionCompanionPage
        }
    }

    // the origin keeps its own selection: the companion is wanted here, not there
    func arguments(originSession: String) -> [String] {
        switch self {
        case .duplicate:
            return ["session", "duplicate", "--companion", "--target", originSession, "--no-select"]
        case .terminal(let options):
            var arguments = ["session", "new", "--parent", originSession, "--no-select"]
            if let cwd = options.cwd { arguments += ["--cwd", cwd] }
            if let command = options.command { arguments += ["--command", command] }
            if options.wait { arguments.append("--wait") }
            if let name = options.name { arguments += ["--name", name] }
            return arguments
        case .page(let options):
            return Self.pageArguments(options, originSession: originSession)
        }
    }

    // a file path is the origin's own: the page is that Mac's and is served from there
    private static func pageArguments(_ options: ControlSessionOverlayOpenOptions, originSession: String) -> [String] {
        var arguments = ["session", "overlay", "open", "--companion", "--target", originSession]
        switch options.page {
        case .file(let path, let grantRoot):
            arguments += ["--html", path]
            if let grantRoot { arguments += ["--cwd", grantRoot] }
        case .url(let url): arguments += ["--url", url.absoluteString]
        case .replica, .image, .markdown, .text, .document, nil: break
        }
        let flags: [(Bool, String)] = [(options.navigation, "--navigation"), (options.javascript, "--js"),
                                       (options.chromeless, "--chromeless"), (options.persistent, "--persistent"),
                                       (options.browse, "--browse")]
        arguments += flags.filter(\.0).map(\.1)
        if let color = options.backgroundColor { arguments += ["--background-color", color] }
        return arguments
    }
}
