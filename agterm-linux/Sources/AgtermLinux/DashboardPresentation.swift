import agtermCore

/// Owner-local identity for one delayed dashboard click.
///
/// GTK owns the timeout source while this value owns the semantic generation.  Both are needed:
/// removing the source prevents needless delivery, while the generation makes a late callback harmless
/// if it was already dispatched when another click, keyboard move, or reconcile cancelled it.
struct DashboardClickIntent {
    static let delayMilliseconds: UInt32 = 180

    private(set) var generation: UInt64 = 0
    private(set) var member: DashboardMember?

    mutating func begin(member: DashboardMember) -> UInt64 {
        generation &+= 1
        self.member = member
        return generation
    }

    mutating func cancel() {
        generation &+= 1
        member = nil
    }

    func accepts(generation: UInt64, member: DashboardMember) -> Bool {
        self.generation == generation && self.member == member
    }
}

enum LinuxModalTitle {
    static func normal(sessionName: String?, window: WindowInfo?) -> String {
        let session = sessionName ?? "Agterm"
        guard let window, window.hasCustomName else { return session }
        return "\(session) — \(window.name)"
    }

    static func dashboard(window: WindowInfo?) -> String {
        guard let window, window.hasCustomName else { return "Dashboard" }
        return "Dashboard — \(window.name)"
    }
}
