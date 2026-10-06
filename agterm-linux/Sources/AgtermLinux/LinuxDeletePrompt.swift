enum DeletePrompt {
    static func workspaceMessage(name: String, sessions: Int) -> String {
        let sessionClause = sessions == 1 ? "1 session" : "\(sessions) sessions"
        return "Delete “\(name)” and its \(sessionClause)? This can't be undone."
    }

    static func windowMessage(name: String) -> String {
        "Delete the window “\(name)” and all its workspaces and sessions? This can't be undone."
    }
}
