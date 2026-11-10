import Foundation

public enum CaptureResult: Equatable {
    case payload(ClipboardPayload), empty, privateContent, unsupported, tooLarge, changedDuringRead
}

/// Whether restoring can possibly work. Files are handed to the destination app through the clipboard, and macOS only
/// lets that app read them when the app WRITING the clipboard can read them itself.
public enum RestorePreparation: Equatable, Sendable { case ready, fileAccessDenied }

@MainActor public protocol ClipboardAccess: AnyObject {
    var changeCount: Int { get }
    func capture(limits: HistoryLimits) -> CaptureResult
    /// Called before `restore`. May take as long as the user takes to answer a macOS permission prompt.
    func prepareRestore(_ payload: ClipboardPayload) async -> RestorePreparation
    func restore(_ payload: ClipboardPayload) -> Bool
    func clear()
}

public protocol HistoryPersisting: AnyObject, Sendable {
    func load() async throws -> [ClipboardEntry]
    /// Revisions ensure a delayed write can never restore entries removed by Clear All.
    func save(_ entries: [ClipboardEntry], revision: UInt64) async throws
    func clear(revision: UInt64) async throws
}

public enum PasteOutcome: Equatable, Sendable {
    case commandSent, permissionRequired, noDestination, focusNotRestored, clipboardChanged, cancelled, eventUnavailable
}

@MainActor public protocol PasteDelivering: AnyObject {
    func paste(expectedChangeCount: Int, isCurrent: @escaping () -> Bool) async -> PasteOutcome
}

public enum SessionNotice: Equatable {
    case ready, saved, privateContentSkipped, unsupportedSkipped, tooLargeSkipped
    case storageFailed, loadFailed, cleared, clearFailed, restoreFailed, fileAccessDenied
    case itemDeleted, pinLimitReached
    case paste(PasteOutcome)
}

/// All in-memory mutations run on the main actor. Disk writes are versioned and debounced.
/// No clipboard contents or underlying error descriptions are logged or exposed in notices.
@MainActor public final class ClipboardSession {
    public private(set) var entries: [ClipboardEntry] = []
    public private(set) var notice: SessionNotice = .ready
    public private(set) var isLoading = false
    public private(set) var isClearing = false
    public private(set) var isPasting = false
    public private(set) var isPaused = false
    public var onChange: (() -> Void)?
    public private(set) var limits: HistoryLimits
    private let clipboard: ClipboardAccess
    private let store: HistoryPersisting
    private var observedCount: Int
    private var revision: UInt64 = 0
    private var operation: UInt64 = 0
    private var hasStarted = false
    private var saveTask: Task<Void, Never>?

