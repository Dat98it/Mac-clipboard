import AppKit
import ApplicationServices
import MacClipBoardCore

/// Stores AX object identities only, never the target's text or clipboard contents.
@MainActor public final class PasteRouter: PasteDelivering {
    private struct Destination {
        let application: NSRunningApplication
        let focusedElement: AXUIElement?
        let focusedWindow: AXUIElement?
    }
    private var destination: Destination?
    private var observer: NSObjectProtocol?
    private let clipboard: ClipboardAccess
    private let automaticPasteEnabled: Bool
    private let permissionCheck: () -> Bool
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    public init(clipboard: ClipboardAccess, automaticPasteEnabled: Bool = true,
                permissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.clipboard = clipboard; self.automaticPasteEnabled = automaticPasteEnabled
        self.permissionCheck = permissionCheck
    }
    public var hasPermission: Bool { permissionCheck() }
    public var destinationName: String? { destination?.application.localizedName }

    public func start() {
        guard observer == nil else { return }
        captureDestination()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.remember(app)
            }
        }
    }
    public func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil; destination = nil
    }
    public func captureDestination() {
        if let app = NSWorkspace.shared.frontmostApplication { remember(app) }
    }
    private func remember(_ app: NSRunningApplication) {
        guard app.processIdentifier != ownPID, app.activationPolicy == .regular else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        destination = Destination(application: app,
                                  focusedElement: hasPermission ? attribute(axApp, kAXFocusedUIElementAttribute) : nil,
                                  focusedWindow: hasPermission ? attribute(axApp, kAXFocusedWindowAttribute) : nil)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    public func paste(expectedChangeCount: Int, isCurrent: @escaping () -> Bool) async -> PasteOutcome {
        guard isCurrent() else { return .cancelled }
        guard automaticPasteEnabled else { return .eventUnavailable }
        guard hasPermission else { return .permissionRequired }
        guard let target = destination, !target.application.isTerminated,
              target.application.processIdentifier != ownPID else { return .noDestination }
        // Prefer the exact focused input. An app that hides its inputs from Accessibility (Chrome, Electron)
        // is verified by its focused window instead; if neither was captured there is nothing safe to check.
        let plan = PasteFocusRules.plan(hasElement: target.focusedElement != nil, hasWindow: target.focusedWindow != nil)
        guard plan != .refuse else { return .focusNotRestored }
        let pid = target.application.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        // macOS 14 activation is cooperative and asynchronous. In particular, ordering out a
        // nonactivating panel can hand key focus back to an app other than our captured target.
        NSApp.yieldActivation(to: target.application)
        _ = target.application.activate(from: .current, options: [])
        // Accessibility explicitly authorizes restoring this captured application's focus.
        // A rejected activation request is not sufficient reason to give up if AX can restore it.
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        var raisedWindow = false
        for _ in 0..<20 {
            guard isCurrent() else { return .cancelled }
            guard clipboard.changeCount == expectedChangeCount else { return .clipboardChanged }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                if !raisedWindow {
                    if let window = target.focusedWindow { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
                    raisedWindow = true
                }
                let matches: Bool
                switch plan {
                case .element:
                    matches = target.focusedElement.flatMap { element in
                        attribute(appElement, kAXFocusedUIElementAttribute).map { CFEqual($0, element) }
                    } ?? false
                case .window:
                    matches = target.focusedWindow.flatMap { window in
                        attribute(appElement, kAXFocusedWindowAttribute).map { CFEqual($0, window) }
                    } ?? false
                case .refuse:
                    matches = false
                }
                // Do not send while the physical click/shortcut still has modifiers held down.
                let held = CGEventSource.flagsState(.combinedSessionState)
                    .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                if PasteFocusRules.mayPaste(plan: plan, frontmostIsTarget: true, focusMatches: matches, modifiersHeld: !held.isEmpty) {
                    return sendPaste(to: pid, expectedChangeCount: expectedChangeCount, isCurrent: isCurrent)
                }
                if !matches, plan == .element, let element = target.focusedElement {
                    // Restore only after activation has completed; some editors reject this
                    // attribute while inactive. Never read or set the editor's value/selection.
                    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                }
            }
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return .cancelled }
        }
        return .focusNotRestored
    }
    private func sendPaste(to pid: pid_t, expectedChangeCount: Int, isCurrent: () -> Bool) -> PasteOutcome {
        guard isCurrent() else { return .cancelled }
        guard hasPermission else { return .permissionRequired }
        guard clipboard.changeCount == expectedChangeCount else { return .clipboardChanged }
        guard pid != ownPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return .focusNotRestored }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return .eventUnavailable }
        down.flags = .maskCommand; up.flags = .maskCommand
        // PID-specific events cannot land in Mac ClipBoard or a third app that steals global focus.
        down.postToPid(pid); up.postToPid(pid)
        // Quartz provides no acknowledgement from the receiving editor. Never claim that text was inserted.
        return .commandSent
    }
    public func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
