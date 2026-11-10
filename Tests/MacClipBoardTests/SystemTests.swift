import AppKit
import Foundation
import Testing
@testable import MacClipBoardCore
@testable import MacClipBoardSystem

@Suite @MainActor struct PasteboardTests {
    // All clipboard tests use unique named pasteboards. Never read the user's general pasteboard.
    func board() -> NSPasteboard { NSPasteboard.withUniqueName() }

    @Test func supportedRepresentationsAndItemBoundariesRoundTripWithoutConversion() {
        let board = board()
        defer { board.releaseGlobally() }
        let adapter = MacPasteboard(board)
        let original = ClipboardPayload(items: [
            [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("Synthetic formatted text 🧪".utf8)),
             ClipboardRepresentation(type: "public.rtf", data: Data("{\\rtf1\\ansi Fixture}".utf8)),
             ClipboardRepresentation(type: "public.html", data: Data("<b>Fixture</b>".utf8))].sorted { $0.type < $1.type },
            [ClipboardRepresentation(type: "public.file-url", data: Data("file:///tmp/macclipboard-fixture-a.txt".utf8))],
            [ClipboardRepresentation(type: "public.file-url", data: Data("file:///tmp/macclipboard-fixture-b.txt".utf8))],
        ])
        #expect(adapter.restore(original))
        guard case .payload(let captured) = adapter.capture(limits: HistoryLimits()) else { Issue.record("Expected supported payload"); return }
        // macOS may add a legacy multi-item metadata type. Supported bytes and boundaries are exact.
        #expect(captured.items == original.items)
        adapter.clear()
        #expect(adapter.capture(limits: HistoryLimits()) == .empty)
    }

    @Test func imageBytesAreNotReencoded() {
        let board = board()
        defer { board.releaseGlobally() }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        let data = image.representation(using: .png, properties: [:])!
        let value = ClipboardPayload(items: [[ClipboardRepresentation(type: "public.png", data: data)]])
        let adapter = MacPasteboard(board)
        #expect(adapter.restore(value))
        #expect(adapter.capture(limits: HistoryLimits()) == .payload(value))
    }

    @Test func concealedAndUnsupportedTypesAreSkippedAndPartialFormatsAreExplicit() {
        let board = board()
        defer { board.releaseGlobally() }
        let adapter = MacPasteboard(board)
        let item = NSPasteboardItem()
        item.setString("Synthetic private marker fixture", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.writeObjects([item])
        #expect(adapter.capture(limits: HistoryLimits()) == .privateContent)
        board.clearContents()
        let custom = NSPasteboardItem()
        custom.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("local.fixture.custom"))
        board.writeObjects([custom])
        #expect(adapter.capture(limits: HistoryLimits()) == .unsupported)
        board.clearContents()
        let mixed = NSPasteboardItem()
        mixed.setString("Synthetic mixed fixture", forType: .string)
        mixed.setData(Data([4]), forType: NSPasteboard.PasteboardType("local.fixture.custom"))
        board.writeObjects([mixed])
        guard case .payload(let captured) = adapter.capture(limits: HistoryLimits()) else { Issue.record("Expected supported text"); return }
        #expect(captured.omittedTypeCount == 1)
        #expect(!captured.showsOmittedWarning) // a custom type is not known content, so it is no reason to warn
        #expect(captured.items[0].count == 1)
    }

    @Test func oversizedPayloadIsLeftUnchanged() {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("Synthetic size fixture", forType: .string)
        let count = board.changeCount
        #expect(MacPasteboard(board).capture(limits: HistoryLimits(maxEntryBytes: 3)) == .tooLarge)
        #expect(board.changeCount == count)
    }

    @Test func namedBoardCanNeverTriggerRealPasteWhenIsolated() async {
        let board = board()
        defer { board.releaseGlobally() }
        let router = PasteRouter(clipboard: MacPasteboard(board), automaticPasteEnabled: false)
        let result = await router.paste(expectedChangeCount: board.changeCount, isCurrent: { true })
        #expect(result == .eventUnavailable)
    }

    @Test func missingPermissionAndMissingDestinationNeverPostEvents() async {
        let board = board()
        defer { board.releaseGlobally() }
        let adapter = MacPasteboard(board)
        let denied = PasteRouter(clipboard: adapter, permissionCheck: { false })
        #expect(await denied.paste(expectedChangeCount: board.changeCount, isCurrent: { true }) == .permissionRequired)
        let noTarget = PasteRouter(clipboard: adapter, permissionCheck: { true })
        #expect(await noTarget.paste(expectedChangeCount: board.changeCount, isCurrent: { true }) == .noDestination)
        #expect(await noTarget.paste(expectedChangeCount: board.changeCount, isCurrent: { false }) == .cancelled)
    }

    @Test func monitorStartIsIdempotentAndStopIsSafe() {
        let monitor = ClipboardMonitor()
        monitor.start { }; monitor.start { }
        #expect(monitor.isRunning)
        monitor.stop(); monitor.stop()
        #expect(!monitor.isRunning)
    }
}

@Suite struct FileHistoryTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacClipBoardTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func reopenRestoresExactBytesAndClearRejectsStaleSaves() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileHistoryStore(directory: directory)
        let entry = ClipboardEntry(payload: payload("Synthetic persistence fixture\nTiếng Việt 🧪"))
        try await store.save([entry], revision: 1)
        let reopened = FileHistoryStore(directory: directory)
        let restored = try await reopened.load()
        #expect(restored == [entry])
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("history.plist").path)
        #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await store.clear(revision: 3)
        // Even if an old task enters the actor AFTER deletion, it cannot restore its snapshot.
        try await store.save([entry], revision: 2)
        try await store.save([entry], revision: 3)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.plist").path))
        let afterClear = try await FileHistoryStore(directory: directory).load()
        #expect(afterClear.isEmpty)
        try await store.save([entry], revision: 4)
        let newHistory = try await store.load()
        #expect(newHistory == [entry])
    }

    @Test func simultaneousWritesAndClearAlwaysKeepNewestRevision() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileHistoryStore(directory: directory)
        let entry = ClipboardEntry(payload: payload("Synthetic race fixture"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in UInt64(1)...20 { group.addTask { try await store.save([entry], revision: revision) } }
            group.addTask { try await store.clear(revision: 21) }
            try await group.waitForAll()
        }
        let restored = try await store.load()
        #expect(restored.isEmpty)
    }

    @Test func invalidArchiveThrowsInsteadOfPretendingHistoryIsEmpty() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("Synthetic invalid archive".utf8).write(to: directory.appendingPathComponent("history.plist"))
        do { _ = try await FileHistoryStore(directory: directory).load(); Issue.record("Must report invalid archive") }
        catch { /* Expected; no content or error details are printed. */ }
    }
}
