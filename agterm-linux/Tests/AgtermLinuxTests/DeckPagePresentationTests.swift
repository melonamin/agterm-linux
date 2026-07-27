import Foundation
import Testing
@testable import AgtermLinux

@Suite("Linux terminal deck presentation")
struct DeckPagePresentationTests {
    @Test("normal mode maps and targets only the active session")
    func normalMode() {
        let active = DeckPagePresentation(isActive: true, dashboardOpen: false)
        #expect(active.childVisible)
        #expect(active.opacity == 1)
        #expect(active.canTarget)

        let inactive = DeckPagePresentation(isActive: false, dashboardOpen: false)
        #expect(!inactive.childVisible)
        #expect(inactive.opacity == 0)
        #expect(!inactive.canTarget)
    }

    @Test("dashboard renders every session beneath its opaque host without accepting input")
    func dashboardMode() {
        let active = DeckPagePresentation(isActive: true, dashboardOpen: true)
        #expect(active.childVisible)
        #expect(active.opacity == 1)
        #expect(!active.canTarget)

        let inactive = DeckPagePresentation(isActive: false, dashboardOpen: true)
        #expect(inactive.childVisible)
        #expect(inactive.opacity == 1)
        #expect(!inactive.canTarget)
    }

    @Test("no active session hides every page — the soft-closed-last-session case")
    func noActiveSession() {
        let page = UUID()
        // Soft-closing the last session takes it OUT of the tree (so nothing is active) while its surfaces
        // stay alive for the undo, so the page must go dark and untargetable rather than keep the selection
        // it had a moment ago.
        let held = DeckPagePresentation(pageID: page, activeID: nil, dashboardOpen: false)
        #expect(!held.childVisible)
        #expect(held.opacity == 0)
        #expect(!held.canTarget)

        // ...and the very same page is active again as soon as a session is selected.
        let selected = DeckPagePresentation(pageID: page, activeID: page, dashboardOpen: false)
        #expect(selected.childVisible)
        #expect(selected.canTarget)
        #expect(!DeckPagePresentation(pageID: page, activeID: UUID(), dashboardOpen: false).canTarget)
    }
}
