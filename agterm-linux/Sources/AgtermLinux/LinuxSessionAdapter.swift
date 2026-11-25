import Foundation
import agtermCore

enum LinuxSessionTitlePolicy {
    /// A local shell's automatic cwd title carries no information the session model does not already
    /// have. Normalize it to blank so `Session.displayName` keeps using the cwd basename. Real program
    /// titles and remote Fish titles (which include a host prefix) continue through unchanged.
    static func recordableTitle(_ title: String, cwd: String, home: String, loginShell: String?) -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == cwd { return "" }
        if loginShell == "fish", value == fishPromptPwd(cwd: cwd, home: home) { return "" }
        return title
    }

    /// Fish's default `fish_title` uses `prompt_pwd -d 1 -D 1`: home becomes `~`, intermediate
    /// components shrink to one character (or dot + one for hidden components), and the leaf stays whole.
    private static func fishPromptPwd(cwd: String, home: String) -> String {
        let shown: String
        if cwd == home {
            shown = "~"
        } else if !home.isEmpty, cwd.hasPrefix(home + "/") {
            shown = "~" + cwd.dropFirst(home.count)
        } else {
            shown = cwd
        }
        guard shown != "/", shown != "~" else { return shown }
        let rooted = shown.hasPrefix("/")
        let homeRooted = shown.hasPrefix("~/")
        let body = homeRooted ? String(shown.dropFirst(2)) : String(shown.drop(while: { $0 == "/" }))
        var parts = body.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return shown }
        for index in 0..<(parts.count - 1) {
            let part = parts[index]
            parts[index] = part.hasPrefix(".") && part.count > 1
                ? "." + part.dropFirst().prefix(1)
                : String(part.prefix(1))
        }
        let prefix = homeRooted ? "~/" : (rooted ? "/" : "")
        return prefix + parts.joined(separator: "/")
    }
}

extension AppStore {
    func setPaneFocus(_ toSplit: Bool, forSession sessionID: UUID) {
        guard let session = session(withID: sessionID), session.hasSplit else { return }
        if session.splitFocused != toSplit { session.splitFocused = toSplit }
    }

    @discardableResult
    func recordPwd(_ pwd: String, forSession sessionID: UUID, isSplit: Bool) -> Bool {
        guard let session = session(withID: sessionID) else { return false }
        if isSplit {
            guard session.splitCwd != pwd else { return false }
            session.splitCwd = pwd
        } else if session.currentCwd != pwd {
            session.currentCwd = pwd
        } else {
            return false
        }
        return true
    }

    @discardableResult
    func recordTitle(_ title: String, forSession sessionID: UUID, isSplit: Bool) -> Bool {
        guard let session = session(withID: sessionID) else { return false }
        if isSplit {
            guard session.splitTitle != title else { return false }
            session.splitTitle = title
        } else if session.oscTitle != title {
            session.oscTitle = title
        } else {
            return false
        }
        return true
    }

    @discardableResult
    func recordTitle(_ title: String, forSession sessionID: UUID, isSplit: Bool,
                     loginShell: String?, home: String) -> Bool {
        guard let session = session(withID: sessionID) else { return false }
        let cwd = isSplit ? (session.splitCwd ?? session.initialSplitCwd ?? session.effectiveCwd)
            : session.effectiveCwd
        return recordTitle(LinuxSessionTitlePolicy.recordableTitle(
            title, cwd: cwd, home: home, loginShell: loginShell),
            forSession: sessionID, isSplit: isSplit)
    }
}
