import Testing
@testable import MacClipBoardCore

@Suite struct PasteFocusRulesTests {
    @Test func theExactInputIsPreferredAndTheWindowIsOnlyAFallback() {
        #expect(PasteFocusRules.plan(hasElement: true, hasWindow: true) == .element)
        #expect(PasteFocusRules.plan(hasElement: true, hasWindow: false) == .element)
        // Chrome and Electron: no focused input is exposed, but the window is.
        #expect(PasteFocusRules.plan(hasElement: false, hasWindow: true) == .window)
    }

    @Test func nothingCapturedMeansNothingIsSent() {
        #expect(PasteFocusRules.plan(hasElement: false, hasWindow: false) == .refuse)
        for frontmost in [true, false] { for matches in [true, false] { for held in [true, false] {
            #expect(!PasteFocusRules.mayPaste(plan: .refuse, frontmostIsTarget: frontmost, focusMatches: matches, modifiersHeld: held))
        } } }
    }

    @Test func pasteNeedsEveryConditionAtTheMomentOfSending() {
        for plan in [PasteFocusPlan.element, .window] {
            #expect(PasteFocusRules.mayPaste(plan: plan, frontmostIsTarget: true, focusMatches: true, modifiersHeld: false))
            #expect(!PasteFocusRules.mayPaste(plan: plan, frontmostIsTarget: false, focusMatches: true, modifiersHeld: false))
            #expect(!PasteFocusRules.mayPaste(plan: plan, frontmostIsTarget: true, focusMatches: false, modifiersHeld: false))
            #expect(!PasteFocusRules.mayPaste(plan: plan, frontmostIsTarget: true, focusMatches: true, modifiersHeld: true))
        }
    }
}
