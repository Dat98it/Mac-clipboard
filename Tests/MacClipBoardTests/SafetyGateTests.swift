import AppKit
import Foundation
import Testing
@testable import MacClipBoardCore
@testable import MacClipBoardSystem

// Tests added after Scripts/mutate.py showed that these guards could be removed without any test failing.

/// A store that records every call, can hold `load` open, and can fail on demand.
actor ProbeHistory: HistoryPersisting {
    private let initial: [ClipboardEntry]
    private let gateLoad: Bool
    private let failLoad: Bool
    private let failClear: Bool
    private var loadGate: CheckedContinuation<Void, Never>?
    private(set) var saves: [UInt64] = []
    private(set) var clears: [UInt64] = []
    enum Failure: Error { case disk }
    init(initial: [ClipboardEntry] = [], gateLoad: Bool = false, failLoad: Bool = false, failClear: Bool = false) {
        self.initial = initial; self.gateLoad = gateLoad; self.failLoad = failLoad; self.failClear = failClear
    }
    var isLoadWaiting: Bool { loadGate != nil }
    func load() async throws -> [ClipboardEntry] {
        if failLoad { throw Failure.disk }
        if gateLoad { await withCheckedContinuation { loadGate = $0 } }
        return initial
    }
    func save(_ entries: [ClipboardEntry], revision: UInt64) throws { saves.append(revision) }
    func clear(revision: UInt64) throws { clears.append(revision); if failClear { throw Failure.disk } }
    func releaseLoad() { loadGate?.resume(); loadGate = nil }
}

@MainActor final class ProbePaster: PasteDelivering {
    var beforeReturn: (() async -> Void)?
    var currentWhenFinished: Bool?
    func paste(expectedChangeCount: Int, isCurrent: @escaping () -> Bool) async -> PasteOutcome {
        await beforeReturn?()
        currentWhenFinished = isCurrent()
        return .commandSent
    }
}

@Suite @MainActor struct SessionGateTests {
    func entry(_ text: String) -> ClipboardEntry { ClipboardEntry(payload: payload(text)) }

    @Test func copiesDuringLoadAreIgnoredAndTheSavedHistorySurvives() async {
        let board = FakeClipboard(), store = ProbeHistory(initial: [entry("Saved before")], gateLoad: true)
        let session = ClipboardSession(clipboard: board, store: store)
        let starting = Task { await session.start() }
        while !(await store.isLoadWaiting) { await Task.yield() }
        board.copy("Copied while loading"); session.poll()
        #expect(board.captureCalls == 0)
        await store.releaseLoad()
        await starting.value
        #expect(session.entries.map { $0.payload.preview } == ["Saved before"])
    }

    @Test func clearAllDuringLoadWinsOverTheLoadedHistory() async {
        let board = FakeClipboard(), store = ProbeHistory(initial: [entry("Old history")], gateLoad: true)
        let session = ClipboardSession(clipboard: board, store: store)
        let starting = Task { await session.start() }
        while !(await store.isLoadWaiting) { await Task.yield() }
        await session.clearAll()
        await store.releaseLoad()
        await starting.value
        #expect(session.entries.isEmpty)
    }

    @Test func copiesWhileClearAllIsInFlightAreNotCaptured() async {
        let board = FakeClipboard(), store = GatedClearHistory()
        let session = ClipboardSession(clipboard: board, store: store)
        await session.start()
        board.copy("Before clear"); session.poll()
        let clearing = Task { await session.clearAll() }
        while !(await store.isWaiting) { await Task.yield() }
        let calls = board.captureCalls
        board.copy("During clear"); session.poll()
        #expect(board.captureCalls == calls)
        #expect(session.entries.isEmpty)
        await store.release()
        await clearing.value
    }

    @Test func unreadableHistoryPausesMonitoringAndSaysSo() async {
        let board = FakeClipboard(), session = ClipboardSession(clipboard: board, store: ProbeHistory(failLoad: true))
        await session.start()
        #expect(session.notice == .loadFailed)
        #expect(session.isPaused)
        board.copy("Must not be captured"); session.poll()
        #expect(board.captureCalls == 0)
    }

    @Test func loadedHistoryIsBoundedByTheCurrentLimits() async {
        let board = FakeClipboard()
        let store = ProbeHistory(initial: ["A", "B", "C", "D", "E"].map(entry))
        let session = ClipboardSession(clipboard: board, store: store,
                                       limits: HistoryLimits(maxEntries: 2, maxTotalBytes: 100, maxEntryBytes: 10))
        await session.start()
        #expect(session.entries.map { $0.payload.preview } == ["A", "B"])
    }

