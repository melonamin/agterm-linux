import Foundation

struct GhosttyResourceResolver {
    let candidates: [String]
    let fileExists: (String) -> Bool

    func resolve() -> String? {
        candidates.first { candidate in
            guard Self.isValid(candidate) else { return false }
            return fileExists(candidate + "/shell-integration")
                && fileExists(Self.terminfoEntry(for: candidate))
        }
    }

    var terminalName: String {
        Self.terminalName(resolvedResources: resolve())
    }

    static func terminalName(resolvedResources: String?) -> String {
        resolvedResources == nil ? "xterm-256color" : "xterm-ghostty"
    }

    private static func isValid(_ candidate: String) -> Bool {
        candidate.hasPrefix("/") && !candidate.contains("\0")
    }

    private static func terminfoEntry(for candidate: String) -> String {
        let share = (candidate as NSString).deletingLastPathComponent
        return share + "/terminfo/x/xterm-ghostty"
    }
}
