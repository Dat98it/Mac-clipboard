import Testing
@testable import MacClipBoardCore

@Suite struct PanelToggleRulesTests {
    @Test func shortcutBringsAPanelLeftOnAnotherSpaceToTheCurrentOne() {
        // Visible and key, but on Space 1 while the user is on Space 2: show it here, never hide it.
        #expect(PanelToggleRules.hotkey(isVisible: true, isOnActiveSpace: false, isKey: true) == .show)
        #expect(PanelToggleRules.hotkey(isVisible: true, isOnActiveSpace: false, isKey: false) == .show)
    }

    @Test func shortcutHidesOnlyThePanelBeingUsed() {
        #expect(PanelToggleRules.hotkey(isVisible: true, isOnActiveSpace: true, isKey: true) == .hide)
        #expect(PanelToggleRules.hotkey(isVisible: true, isOnActiveSpace: true, isKey: false) == .show) // behind another window
        #expect(PanelToggleRules.hotkey(isVisible: false, isOnActiveSpace: true, isKey: false) == .show)
    }

    @Test func menuIconHidesOnThisSpaceAndShowsFromAnotherOne() {
        #expect(PanelToggleRules.statusItem(isVisible: true, isOnActiveSpace: true) == .hide)
        #expect(PanelToggleRules.statusItem(isVisible: true, isOnActiveSpace: false) == .show)
        #expect(PanelToggleRules.statusItem(isVisible: false, isOnActiveSpace: false) == .show)
    }
}
