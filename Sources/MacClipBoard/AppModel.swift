import AppKit
import MacClipBoardCore
import MacClipBoardSystem

@MainActor final class AppModel: ObservableObject {
    let session: ClipboardSession
    let router: PasteRouter
    let monitor = ClipboardMonitor()
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var message = ""
    @Published private(set) var hasPermission = false
    @Published private(set) var destinationName: String?
    @Published private(set) var busy = true
    @Published private(set) var paused = false
    @Published private(set) var pasting = false
    @Published var filter = ""
    @Published private(set) var selectedID: UUID?
    @Published var canUninstall = false
    @Published var uninstallExplanation = ""
    @Published private(set) var preferences: Preferences
    /// What the Settings sheet is editing; nothing changes until Apply.
    @Published var draft: Preferences
    @Published var showingSettings = false
    @Published private(set) var loginState: LaunchAtLogin.State = .unavailable
    @Published private(set) var settingsError = ""
    @Published private(set) var loginError = ""
    @Published private(set) var hotkeyStatus: HotkeyStatus = .off
    /// The row under the mouse pointer, kept here because `@State` is not available in this toolchain.
    @Published private(set) var hoveredID: UUID?
    var hotkeys: HotkeyController?
    private let preferencesStore: PreferencesStore
    let launchAtLogin: LaunchAtLogin?
    private var uninstalling = false
    // Thumbnails are memory-only and pruned with the history, so a deleted or cleared image leaves nothing behind.
    private var thumbnails: [UUID: NSImage] = [:]
    private var thumbnailRequests = Set<UUID>()
    private var thumbnailFailures = Set<UUID>()
    var requestUninstall: (() -> Void)?
    var willPaste: (() -> Void)?
    var pasteNeedsAttention: (() -> Void)?