    @Test func clearAllCancelsASaveThatWasStillWaiting() async {
        let board = FakeClipboard(), store = ProbeHistory()
        let session = ClipboardSession(clipboard: board, store: store)
        await session.start()
        board.copy("Queued for saving"); session.poll() // schedules a debounced save
        await session.clearAll()
        try? await Task.sleep(nanoseconds: 700_000_000) // longer than the 350 ms debounce
        #expect(await store.saves.isEmpty)
        #expect(await store.clears.count == 1)
    }

    @Test func flushNeverWritesAfterAFailedClearSoClearCanBeRetried() async {
        let board = FakeClipboard(), store = ProbeHistory(failClear: true)
        let session = ClipboardSession(clipboard: board, store: store)
        await session.start()
        board.copy("Something"); session.poll()
        await session.clearAll()
        #expect(session.notice == .clearFailed)
        await session.flush()
        #expect(await store.saves.isEmpty)
    }

    @Test func aPasteIsToldItIsStaleOnceClearAllRuns() async {
        let board = FakeClipboard(), session = ClipboardSession(clipboard: board, store: MemoryHistory()), paster = ProbePaster()
        await session.start(); board.copy("Item"); session.poll()
        paster.beforeReturn = { await session.clearAll() }
        await session.select(session.entries[0].id, paster: paster)
        #expect(paster.currentWhenFinished == false)
    }
}

@Suite struct LimitGateTests {
    func entry(_ text: String, pinned: Bool = false, id: UUID = UUID()) -> ClipboardEntry {
        ClipboardEntry(id: id, payload: payload(text), isPinned: pinned)
    }

    @Test func pinnedItemsStayWithinTheirByteShare() {
        let limits = HistoryLimits(maxEntries: 10, maxTotalBytes: 10, maxEntryBytes: 5, maxPinnedEntries: 5) // pinned share: 5 bytes
        let kept = limits.bounded([entry("AAA", pinned: true), entry("BBB", pinned: true)])
        #expect(kept.map { $0.payload.preview } == ["AAA"])
    }

    @Test func duplicateIdsCollapseToTheFirst() {
        let limits = HistoryLimits(maxEntries: 10, maxTotalBytes: 100, maxEntryBytes: 10)
        let id = UUID()
        #expect(limits.bounded([entry("First", id: id), entry("Second", id: id)]).map { $0.payload.preview } == ["First"])
    }

    @Test func invalidEntriesAreDroppedWhateverTheirSource() {
        let limits = HistoryLimits(maxEntries: 10, maxTotalBytes: 100, maxEntryBytes: 5)
        let unsupported = ClipboardEntry(payload: ClipboardPayload(items: [[ClipboardRepresentation(type: "public.jpeg", data: Data([1]))]]))
        let empty = ClipboardEntry(payload: ClipboardPayload(items: [[ClipboardRepresentation(type: "public.utf8-plain-text", data: Data())]]))
        let tooBig = entry("123456")
        #expect(limits.bounded([unsupported, empty, tooBig, entry("OK")]).map { $0.payload.preview } == ["OK"])
    }

    @Test func payloadValidityRules() {
        let limits = HistoryLimits(maxEntries: 10, maxTotalBytes: 100, maxEntryBytes: 5)
        #expect(payload("12345").isValid(limits: limits))
        #expect(!payload("123456").isValid(limits: limits)) // over the per-copy cap
        #expect(!payload("").isValid(limits: limits)) // no bytes at all
        let unsupported = ClipboardPayload(items: [[ClipboardRepresentation(type: "com.example.custom", data: Data([1]))]])
        #expect(!unsupported.isValid(limits: limits))
        let item = [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data([65]))]
        let many = ClipboardPayload(items: Array(repeating: item, count: 129))
        #expect(!many.isValid(limits: HistoryLimits(maxEntries: 10, maxTotalBytes: 1000, maxEntryBytes: 1000)))
    }
}

