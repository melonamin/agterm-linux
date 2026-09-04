import Testing
@testable import AgtermLinux

@Suite("Linux appearance reload policy")
struct AppearanceReloadPolicyTests {
    @Test("an appearance side preserves the observed darkness")
    func appearanceSidePreservesObservedDarkness() {
        // Given / When
        let light = LinuxAppearanceSide(isDark: false)
        let dark = LinuxAppearanceSide(isDark: true)

        // Then
        #expect(!light.isDark)
        #expect(dark.isDark)
    }

    @Test("sync off skips an appearance reload")
    func syncOffIsIneligible() {
        // Given
        let context = AppearanceReloadContext(
            followsSystemAppearance: false,
            hasLightSlot: true,
            hasDarkSlot: true,
            currentSide: .dark
        )

        // When
        let eligible = AppearanceReloadPolicy().isEligible(for: context)

        // Then
        #expect(!eligible)
    }

    @Test("an ineligible reload still carries the settled side for live scheme synchronization")
    func syncOffStillPlansLiveSchemeSynchronization() {
        // Given
        let context = AppearanceReloadContext(
            followsSystemAppearance: false,
            hasLightSlot: true,
            hasDarkSlot: true,
            currentSide: .dark
        )

        // When
        let plan = AppearanceReloadPolicy().plan(for: context)

        // Then
        #expect(plan == AppearanceReconciliationPlan(side: .dark, requiresConfigReload: false))
    }

    @Test("sync on with both slots accepts a side change")
    func syncOnIsEligible() {
        // Given
        let context = AppearanceReloadContext(
            followsSystemAppearance: true,
            hasLightSlot: true,
            hasDarkSlot: true,
            currentSide: .dark
        )

        // When
        let eligible = AppearanceReloadPolicy().isEligible(for: context)

        // Then
        #expect(eligible)
    }

    @Test("a missing light slot skips an appearance reload")
    func missingLightSlotIsIneligible() {
        // Given
        let context = AppearanceReloadContext(
            followsSystemAppearance: true,
            hasLightSlot: false,
            hasDarkSlot: true,
            currentSide: .dark
        )

        // When
        let eligible = AppearanceReloadPolicy().isEligible(for: context)

        // Then
        #expect(!eligible)
    }

    @Test("a missing dark slot skips an appearance reload")
    func missingDarkSlotIsIneligible() {
        // Given
        let context = AppearanceReloadContext(
            followsSystemAppearance: true,
            hasLightSlot: true,
            hasDarkSlot: false,
            currentSide: .dark
        )

        // When
        let eligible = AppearanceReloadPolicy().isEligible(for: context)

        // Then
        #expect(!eligible)
    }

    @Test("the first valid appearance event reloads")
    func firstValidEventIsEligible() {
        // Given
        let context = AppearanceReloadContext(
            followsSystemAppearance: true,
            hasLightSlot: true,
            hasDarkSlot: true,
            currentSide: .dark
        )

        // When
        let eligible = AppearanceReloadPolicy().isEligible(for: context)

        // Then
        #expect(eligible)
    }

    @Test("a same-side duplicate skips an appearance reload")
    func sameSideDuplicateIsIneligible() {
        // Given
        let context = AppearanceReloadContext(
            followsSystemAppearance: true,
            hasLightSlot: true,
            hasDarkSlot: true,
            currentSide: .dark
        )

        // When
        var policy = AppearanceReloadPolicy()
        policy.recordAppliedColorSchemeSide(.dark)
        let eligible = policy.isEligible(for: context)

        // Then
        #expect(!eligible)
    }

    @Test("an opposite-side change reloads")
    func oppositeSideChangeIsEligible() {
        // Given
        let context = AppearanceReloadContext(
            followsSystemAppearance: true,
            hasLightSlot: true,
            hasDarkSlot: true,
            currentSide: .light
        )

        // When
        var policy = AppearanceReloadPolicy()
        policy.recordAppliedColorSchemeSide(.dark)
        let eligible = policy.isEligible(for: context)

        // Then
        #expect(eligible)
    }

    @Test("startup seeding suppresses a same-side appearance event")
    func startupSeedingSuppressesSameSideEvent() {
        // Given
        var policy = AppearanceReloadPolicy()
        let context = AppearanceReloadContext(
            followsSystemAppearance: true,
            hasLightSlot: true,
            hasDarkSlot: true,
            currentSide: .dark
        )
        policy.recordAppliedColorSchemeSide(.dark)

        // When
        let eligible = policy.isEligible(for: context)

        // Then
        #expect(!eligible)
    }

    @Test("startup applies light then reconciles dark")
    func startupAppliedLightThenReconcilesDark() {
        // Given
        var policy = AppearanceReloadPolicy()
        let dark = AppearanceReloadContext(
            followsSystemAppearance: true,
            hasLightSlot: true,
            hasDarkSlot: true,
            currentSide: .dark
        )
        policy.recordAppliedColorSchemeSide(.light)

        // When
        let eligibleBeforeDarkApply = policy.isEligible(for: dark)
        policy.recordAppliedColorSchemeSide(.dark)
        let eligibleAfterDarkApply = policy.isEligible(for: dark)

        // Then
        #expect(eligibleBeforeDarkApply)
        #expect(!eligibleAfterDarkApply)
    }

    @Test("a successful apply records the current side")
    func successfulApplyRecordsCurrentSide() {
        // Given
        var policy = AppearanceReloadPolicy()
        let context = AppearanceReloadContext(
            followsSystemAppearance: true,
            hasLightSlot: true,
            hasDarkSlot: true,
            currentSide: .light
        )

        // When
        policy.recordAppliedColorSchemeSide(.light)

        // Then
        #expect(!policy.isEligible(for: context))
    }

    @Test("an unrecorded failed apply leaves the previous side eligible")
    func unrecordedFailedApplyLeavesPreviousSideEligible() {
        // Given
        var policy = AppearanceReloadPolicy()
        let light = AppearanceReloadContext(
            followsSystemAppearance: true,
            hasLightSlot: true,
            hasDarkSlot: true,
            currentSide: .light
        )
        policy.recordAppliedColorSchemeSide(.dark)

        // When
        let eligible = policy.isEligible(for: light)

        // Then
        #expect(eligible)
    }

    @Test("a successful re-enable apply restores a later opposite-side flip")
    func reenableApplyRestoresLaterOppositeSideFlip() {
        // Given
        var policy = AppearanceReloadPolicy()
        let disabledLight = AppearanceReloadContext(
            followsSystemAppearance: false,
            hasLightSlot: true,
            hasDarkSlot: true,
            currentSide: .light
        )
        let dark = AppearanceReloadContext(
            followsSystemAppearance: true,
            hasLightSlot: true,
            hasDarkSlot: true,
            currentSide: .dark
        )
        policy.recordAppliedColorSchemeSide(.dark)

        // When
        let disabledEventEligible = policy.isEligible(for: disabledLight)
        policy.recordAppliedColorSchemeSide(.light)
        let laterDarkEventEligible = policy.isEligible(for: dark)

        // Then
        #expect(!disabledEventEligible)
        #expect(laterDarkEventEligible)
    }
}
