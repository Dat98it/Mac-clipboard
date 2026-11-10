import Foundation

/// When to show or hide the history panel. A panel left open on another Space is still "visible" to AppKit,
/// so treating that as visible made the shortcut and the menu icon hide a panel the user could not see
/// (and never bring it to the Space they were on).
public enum PanelToggleRules {
    public enum Action: Equatable { case show, hide }

    /// The global shortcut hides only the panel the user is actually using: on this Space and key.
    public static func hotkey(isVisible: Bool, isOnActiveSpace: Bool, isKey: Bool) -> Action {
        isVisible && isOnActiveSpace && isKey ? .hide : .show
    }

    /// The menu icon hides a panel that is showing on this Space; from another Space it brings the panel here.
    public static func statusItem(isVisible: Bool, isOnActiveSpace: Bool) -> Action {
        isVisible && isOnActiveSpace ? .hide : .show
    }
}