    init(clipboard: ClipboardAccess, store: HistoryPersisting, isolated: Bool,
         preferencesStore: PreferencesStore, preferences: Preferences, launchAtLogin: LaunchAtLogin?) {
        self.preferencesStore = preferencesStore; self.preferences = preferences; draft = preferences
        self.launchAtLogin = launchAtLogin
        session = ClipboardSession(clipboard: clipboard, store: store, limits: preferences.limits)
        router = PasteRouter(clipboard: clipboard, automaticPasteEnabled: !isolated)
        session.onChange = { [weak self] in self?.refresh() }
    }
    func start() async {
        router.start()
        await session.start()
        monitor.start { [weak self] in self?.session.poll() }
        refresh()
    }
    func stop() async {
        session.cancelPendingPaste()
        monitor.stop(); router.stop()
        await session.flush()
    }
    func prepareForUninstall() async {
        uninstalling = true; refresh()
        await stop()
    }
    func recoverFromUninstallFailure() async {
        uninstalling = false
        await start()
    }
    func setHover(_ id: UUID, inside: Bool) {
        if inside { hoveredID = id } else if hoveredID == id { hoveredID = nil }
    }
    /// Registers the chosen shortcut (or releases it). Called at launch and after Apply.
    func applyHotkey() {
        hotkeyStatus = hotkeys?.apply(preferences.hotkey) ?? .off
    }
    var hotkeyExplanation: String {
        guard hotkeys != nil else { return L("The shortcut is disabled in test environments.") }
        switch hotkeyStatus {
        case .off: return L("Shows or hides the history from any app. No extra permission is needed.")
        case .registered(let choice): return String(format: L("Registered: %@. Press it again to hide the history."), choice.symbols)
        case .unavailable(let choice):
            return String(format: L("Could not register %@: another app is probably using it. Pick another shortcut."), choice.symbols)
        }
    }
    func prepareToShow() {
        router.captureDestination()
        selectedID = nil
        refresh()
    }
    func refresh() {
        entries = session.entries
        hasPermission = router.hasPermission
        destinationName = router.destinationName
        busy = session.isLoading || session.isClearing || uninstalling
        paused = session.isPaused
        pasting = session.isPasting
        message = describe(session.notice)
        loginState = launchAtLogin?.state ?? .unavailable
        let ids = Set(entries.map { $0.id })
        thumbnails = thumbnails.filter { ids.contains($0.key) }
        thumbnailFailures.formIntersection(ids)
        if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
    }
    /// Returns the cached thumbnail, or starts decoding it off the main thread and returns nil until it is ready.
    func thumbnail(for entry: ClipboardEntry) -> NSImage? {
        if let image = thumbnails[entry.id] { return image }
        guard let data = entry.payload.imageData, !thumbnailFailures.contains(entry.id),
              thumbnailRequests.insert(entry.id).inserted else { return nil }
        let id = entry.id
        Task.detached(priority: .utility) { [weak self] in
            let image = Thumbnailer.makeThumbnail(from: data, maxPixelSize: 128)
            await self?.finishThumbnail(id: id, image: image)
        }
        return nil
    }
    private func finishThumbnail(id: UUID, image: CGImage?) {
        thumbnailRequests.remove(id)
        guard entries.contains(where: { $0.id == id }) else { return }
        if let image {
            thumbnails[id] = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
        } else { thumbnailFailures.insert(id) }
        objectWillChange.send()
    }
    /// Pinned items first, each group newest first.
    var visibleEntries: [ClipboardEntry] {
        let matching = filter.isEmpty ? entries : entries.filter { $0.payload.preview.localizedCaseInsensitiveContains(filter) }
        return matching.filter { $0.isPinned } + matching.filter { !$0.isPinned }
    }
    var totalBytes: Int { entries.reduce(0) { $0 + $1.payload.byteCount } }
    func select(_ entry: ClipboardEntry) {
        guard !busy, !pasting else { return }
        if hasPermission, destinationName != nil { willPaste?() }
        Task {
            await session.select(entry.id, paster: router)
            if session.notice != .paste(.commandSent) { pasteNeedsAttention?() }
        }
    }
    func delete(_ entry: ClipboardEntry) {
        guard !busy else { return }
        if selectedID == entry.id { selectedID = ListSelection.neighbour(afterRemoving: entry.id, in: visibleEntries.map { $0.id }) }
        session.delete(entry.id)
    }
    /// Arrow keys. Returns false when there is nothing to move through, so the key keeps its normal meaning.
    func moveSelection(by delta: Int) -> Bool {
        guard !busy, let next = ListSelection.moved(from: selectedID, in: visibleEntries.map { $0.id }, by: delta) else { return false }
        selectedID = next
        return true
    }
    /// Return/Enter: paste the highlighted item. Does nothing (and returns false) without a highlighted item.
    func activateSelection() -> Bool {
        guard let entry = visibleEntries.first(where: { $0.id == selectedID }) else { return false }
        select(entry)
        return true
    }
    func togglePin(_ entry: ClipboardEntry) {
        guard !busy else { return }
        session.setPinned(entry.id, !entry.isPinned)
    }
    var limits: HistoryLimits { session.limits }
    /// Items the draft limits would drop right now; shown before Apply because it cannot be undone.
    var draftRemovalCount: Int { session.entriesRemoved(under: draft.limits) }
    func openSettings() {
        draft = preferences; settingsError = ""; loginError = ""
        refresh()
        showingSettings = true
    }
    func applySettings() {
        guard !busy, draft != preferences else { return }
        preferences = draft
        session.setLimits(preferences.limits)
        applyHotkey()
        do { try preferencesStore.save(preferences); settingsError = ""; showingSettings = false }
        catch { settingsError = L("Settings could not be saved. They apply until you quit.") }
        refresh()
    }
    /// Menu item and Settings toggle share this; the caller shows an alert for `.failed`.
    @discardableResult
    func toggleLaunchAtLogin() -> LaunchAtLogin.Outcome {
        guard let launchAtLogin else { return .unavailable }
        let outcome = launchAtLogin.toggle()
        switch outcome {
        case .failed(let message): loginError = message
        case .unavailable: loginError = L("macOS did not confirm the change. Check System Settings → General → Login Items.")
        default: loginError = ""
        }
        refresh()
        return outcome
    }
    var loginExplanation: String {
        switch loginState {
        case .on, .off: return L("Starts Mac ClipBoard when you log in, hidden in the menu bar. Off by default.")
        case .needsApproval: return L("Waiting for your approval in System Settings → General → Login Items.")
        case .unavailable: return L("Launch at Login is disabled in test environments.")
        }
    }
    func clearAll() {
        filter = ""
        Task { await session.clearAll() }
    }
    func togglePaused() { session.setPaused(!session.isPaused) }
    func describe(_ notice: SessionNotice) -> String {
        switch notice {
        case .ready: return L("Copy something to start your history.")
        case .saved: return L("Saved locally. Click an item to paste.")
        case .privateContentSkipped: return L("Private or temporary clipboard content was skipped.")
        case .unsupportedSkipped: return L("This clipboard format cannot be saved. The clipboard was left unchanged.")
        case .tooLargeSkipped: return L("Copy exceeds the 8 MiB limit and was not saved. The clipboard was left unchanged.")
        case .storageFailed: return L("History could not be saved. Recent items may be lost when you quit.")
        case .loadFailed: return L("Saved history could not be read. Monitoring is paused. Clear All to reset, or resume to start a new history.")
        case .cleared: return L("History and system clipboard cleared.")
        case .clearFailed: return L("Memory and clipboard cleared, but saved history could not be removed. Monitoring is paused. Retry Clear All before quitting.")
        case .itemDeleted: return L("Removed from history. The system clipboard was not changed.")
        case .pinLimitReached:
            return String(format: L("You can pin up to %d items or %d MiB. Unpin one first."),
                          session.limits.maxPinnedEntries, session.limits.maxPinnedBytes / (1024 * 1024))
        case .restoreFailed: return L("The item could not be copied to the clipboard. Nothing was pasted.")
        case .fileAccessDenied:
            return L("Mac ClipBoard is not allowed to read this file, so the app you paste into would receive nothing. Allow it in System Settings → Privacy & Security → Files & Folders (or Full Disk Access), then select the item again.")
        case .paste(let outcome):
            switch outcome {
            case .commandSent: return L("Cmd+V sent to the previous app. If it did not paste, press Cmd+V there.")
            case .permissionRequired: return L("Copied to clipboard. Enable Accessibility for automatic paste, or switch back and press Cmd+V.")
            case .noDestination: return L("Copied to clipboard. Open the destination editor, then press Cmd+V.")
            case .focusNotRestored: return L("Copied to clipboard. The previous input could not be focused safely. Switch back and press Cmd+V.")
            case .clipboardChanged: return L("The clipboard changed before paste. Select the item again.")
            case .cancelled: return L("Automatic paste cancelled. No paste command was sent.")
            case .eventUnavailable: return L("Copied to clipboard. Automatic paste is unavailable. Switch back and press Cmd+V.")
            }
        }
    }
}

func L(_ key: String) -> String { NSLocalizedString(key, bundle: .main, comment: "") }
func bytes(_ count: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary) }
