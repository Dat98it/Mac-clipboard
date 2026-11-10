import Foundation
import Testing
@testable import MacClipBoardCore

func payload(_ text: String) -> ClipboardPayload {
    ClipboardPayload(items: [[ClipboardRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]])
}

@MainActor final class FakeClipboard: ClipboardAccess {
    var changeCount = 0
    var result: CaptureResult = .empty
    var captureCalls = 0
    var restores: [ClipboardPayload] = []
    var restoreSucceeds = true
    var preparation: RestorePreparation = .ready
    var prepareCalls = 0
    /// When set, `prepareRestore` stays pending until `releasePrepare()`, like macOS waiting for the user to answer a prompt.
    var gatePrepare = false
    private var prepareContinuation: CheckedContinuation<Void, Never>?
    var isPrepareWaiting: Bool { prepareContinuation != nil }
    func releasePrepare() { prepareContinuation?.resume(); prepareContinuation = nil }
    func prepareRestore(_ payload: ClipboardPayload) async -> RestorePreparation {
        prepareCalls += 1
        if gatePrepare { await withCheckedContinuation { prepareContinuation = $0 } }
        return preparation
    }
    func copy(_ text: String) { result = .payload(payload(text)); changeCount += 1 }
    func capture(limits: HistoryLimits) -> CaptureResult { captureCalls += 1; return result }
    func restore(_ payload: ClipboardPayload) -> Bool {
        restores.append(payload); result = .payload(payload); changeCount += 1
        return restoreSucceeds
    }
    func clear() { result = .empty; changeCount += 1 }
}

actor MemoryHistory: HistoryPersisting {
    var entries: [ClipboardEntry] = []
    var revision: UInt64 = 0
    var failSave = false
    var failClear = false
    func load() -> [ClipboardEntry] { entries }
    func save(_ entries: [ClipboardEntry], revision: UInt64) throws {
        if failSave { throw Failure.disk }
        if revision >= self.revision { self.entries = entries; self.revision = revision }
    }
    func clear(revision: UInt64) throws {
        self.revision = revision
        if failClear { throw Failure.disk }
        entries = []
    }
    func setClearFailure() { failClear = true }
    func setSaveFailure() { failSave = true }
    enum Failure: Error { case disk }
}

@MainActor final class FakePaster: PasteDelivering {
    var outcome: PasteOutcome = .commandSent
    var expectedCount: Int?
    var beforeReturn: (() async -> Void)?
    func paste(expectedChangeCount: Int, isCurrent: @escaping () -> Bool) async -> PasteOutcome {
        expectedCount = expectedChangeCount
        await beforeReturn?()
        return isCurrent() ? outcome : .cancelled
    }
}

@Suite @MainActor struct SessionTests {
    @Test func startupDoesNotReadExistingClipboardAndStartIsIdempotent() async {
        let board = FakeClipboard(), store = MemoryHistory()
        board.copy("Synthetic content present before tracking")
        let session = ClipboardSession(clipboard: board, store: store)
        await session.start(); await session.start(); session.poll()
        #expect(board.captureCalls == 0)
        #expect(session.entries.isEmpty)
    }

    @Test func newestFirstDeduplicatesAndRoundTripsFullText() async {
        let board = FakeClipboard(), session = ClipboardSession(clipboard: board, store: MemoryHistory())
        await session.start()
        let old = "Fixture A — Tiếng Việt 🧪\n" + String(repeating: "long line\t", count: 100)
        board.copy(old); session.poll()
        board.copy("Fixture B"); session.poll()
        #expect(session.entries.map { $0.payload.preview } == ["Fixture B", String(old.prefix(320))])
        let item = session.entries[1], paster = FakePaster()
        paster.outcome = .permissionRequired
        await session.select(item.id, paster: paster)
        #expect(board.restores.last == payload(old))
        #expect(paster.expectedCount == board.changeCount)
        #expect(session.notice == .paste(.permissionRequired))
        session.poll()
        #expect(session.entries.count == 2)
        board.copy(old); session.poll()
        #expect(session.entries.count == 2)
        #expect(session.entries[0].payload == payload(old))
    }