    public init(clipboard: ClipboardAccess, store: HistoryPersisting, limits: HistoryLimits = HistoryLimits()) {
        self.clipboard = clipboard; self.store = store; self.limits = limits
        observedCount = clipboard.changeCount // Metadata only: never read the startup clipboard.
    }

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        observedCount = clipboard.changeCount
        isLoading = true; onChange?()
        let initialRevision = revision
        do {
            let loaded = try await store.load()
            if revision == initialRevision { entries = limits.bounded(loaded) }
        } catch { notice = .loadFailed; isPaused = true }
        isLoading = false; onChange?()
    }

    public func poll() {
        guard hasStarted, !isLoading, !isPaused, !isClearing else { return }
        let count = clipboard.changeCount
        guard count != observedCount else { return }
        let result = clipboard.capture(limits: limits)
        // Retry a racing writer on the next tick; never associate bytes with the wrong change.
        if result == .changedDuringRead { return }
        observedCount = count
        switch result {
        case .payload(let payload):
            guard payload.isValid(limits: limits) else { notice = .unsupportedSkipped; onChange?(); return }
            // Copying a pinned item again must not silently unpin it.
            let wasPinned = entries.contains { $0.payload == payload && $0.isPinned }
            entries.removeAll { $0.payload == payload }
            entries.insert(ClipboardEntry(payload: payload, isPinned: wasPinned), at: 0)
            entries = limits.bounded(entries)
            notice = .saved
            revision += 1
            scheduleSave()
        case .empty: break
        case .privateContent: notice = .privateContentSkipped
        case .unsupported: notice = .unsupportedSkipped
        case .tooLarge: notice = .tooLargeSkipped
        case .changedDuringRead: break
        }
        onChange?()
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
        // Resuming never reads material copied during the pause.
        observedCount = clipboard.changeCount
        onChange?()
    }

    public func cancelPendingPaste() {
        operation += 1
        isPasting = false
        onChange?()
    }

    public func select(_ id: UUID, paster: PasteDelivering) async {
        guard !isClearing, !isLoading, let entry = entries.first(where: { $0.id == id }) else { return }
        operation += 1
        let token = operation
        // Busy from the first moment: macOS may be asking the user for file access, and a second click must not queue behind it.
        isPasting = true; onChange?()
        let preparation = await clipboard.prepareRestore(entry.payload)
        guard operation == token else { return }
        // Without access the destination would receive an empty clipboard and nothing would visibly happen,
        // so say so and leave the clipboard as it was.
        guard preparation == .ready else { isPasting = false; notice = .fileAccessDenied; onChange?(); return }
        let restored = clipboard.restore(entry.payload)
        observedCount = clipboard.changeCount // Suppress only our own write, not a future user copy.
        guard restored else { isPasting = false; notice = .restoreFailed; onChange?(); return }
        let expected = observedCount
        let outcome = await paster.paste(expectedChangeCount: expected) { [weak self] in
            guard let self else { return false }
            return self.operation == token && !self.isClearing
        }
        guard operation == token else { return }
        isPasting = false
        notice = .paste(outcome); onChange?()
    }

    /// Removes one history item. The system clipboard is not touched.
    public func delete(_ id: UUID) {
        guard !isClearing, !isLoading, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        notice = .itemDeleted
        revision += 1
        scheduleSave()
        onChange?()
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard !isClearing, !isLoading, let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].isPinned != pinned else { return }
        if pinned {
            let current = entries.filter { $0.isPinned }
            let bytes = current.reduce(0) { $0 + $1.payload.byteCount } + entries[index].payload.byteCount
            guard current.count < limits.maxPinnedEntries, bytes <= limits.maxPinnedBytes else {
                notice = .pinLimitReached; onChange?(); return
            }
        }
        entries[index] = entries[index].pinned(pinned)
        revision += 1
        scheduleSave()
        onChange?()
    }

    /// How many items would be dropped if `candidate` were applied now. Lets the UI warn before anything is lost.
    public func entriesRemoved(under candidate: HistoryLimits) -> Int {
        entries.count - candidate.bounded(entries).count
    }

    /// Applies new limits at once; items that no longer fit are dropped (oldest unpinned first, pinned kept first).
    public func setLimits(_ newLimits: HistoryLimits) {
        guard !isLoading, !isClearing else { return }
        limits = newLimits
        let bounded = newLimits.bounded(entries)
        if bounded != entries {
            entries = bounded
            revision += 1
            scheduleSave()
        }
        onChange?()
    }

    public func clearAll() async {
        guard !isClearing else { return }
        operation += 1; revision += 1
        let clearRevision = revision
        saveTask?.cancel(); saveTask = nil
        isClearing = true; isPasting = false
        entries = []
        clipboard.clear()
        observedCount = clipboard.changeCount
        onChange?() // Empty immediately, before any disk I/O.
        do {
            try await store.clear(revision: clearRevision)
            notice = .cleared
        } catch {
            notice = .clearFailed
            isPaused = true // Do not silently overwrite a failed deletion with new history.
        }
        isClearing = false; onChange?()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = entries, version = revision, store = store
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                try Task.checkCancellation()
                try await store.save(snapshot, revision: version)
            } catch is CancellationError { return }
            catch {
                guard let self, self.revision == version else { return }
                self.notice = .storageFailed; self.onChange?()
            }
        }
    }

    public func flush() async {
        saveTask?.cancel(); saveTask = nil
        // Retrying Clear All must stay possible after a disk failure. Do not claim a successful flush.
        guard notice != .clearFailed, !isLoading else { return }
        let version = revision
        do { try await store.save(entries, revision: version) }
        catch { notice = .storageFailed; onChange?() }
    }
}
