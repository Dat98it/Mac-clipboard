import AppKit
import SwiftUI
import MacClipBoardCore
import MacClipBoardSystem

/// Menu bar + a single window, following AppClean. The nonactivating panel follows ShelfDrop's
/// ShelfPanel pattern to preserve the source editor's focus when clicking the status item.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let isolated: Bool
    private let store: FileHistoryStore
    private let uninstaller: SelfUninstaller
    private var statusItem: NSStatusItem!
    private var window: HistoryPanel?
    private var observer: NSObjectProtocol?
    private var terminating = false

    private let hotkeyAllowed: Bool

    init(clipboard: ClipboardAccess, store: FileHistoryStore, isolated: Bool,
         preferencesStore: PreferencesStore, preferences: Preferences, launchAtLogin: LaunchAtLogin?, hotkeyAllowed: Bool) {
        self.hotkeyAllowed = hotkeyAllowed
        model = AppModel(clipboard: clipboard, store: store, isolated: isolated,
                         preferencesStore: preferencesStore, preferences: preferences, launchAtLogin: launchAtLogin)
        self.isolated = isolated
        self.store = store
        uninstaller = SelfUninstaller(historyDirectory: store.directory,
                                    testEnvironment: isolated || CommandLine.arguments.contains("--test-system-clipboard"),
                                    loginItem: launchAtLogin?.service)
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let button = statusItem.button!
        button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Mac ClipBoard")
        button.image?.isTemplate = true
        button.toolTip = "Mac ClipBoard"
        button.target = self; button.action = #selector(statusClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        installMainMenu()
        if hotkeyAllowed {
            model.hotkeys = HotkeyController(service: GlobalHotKey(), onPress: { [weak self] in self?.toggleFromHotkey() })
            model.applyHotkey()
        }
        model.willPaste = { [weak self] in self?.window?.orderOut(nil) }
        model.pasteNeedsAttention = { [weak self] in self?.showWindow(preserveDestination: true) }
        model.requestUninstall = { [weak self] in self?.uninstallSelf() }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        }
        Task {
            await model.start()
            if !CommandLine.arguments.contains("--background"), !Self.launchedAsLoginItem { showWindow() }
            // Test aid, sandbox only: show the Settings sheet without needing a click.
            if isolated, CommandLine.arguments.contains("--open-settings") { model.openSettings() }
        }
    }
    /// A login-item launch arrives as an "open application" event tagged `lgit`. Then stay in the menu bar
    /// instead of opening the history window on every login.
    static var launchedAsLoginItem: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: L("Open History"), action: #selector(openHistory), keyEquivalent: "").target = self
            menu.addItem(withTitle: L(model.paused ? "Resume" : "Pause"), action: #selector(togglePause), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
            let login = menu.addItem(withTitle: L("Launch at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            login.target = self
            login.state = model.loginState == .on ? .on : (model.loginState == .needsApproval ? .mixed : .off)
            login.isEnabled = model.loginState != .unavailable
            menu.addItem(.separator())
            let uninstall = menu.addItem(withTitle: L("Uninstall…"), action: #selector(uninstallSelf), keyEquivalent: "")
            uninstall.target = self
            uninstall.isEnabled = uninstaller.availability == .available
            menu.addItem(.separator())
            menu.addItem(withTitle: L("Quit Mac ClipBoard"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if window?.isVisible == true {
            window?.orderOut(nil)
        } else { showWindow() }
    }
    @objc func openHistory() { showWindow() }
    /// The global shortcut: hide the history when it is the window being used, otherwise bring it up.
    /// Showing it records the frontmost app as the paste destination, so it works from any app.
    func toggleFromHotkey() {
        if let window, window.isVisible, window.isKeyWindow { window.orderOut(nil) } else { showWindow() }
    }
    @objc func togglePause() { model.togglePaused() }
    @objc func openSettings() {
        showWindow()
        model.openSettings()
    }
    @objc func toggleLaunchAtLogin() {
        model.toggleLaunchAtLogin()
        if !model.loginError.isEmpty { showAlert(L("Launch at Login could not be changed"), model.loginError) }
    }
    func showWindow(preserveDestination: Bool = false) {
        if !preserveDestination { model.prepareToShow() }
        model.canUninstall = uninstaller.availability == .available
        model.uninstallExplanation = uninstallReason(uninstaller.availability)
        if window == nil {
            let panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 730),
                                     styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = isolated ? "Mac ClipBoard — Test" : "Mac ClipBoard"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.level = .normal
            panel.contentMinSize = NSSize(width: 480, height: 540)
            panel.contentView = NSHostingView(rootView: HistoryView(model: model, isolated: isolated))
            panel.onBeforeInteraction = { [weak self] in self?.model.router.captureDestination() }
            panel.onKey = { [weak self] key in
                guard let model = self?.model else { return false }
                switch key {
                case .up: return model.moveSelection(by: -1)
                case .down: return model.moveSelection(by: 1)
                case .activate: return model.activateSelection()
                }
            }
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func uninstallReason(_ state: SelfUninstallRules.Availability) -> String {
        switch state {
        case .available: return L("Move this app and its saved history to the Trash")
        case .developmentBuild: return L("Uninstall is available only from a built .app bundle.")
        case .wrongApplication: return L("This bundle is not Mac ClipBoard. Uninstall is blocked.")
        case .readOnlyVolume: return L("This copy is on a read-only volume. Install it in Applications first.")
        case .notDeletable: return L("This account cannot move this copy to the Trash.")
        case .testEnvironment: return L("Uninstall is disabled in test environments.")
        }
    }

    @objc func uninstallSelf() {
        let availability = uninstaller.availability
        guard availability == .available else { showAlert(L("Cannot uninstall Mac ClipBoard"), uninstallReason(availability)); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Uninstall Mac ClipBoard?")
        var explanation = String(format: L("Mac ClipBoard will stop monitoring and move this app (%@) and its saved history to the Trash, then quit. The current system clipboard is kept. You can restore the app and history from the Trash."), uninstaller.bundleURL.path)
        if model.loginState == .on || model.loginState == .needsApproval { explanation += " " + L("Launch at Login will be turned off.") }
        alert.informativeText = explanation
        // Cancel is the default, including Return/Escape. The destructive action needs an explicit click.
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Uninstall"))
        alert.buttons[1].hasDestructiveAction = true
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            MainActor.assumeIsolated { self?.performUninstall() }
        }
    }

    func performUninstall() {
        Task {
            await model.prepareForUninstall()
            await store.freezeWrites()
            switch uninstaller.uninstall() {
            case .removed(let historyMoved):
                // Blocking on purpose: the app quits right after, so a sheet would never be seen.
                var warnings: [String] = []
                if !historyMoved {
                    warnings.append(L("Saved history could not be moved. Remove ~/Library/Application Support/local.macclipboard.app manually if needed."))
                }
                if uninstaller.loginItemRemovalFailed {
                    warnings.append(L("Couldn't turn off Launch at Login. Remove it in System Settings → General → Login Items."))
                }
                if !warnings.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = L("App moved to the Trash")
                    alert.informativeText = warnings.joined(separator: "\n\n")
                    alert.runModal()
                }
                // Do not run another flush on termination: it would recreate the trashed history.
                terminating = true
                if let observer { NotificationCenter.default.removeObserver(observer) }
                NSApp.terminate(nil)
            case .refused(let state):
                await store.resumeWrites()
                await model.recoverFromUninstallFailure()
                showAlert(L("Cannot uninstall Mac ClipBoard"), uninstallReason(state))
            case .trashFailed:
                await store.resumeWrites()
                await model.recoverFromUninstallFailure()
                showAlert(L("Cannot uninstall Mac ClipBoard"), L("The app could not be moved to the Trash. It is still installed and can be used again."))
            }
        }
    }

    func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    func installMainMenu() {
        let main = NSMenu(), appMenu = NSMenu(), editMenu = NSMenu()
        let appItem = NSMenuItem(), editItem = NSMenuItem()
        appItem.submenu = appMenu; editItem.submenu = editMenu
        main.addItem(appItem); main.addItem(editItem)
        appMenu.addItem(withTitle: L("Open History"), action: #selector(openHistory), keyEquivalent: "1").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit Mac ClipBoard"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        editItem.title = L("Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: L(title), action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = main
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateNow }
        terminating = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        Task { await model.stop(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

enum PanelKey { case up, down, activate }

final class HistoryPanel: NSPanel {
    var onBeforeInteraction: (() -> Void)?
    /// Return true when the key was used, so it is not also delivered to the focused control.
    var onKey: ((PanelKey) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
    override func sendEvent(_ event: NSEvent) {
        // The editor's field/caret may have changed while history remained visible.
        if event.type == .leftMouseDown { onBeforeInteraction?() }
        if event.type == .keyDown, let key = panelKey(for: event), onKey?(key) == true { return }
        super.sendEvent(event)
    }
    private func panelKey(for event: NSEvent) -> PanelKey? {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        // While an input method is composing (Telex/VNI candidates), arrows and Return belong to it.
        if let text = firstResponder as? NSTextView, text.hasMarkedText() { return nil }
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .activate
        default: return nil
        }
    }
}
