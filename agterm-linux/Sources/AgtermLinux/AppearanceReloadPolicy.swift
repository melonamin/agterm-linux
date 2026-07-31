enum LinuxAppearanceSide: Equatable {
    case light
    case dark

    init(isDark: Bool) {
        self = isDark ? .dark : .light
    }

    var isDark: Bool { self == .dark }
}

struct AppearanceReloadContext: Equatable {
    let followsSystemAppearance: Bool
    let hasLightSlot: Bool
    let hasDarkSlot: Bool
    let currentSide: LinuxAppearanceSide
}

struct AppearanceReloadPolicy {
    private var lastAppliedSide: LinuxAppearanceSide?

    func isEligible(for context: AppearanceReloadContext) -> Bool {
        guard context.followsSystemAppearance,
            context.hasLightSlot,
            context.hasDarkSlot
        else { return false }

        return context.currentSide != lastAppliedSide
    }

    mutating func recordAppliedColorSchemeSide(_ side: LinuxAppearanceSide) {
        lastAppliedSide = side
    }
}

@MainActor private(set) var gAppearanceReloadPolicy = AppearanceReloadPolicy()

@MainActor func recordAppliedColorSchemeSide(_ side: LinuxAppearanceSide) {
    gAppearanceReloadPolicy.recordAppliedColorSchemeSide(side)
}