    @Test func pauseSkipsCopiesAndEmptyClipboardDoesNotCreateAnEntry() async {
        let board = FakeClipboard(), session = ClipboardSession(clipboard: board, store: MemoryHistory())
        await session.start()
        session.setPaused(true); board.copy("Fixture during pause"); session.poll()
        session.setPaused(false); session.poll()
        #expect(board.captureCalls == 0)
        board.clear(); session.poll()
        #expect(session.entries.isEmpty)
        board.copy("Fixture after resume"); session.poll()
        #expect(session.entries.count == 1)
    }

    @Test func limitsEvictOldestByCountAndBytes() async {
        let board = FakeClipboard()
        let session = ClipboardSession(clipboard: board, store: MemoryHistory(), limits: HistoryLimits(maxEntries: 2, maxTotalBytes: 6, maxEntryBytes: 4))
        await session.start()
        for value in ["AA", "BBB", "CCCC"] { board.copy(value); session.poll() }
        #expect(session.entries.map { $0.payload.preview } == ["CCCC"])
        board.copy("D"); session.poll()
        board.copy("E"); session.poll()
        #expect(session.entries.map { $0.payload.preview } == ["E", "D"])
    }

    @Test func clearCancelsPendingSaveAndCannotReappearAfterRestart() async {
        let board = FakeClipboard(), store = MemoryHistory()
        let session = ClipboardSession(clipboard: board, store: store)
        await session.start()
        board.copy("Synthetic history to delete"); session.poll()
        await session.clearAll()
        session.poll()
        await session.flush()
        #expect(session.entries.isEmpty)
        #expect(board.result == .empty)
        #expect(session.notice == .cleared)
        let reopened = ClipboardSession(clipboard: board, store: store)
        await reopened.start(); reopened.poll()
        #expect(reopened.entries.isEmpty)
        board.copy("New fixture after clear"); reopened.poll()
        #expect(reopened.entries.count == 1)
    }

    @Test func clearInvalidatesPendingPaste() async {
        let board = FakeClipboard(), store = MemoryHistory(), paster = FakePaster()
        let session = ClipboardSession(clipboard: board, store: store)
        await session.start(); board.copy("Synthetic old item"); session.poll()
        let id = session.entries[0].id
        paster.beforeReturn = { await session.clearAll() }
        await session.select(id, paster: paster)
        #expect(session.entries.isEmpty)
        #expect(!session.isPasting)
        #expect(session.notice == .cleared)
    }

    @Test func clearFailureIsVisibleAndPausesMonitoring() async {
        let board = FakeClipboard(), store = MemoryHistory()
        let session = ClipboardSession(clipboard: board, store: store)
        await session.start(); board.copy("Synthetic fixture"); session.poll()
        await store.setClearFailure()
        await session.clearAll()
        #expect(session.entries.isEmpty)
        #expect(session.isPaused)
        #expect(session.notice == .clearFailed)
        #expect(board.result == .empty)
    }

    @Test func failedRestoreDoesNotCallPasteAndDoesNotLeaveBusyState() async {
        let board = FakeClipboard(), session = ClipboardSession(clipboard: board, store: MemoryHistory()), paster = FakePaster()
        await session.start(); board.copy("Synthetic fixture"); session.poll()
        board.restoreSucceeds = false
        await session.select(session.entries[0].id, paster: paster)
        #expect(paster.expectedCount == nil)
        #expect(session.notice == .restoreFailed)
        #expect(!session.isPasting)
    }

    @Test func unstableReadRetriesInsteadOfLosingChange() async {
        let board = FakeClipboard(), session = ClipboardSession(clipboard: board, store: MemoryHistory())
        await session.start()
        board.changeCount += 1; board.result = .changedDuringRead
        session.poll(); board.result = .payload(payload("Stable synthetic fixture")); session.poll()
        #expect(board.captureCalls == 2)
        #expect(session.entries.count == 1)
    }
}
