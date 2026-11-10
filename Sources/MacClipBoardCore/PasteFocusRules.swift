import Foundation

/// How much of the destination's focus can be verified before Cmd+V is sent.
public enum PasteFocusPlan: Equatable, Sendable {
    /// The app exposes its focused input: it must still be that exact input.
    case element
    /// The app exposes no focused input (Chrome and Electron apps only build that tree for assistive
    /// technology), but it does expose its focused window: that window must still be the focused one.
    case window
    /// Nothing can be verified, so nothing is sent.
    case refuse
}

/// The decision to press Cmd+V lives here, away from Accessibility calls, so it can be tested and mutation-checked.
public enum PasteFocusRules {
    /// The most specific identity that was captured wins; a window is only a fallback for an app that hides its inputs.
    public static func plan(hasElement: Bool, hasWindow: Bool) -> PasteFocusPlan {
        if hasElement { return .element }
        return hasWindow ? .window : .refuse
    }

    /// Every condition must hold at the moment of sending.
    public static func mayPaste(plan: PasteFocusPlan, frontmostIsTarget: Bool, focusMatches: Bool, modifiersHeld: Bool) -> Bool {
        plan != .refuse && frontmostIsTarget && focusMatches && !modifiersHeld
    }
}
