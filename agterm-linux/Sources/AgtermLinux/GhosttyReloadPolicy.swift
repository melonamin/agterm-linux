enum GhosttyReloadDisposition: Equatable {
    case ignoreSoftReload
    case reloadHostConfig
}

enum GhosttyReloadPolicy {
    static func handle(isSoft: Bool, reloadHostConfig: () -> Void) -> GhosttyReloadDisposition {
        guard !isSoft else { return .ignoreSoftReload }
        reloadHostConfig()
        return .reloadHostConfig
    }
}
