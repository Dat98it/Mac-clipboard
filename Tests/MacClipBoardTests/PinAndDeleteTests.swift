import Foundation
import Testing
@testable import MacClipBoardCore
@testable import MacClipBoardSystem

@Suite @MainActor struct PinAndDeleteTests {
    func previews(_ session: ClipboardSession) -> [String] { session.entries.map { $0.payload.preview } }
    func copy(_ text: String, _ board: FakeClipboard, _ session: ClipboardSession) { board.copy(text); session.poll() }
    func id(of text: String, _ session: ClipboardSession) -> UUID { session.entries.first { $0.payload.preview == text }!.id }

    @Test func pinnedItemSurvivesEvictionByCount() async {
        let board = FakeClipboard()
        let session = ClipboardSession(clipboard: board, store: MemoryHistory(),
                                       limits: HistoryLimits(maxEntries: 3, maxTotalBytes: 100, maxEntryBytes: 10))
        await session.start()
        copy("A", board, session)
        session.setPinned(id(of: "A", session), true)
        for value in ["B", "C", "D", "E"] { copy(value, board, session) }
        #expect(previews(session) == ["E", "D", "A"])
        session.setPinned(id(of: "A", session), false)
        copy("F", board, session)
        #expect(previews(session) == ["F", "E", "D"])
    }

    @Test func pinnedItemSurvivesEvictionByBytes() async {
        let board = FakeClipboard()
        let session = ClipboardSession(clipboard: board, store: MemoryHistory(),
                                       limits: HistoryLimits(maxEntries: 10, maxTotalBytes: 10, maxEntryBytes: 5))
        await session.start()
        copy("AAAA", board, session)
        session.setPinned(id(of: "AAAA", session), true)
        copy("BBBBB", board, session)
        copy("CCCCC", board, session)
        #expect(previews(session) == ["CCCCC", "AAAA"])
    }

    @Test func pinLimitByCountIsEnforcedAndReported() async {
        let board = FakeClipboard()
        let session = ClipboardSession(clipboard: board, store: MemoryHistory(),
                                       limits: HistoryLimits(maxEntries: 10, maxTotalBytes: 100, maxEntryBytes: 10, maxPinnedEntries: 2))
        await session.start()
        for value in ["A", "B", "C"] { copy(value, board, session) }
        for value in ["A", "B", "C"] { session.setPinned(id(of: value, session), true) }
        #expect(session.entries.filter { $0.isPinned }.count == 2)
        #expect(session.entries.first { $0.payload.preview == "C" }?.isPinned == false)
        #expect(session.notice == .pinLimitReached)
    }

    @Test func pinLimitByBytesLeavesRoomForNewCopies() async {
        let board = FakeClipboard()
        let session = ClipboardSession(clipboard: board, store: MemoryHistory(),
                                       limits: HistoryLimits(maxEntries: 10, maxTotalBytes: 10, maxEntryBytes: 5))
        await session.start()
        copy("AAA", board, session); copy("BBB", board, session)
        session.setPinned(id(of: "AAA", session), true)
        session.setPinned(id(of: "BBB", session), true) // 6 bytes > half of 10
        #expect(session.entries.map { $0.isPinned } == [false, true])
        #expect(session.notice == .pinLimitReached)
    }

    @Test func copyingAPinnedItemAgainKeepsItPinned() async {
        let board = FakeClipboard(), session = ClipboardSession(clipboard: board, store: MemoryHistory())
        await session.start()
        copy("A", board, session); copy("B", board, session)
        session.setPinned(id(of: "A", session), true)
        copy("A", board, session)
        #expect(previews(session) == ["A", "B"])
        #expect(session.entries.map { $0.isPinned } == [true, false])
    }