@Suite struct StoreGateTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacClipBoardTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func entry(_ text: String) -> ClipboardEntry { ClipboardEntry(payload: payload(text)) }
    func previews(_ entries: [ClipboardEntry]) -> [String] { entries.map { $0.payload.preview } }

    @Test func aSaveWithAnOlderRevisionNeverReplacesNewerHistory() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileHistoryStore(directory: directory)
        try await store.save([entry("Newer")], revision: 5)
        try await store.save([entry("Stale")], revision: 4)
        #expect(previews(try await store.load()) == ["Newer"])
    }

    @Test func aClearWithAnOlderRevisionNeverDeletesNewerHistory() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileHistoryStore(directory: directory)
        try await store.save([entry("Newer")], revision: 5)
        try await store.clear(revision: 4)
        #expect(previews(try await store.load()) == ["Newer"])
    }

    @Test func aFrozenStoreIgnoresSavesAndClearsUntilResumed() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileHistoryStore(directory: directory)
        try await store.save([entry("Kept")], revision: 1)
        await store.freezeWrites()
        try await store.clear(revision: 2)
        try await store.save([entry("Ignored")], revision: 3)
        #expect(previews(try await store.load()) == ["Kept"])
        await store.resumeWrites()
        try await store.save([entry("After resume")], revision: 4)
        #expect(previews(try await store.load()) == ["After resume"])
    }

    @Test func anExistingLooseDirectoryIsTightenedToOwnerOnly() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try await FileHistoryStore(directory: directory).save([entry("Private")], revision: 1)
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
    }

    @Test func anArchiveFromAnotherVersionIsRefusedNotMisread() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let future = try PropertyListSerialization.data(fromPropertyList: ["version": 2, "entries": [Any]()], format: .binary, options: 0)
        try future.write(to: directory.appendingPathComponent("history.plist"))
        do { _ = try await FileHistoryStore(directory: directory).load(); Issue.record("Must refuse an unknown version") }
        catch { /* Expected. */ }
    }

    @Test func anOversizedFileIsRefusedBeforeItIsDecoded() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let big = ClipboardEntry(payload: ClipboardPayload(items: [[ClipboardRepresentation(
            type: "public.utf8-plain-text", data: Data(repeating: 65, count: 3 * 1024 * 1024))]]))
        try await FileHistoryStore(directory: directory).save([big], revision: 1)
        // A valid file, but far larger than this store's limits could ever produce.
        let strict = FileHistoryStore(directory: directory, limits: HistoryLimits(maxEntries: 5, maxTotalBytes: 1024))
        do { _ = try await strict.load(); Issue.record("Must refuse an oversized history file") }
        catch { /* Expected. */ }
    }

    @Test func loadingAndSavingBothHonourTheStoreLimits() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let two = HistoryLimits(maxEntries: 2, maxTotalBytes: 100, maxEntryBytes: 10)
        let three = ["A", "B", "C"].map(entry)
        // Saving through a small store writes at most two entries ...
        try await FileHistoryStore(directory: directory, limits: two).save(three, revision: 1)
        #expect(previews(try await FileHistoryStore(directory: directory, limits: HistoryLimits()).load()) == ["A", "B"])
        // ... and loading through a small store reads at most two of a bigger file.
        try await FileHistoryStore(directory: directory, limits: HistoryLimits()).save(three, revision: 2)
        #expect(previews(try await FileHistoryStore(directory: directory, limits: two).load()) == ["A", "B"])
    }
}

@Suite @MainActor struct PasteboardGateTests {
    func board() -> NSPasteboard { NSPasteboard.withUniqueName() }

    @Test func moreThan128ItemsAreRefusedRatherThanPartiallySaved() {
        let board = board(); defer { board.releaseGlobally() }
        let items = (0..<129).map { i -> NSPasteboardItem in
            let item = NSPasteboardItem(); item.setString("Item \(i)", forType: .string); return item
        }
        board.writeObjects(items)
        #expect(MacPasteboard(board).capture(limits: HistoryLimits()) == .tooLarge)
    }

    @Test func aFileGroupWithAnUnreadableMemberIsRefusedAsAWhole() {
        let board = board(); defer { board.releaseGlobally() }
        let good = NSPasteboardItem(); good.setString("file:///private/tmp/macclipboard-fixture-a.txt", forType: .fileURL)
        let bad = NSPasteboardItem(); bad.setString("this is not a URL", forType: .fileURL)
        board.writeObjects([good, bad])
        let result = MacPasteboard(board).capture(limits: HistoryLimits())
        if case .payload = result { Issue.record("A group must never be saved with a member missing") }
    }

    @Test func anInvalidPayloadIsNeverRestoredAndLeavesTheClipboardAlone() {
        let board = board(); defer { board.releaseGlobally() }
        board.setString("Existing synthetic clipboard", forType: .string)
        let adapter = MacPasteboard(board)
        #expect(!adapter.restore(ClipboardPayload(items: [])))
        #expect(board.string(forType: .string) == "Existing synthetic clipboard")
    }
}

@Suite @MainActor struct UninstallGateTests {
    let app = URL(fileURLWithPath: "/Applications/Mac ClipBoard.app")
    var history: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/local.macclipboard.app")
    }

    @Test func aMissingHistoryDirectoryIsNotSentToTheTrash() {
        var moved: [URL] = []
        let checks = SelfUninstaller.Checks(readOnly: { _ in false }, deletable: { _ in true }, exists: { _ in false })
        let uninstaller = SelfUninstaller(bundleURL: app, identifier: SelfUninstallRules.bundleIdentifier,
                                          historyDirectory: history, checks: checks, trash: { moved.append($0) })
        #expect(uninstaller.uninstall() == .removed(historyMoved: true))
        #expect(moved == [app])
    }
}
