import AppKit
import Foundation
import Testing
@testable import MacClipBoardCore
@testable import MacClipBoardSystem

/// Exercise the file formats consumed by Finder and browser paste handlers, using owned fixtures
/// and named pasteboards only. A file item must never degrade into its text caption/path.
@Suite @MainActor struct FilePasteTests {
    func fixtures() throws -> (root: URL, files: [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClipBoardFiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let requested = ["ảnh thử.png", "presentation.pptx", "notes.md"].map { root.appendingPathComponent($0) }
        for file in requested { try Data("Synthetic clipboard file fixture\n".utf8).write(to: file) }
        // Account for /var → /private/var aliases in the macOS temporary directory.
        let files = requested.map { url in
            (url as NSURL).fileReferenceURL().flatMap { ($0 as NSURL).filePathURL } ?? url
        }
        return (root, files)
    }

    @Test func selectingFileHistoryPublishesFilesWithoutTextFallback() throws {
        let fixture = try fixtures()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let source = fixture.files.enumerated().map { index, url in
            let item = NSPasteboardItem()
            item.setData(Data(url.absoluteString.utf8), forType: .fileURL)
            if index == 0 { item.setString("Synthetic file-name caption", forType: .string) }
            return item
        }
        #expect(board.writeObjects(source))
        let adapter = MacPasteboard(board)
        guard case .payload(let captured) = adapter.capture(limits: HistoryLimits()) else { Issue.record("File capture failed"); return }
        board.clearContents()
        board.setString("Synthetic unrelated text copied later", forType: .string)
        #expect(adapter.restore(captured))
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        #expect(urls == fixture.files)
        #expect(board.string(forType: .string) == nil)
        let filenames = board.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String]
        #expect(filenames == fixture.files.map { $0.path })
    }

    @Test func finderFileReferencesAreCapturedAsDurablePathURLs() throws {
        let fixture = try fixtures()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let referenceURLs = fixture.files.compactMap { ($0 as NSURL).fileReferenceURL() }
        #expect(referenceURLs.count == fixture.files.count)
        let source = referenceURLs.map { url in
            let item = NSPasteboardItem()
            item.setData(Data(url.absoluteString.utf8), forType: .fileURL)
            return item
        }
        #expect(board.writeObjects(source))
        guard case .payload(let captured) = MacPasteboard(board).capture(limits: HistoryLimits()) else { Issue.record("File-reference capture failed"); return }
        let storedURLs = captured.items.compactMap { item in
            item.first(where: { $0.type == "public.file-url" }).flatMap { String(data: $0.data, encoding: .utf8) }.flatMap(URL.init(string:))
        }
        #expect(storedURLs == fixture.files)
        #expect(storedURLs.allSatisfy { !$0.absoluteString.contains("/.file/id=") })
    }

    @Test func oldFileReferenceHistoryIsAlsoRestoredAsFiles() throws {
        let fixture = try fixtures()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let items = try fixture.files.map { url -> [ClipboardRepresentation] in
            let reference = try #require((url as NSURL).fileReferenceURL())
            return [ClipboardRepresentation(type: "public.file-url", data: Data(reference.absoluteString.utf8)),
                    ClipboardRepresentation(type: "public.utf8-plain-text", data: Data(url.lastPathComponent.utf8))]
        }
        #expect(MacPasteboard(board).restore(ClipboardPayload(items: items)))
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        #expect(urls == fixture.files)
        #expect(board.string(forType: .string) == nil)
    }

    @Test func missingFileDoesNotOverwriteClipboardWithItsName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClipBoardMissing-" + UUID().uuidString)
        let missing = root.appendingPathComponent("missing.pptx")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Synthetic clipboard to retain", forType: .string)
        let before = board.changeCount
        let payload = ClipboardPayload(items: [[
            ClipboardRepresentation(type: "public.file-url", data: Data(missing.absoluteString.utf8)),
            ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("missing.pptx".utf8)),
        ]])
        #expect(!MacPasteboard(board).restore(payload))
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "Synthetic clipboard to retain")
    }

    @Test func plainTextPathsRemainTextRatherThanUploadingFiles() throws {
        let fixture = try fixtures()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let text = fixture.files[0].path
        let payload = ClipboardPayload(items: [[ClipboardRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))]])
        #expect(MacPasteboard(board).restore(payload))
        #expect(board.string(forType: .string) == text)
        #expect(!board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]))
    }

    @Test func filesRemainNativeAfterHistoryIsSavedAndReopened() async throws {
        let fixture = try fixtures()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(board.writeObjects(fixture.files.map { $0 as NSURL }))
        let adapter = MacPasteboard(board)
        guard case .payload(let captured) = adapter.capture(limits: HistoryLimits()) else { Issue.record("File capture failed"); return }
        let directory = fixture.root.appendingPathComponent("history")
        try await FileHistoryStore(directory: directory).save([ClipboardEntry(payload: captured)], revision: 1)
        let loaded = try await FileHistoryStore(directory: directory).load()
        let restored = try #require(loaded.first?.payload)
        #expect(restored.types == ["public.file-url"])
        board.clearContents()
        board.setString("Synthetic later clipboard", forType: .string)
        #expect(adapter.restore(restored))
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        #expect(urls == fixture.files)
        #expect(board.string(forType: .string) == nil)
        #expect(try urls.map { try Data(contentsOf: $0) } == fixture.files.map { try Data(contentsOf: $0) })
    }

    @Test func oneMissingFileRejectsTheWholeGroupBeforeChangingClipboard() throws {
        let fixture = try fixtures()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let missing = fixture.root.appendingPathComponent("never-created.pptx")
        let payload = ClipboardPayload(items: [fixture.files[0], missing].map { url in
            [ClipboardRepresentation(type: "public.file-url", data: Data(url.absoluteString.utf8))]
        })
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Synthetic original clipboard", forType: .string)
        let before = board.changeCount
        let restored = MacPasteboard(board).restore(payload)
        #expect(!restored)
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "Synthetic original clipboard")
    }

    @Test func invalidFileURLCannotFallBackToText() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Synthetic original clipboard", forType: .string)
        let payload = ClipboardPayload(items: [[
            ClipboardRepresentation(type: "public.file-url", data: Data("https://example.invalid/fixture.md".utf8)),
            ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("fixture.md".utf8)),
        ]])
        let restored = MacPasteboard(board).restore(payload)
        #expect(!restored)
        #expect(board.string(forType: .string) == "Synthetic original clipboard")
    }
}