    @Test func deleteRemovesOnlyThatItemAndNeverTouchesTheClipboard() async {
        let board = FakeClipboard(), store = MemoryHistory()
        let session = ClipboardSession(clipboard: board, store: store)
        await session.start()
        copy("A", board, session); copy("B", board, session)
        let changeCount = board.changeCount
        session.delete(id(of: "B", session)) // B is also what the clipboard currently holds
        #expect(previews(session) == ["A"])
        #expect(session.notice == .itemDeleted)
        #expect(board.changeCount == changeCount)
        #expect(board.restores.isEmpty)
        session.poll() // the still-present clipboard content must not be captured again
        #expect(previews(session) == ["A"])
        await session.flush()
        #expect(await store.entries.map { $0.payload.preview } == ["A"])
    }

    @Test func deletingAnUnknownItemChangesNothing() async {
        let board = FakeClipboard(), session = ClipboardSession(clipboard: board, store: MemoryHistory())
        await session.start()
        copy("A", board, session)
        session.delete(UUID())
        #expect(previews(session) == ["A"])
        #expect(session.notice == .saved)
    }

    @Test func pinsAndDeletionsPersistAcrossRestart() async {
        let board = FakeClipboard(), store = MemoryHistory()
        let session = ClipboardSession(clipboard: board, store: store)
        await session.start()
        for value in ["A", "B", "C"] { copy(value, board, session) }
        session.setPinned(id(of: "A", session), true)
        session.delete(id(of: "B", session))
        await session.flush()
        let reopened = ClipboardSession(clipboard: board, store: store)
        await reopened.start()
        #expect(reopened.entries.map { $0.payload.preview } == ["C", "A"])
        #expect(reopened.entries.map { $0.isPinned } == [false, true])
    }

    @Test func clearAllAlsoRemovesPinnedItems() async {
        let board = FakeClipboard(), store = MemoryHistory()
        let session = ClipboardSession(clipboard: board, store: store)
        await session.start()
        copy("A", board, session)
        session.setPinned(id(of: "A", session), true)
        await session.clearAll()
        #expect(session.entries.isEmpty)
        let reopened = ClipboardSession(clipboard: board, store: store)
        await reopened.start()
        #expect(reopened.entries.isEmpty)
    }
}

@Suite struct PinnedStorageTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacClipBoardTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func pinnedFlagRoundTripsThroughTheFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pinned = ClipboardEntry(payload: payload("Synthetic pinned fixture"), isPinned: true)
        let plain = ClipboardEntry(payload: payload("Synthetic plain fixture"))
        try await FileHistoryStore(directory: directory).save([plain, pinned], revision: 1)
        let restored = try await FileHistoryStore(directory: directory).load()
        #expect(restored == [plain, pinned])
        #expect(restored.map { $0.isPinned } == [false, true])
    }

    /// History saved by 0.1.0 has no `isPinned` key. It must load as unpinned, not as a corrupt archive.
    @Test func historyWrittenBeforePinningStillLoads() async throws {
        struct OldEntry: Codable { let id: UUID; let capturedAt: Date; let payload: ClipboardPayload }
        struct OldArchive: Codable { let version: Int; let entries: [OldEntry] }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = OldEntry(id: UUID(), capturedAt: Date(timeIntervalSince1970: 1_700_000_000), payload: payload("Synthetic legacy fixture"))
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(OldArchive(version: 1, entries: [old])).write(to: directory.appendingPathComponent("history.plist"))
        let restored = try await FileHistoryStore(directory: directory).load()
        #expect(restored.count == 1)
        #expect(restored[0].id == old.id)
        #expect(restored[0].payload == old.payload)
        #expect(!restored[0].isPinned)
    }

    @Test func loadingNeverKeepsMorePinnedThanTheCaps() {
        let limits = HistoryLimits(maxEntries: 10, maxTotalBytes: 100, maxEntryBytes: 10, maxPinnedEntries: 2)
        let entries = ["A", "B", "C", "D"].map { ClipboardEntry(payload: payload($0), isPinned: true) }
        let kept = limits.bounded(entries)
        #expect(kept.map { $0.payload.preview } == ["A", "B"])
    }
}
