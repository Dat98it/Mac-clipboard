import AppKit
import Foundation
import Testing
@testable import MacClipBoardCore
@testable import MacClipBoardSystem

/// macOS only lets the destination app read pasted files when the app writing the clipboard can read them. A file with
/// mode 000 fails open() with the same errno macOS returns for a protected folder that was refused, so it stands in for it.
@Suite struct FileReadAccessTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacClipBoardTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func file(_ name: String, in directory: URL, mode: Int = 0o644) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("synthetic".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    @Test func aReadableFileAMissingFileAndADirectoryAreNotDenied() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let readable = try file("readable.png", in: directory)
        #expect(!FileReadAccess.isDenied(path: readable.path))
        #expect(!FileReadAccess.isDenied(path: directory.appendingPathComponent("missing.png").path)) // restoring reports that itself
        #expect(!FileReadAccess.isDenied(path: directory.path))
    }

    @Test func aFileTheProcessCannotOpenIsDenied() throws {
        try #require(getuid() != 0, "root can read everything")
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let locked = try file("locked.png", in: directory, mode: 0o000)
        #expect(FileReadAccess.isDenied(path: locked.path))
    }
}

@Suite @MainActor struct RestorePreparationTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacClipBoardTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func filePayload(_ urls: [URL]) -> ClipboardPayload {
        ClipboardPayload(items: urls.map { [ClipboardRepresentation(type: "public.file-url", data: Data($0.absoluteString.utf8))] })
    }
    func adapter() -> (MacPasteboard, NSPasteboard) {
        let board = NSPasteboard.withUniqueName()
        return (MacPasteboard(board), board)
    }

    @Test func textAndImagePayloadsNeedNoFileAccess() async {
        let (adapter, board) = adapter(); defer { board.releaseGlobally() }
        #expect(await adapter.prepareRestore(payload("plain text")) == .ready)
    }

    @Test func readableMissingAndUnreadableFiles() async throws {
        try #require(getuid() != 0, "root can read everything")
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (adapter, board) = adapter(); defer { board.releaseGlobally() }
        let good = directory.appendingPathComponent("good.png"), locked = directory.appendingPathComponent("locked.png")
        try Data("x".utf8).write(to: good); try Data("x".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        #expect(await adapter.prepareRestore(filePayload([good])) == .ready)
        #expect(await adapter.prepareRestore(filePayload([directory.appendingPathComponent("gone.png")])) == .ready)
        #expect(await adapter.prepareRestore(filePayload([locked])) == .fileAccessDenied)
        // One file in the group that cannot be read is enough: a group is never half delivered.
        #expect(await adapter.prepareRestore(filePayload([good, locked])) == .fileAccessDenied)
    }
}

@Suite @MainActor struct SelectWithoutFileAccessTests {
    @Test func deniedAccessLeavesTheClipboardAloneAndSendsNothing() async {
        let board = FakeClipboard(), session = ClipboardSession(clipboard: board, store: MemoryHistory()), paster = FakePaster()
        await session.start(); board.copy("Synthetic item"); session.poll()
        board.preparation = .fileAccessDenied
        let changeCount = board.changeCount
        await session.select(session.entries[0].id, paster: paster)
        #expect(board.restores.isEmpty) // the clipboard was never rewritten
        #expect(board.changeCount == changeCount)
        #expect(paster.expectedCount == nil) // and no paste was attempted
        #expect(session.notice == .fileAccessDenied)
        #expect(!session.isPasting) // not stuck busy: the user can allow access and click again
    }

    @Test func readyAccessPastesAsBefore() async {
        let board = FakeClipboard(), session = ClipboardSession(clipboard: board, store: MemoryHistory()), paster = FakePaster()
        await session.start(); board.copy("Synthetic item"); session.poll()
        await session.select(session.entries[0].id, paster: paster)
        #expect(board.prepareCalls == 1)
        #expect(board.restores.count == 1)
        #expect(session.notice == .paste(.commandSent))
    }

    /// macOS can keep a file-access prompt open for as long as the user likes. Anything that happens meanwhile must win.
    @Test func clearAllWhileMacOSIsAskingForAccessCancelsTheSelection() async {
        let board = FakeClipboard(), session = ClipboardSession(clipboard: board, store: MemoryHistory()), paster = FakePaster()
        await session.start(); board.copy("Synthetic item to be cleared"); session.poll()
        board.gatePrepare = true
        let id = session.entries[0].id
        let selecting = Task { await session.select(id, paster: paster) }
        while !board.isPrepareWaiting { await Task.yield() }
        #expect(session.isPasting) // already busy while the prompt is open
        await session.clearAll()
        board.releasePrepare()
        await selecting.value
        #expect(board.restores.isEmpty) // the cleared item is never put back on the clipboard
        #expect(paster.expectedCount == nil) // and never pasted
        #expect(session.entries.isEmpty)
        #expect(!session.isPasting)
    }
}
