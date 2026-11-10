import AppKit
import Foundation
import Testing
@testable import MacClipBoardCore
@testable import MacClipBoardSystem

@MainActor final class FakeHotkeyService: HotkeyRegistering {
    var events: [String] = []
    var registerSucceeds = true
    var handler: (@MainActor () -> Void)?
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) -> Bool {
        events.append("register:\(keyCode):\(modifiers)")
        guard registerSucceeds else { return false }
        self.handler = handler
        return true
    }
    func unregister() { events.append("unregister"); handler = nil }
}

@Suite struct HotkeyChoiceTests {
    @Test func theShortcutsAreTheDocumentedKeysAndModifiers() {
        #expect(HotkeyChoice.default == .commandShiftV)
        #expect(HotkeyChoice.allCases.first == .commandShiftV) // the default is listed first in Settings
        #expect(HotkeyChoice.controlOptionV.keyCode == 9) // kVK_ANSI_V
        #expect(HotkeyChoice.controlOptionV.modifiers == 0x1000 | 0x800) // control + option
        #expect(HotkeyChoice.controlOptionCommandV.modifiers == 0x1000 | 0x800 | 0x100)
        #expect(HotkeyChoice.commandShiftV.modifiers == 0x100 | 0x200) // command + shift
        #expect(HotkeyChoice.controlOptionV.symbols == "⌃⌥V")
        #expect(HotkeyChoice.commandShiftV.symbols == "⇧⌘V")
    }

    @Test func offHasNoKeyAndEveryShortcutIsDistinct() {
        #expect(HotkeyChoice.off.keyCode == nil)
        let active = HotkeyChoice.allCases.filter { $0 != .off }
        #expect(Set(active.map { $0.modifiers }).count == active.count)
    }
}

@Suite @MainActor struct HotkeyControllerTests {
    @Test func registersTheChosenCombinationAndRunsTheHandlerOnPress() {
        let service = FakeHotkeyService()
        var presses = 0
        let controller = HotkeyController(service: service, onPress: { presses += 1 })
        #expect(controller.apply(.controlOptionV) == .registered(.controlOptionV))
        #expect(service.events == ["unregister", "register:9:\(0x1000 | 0x800)"])
        service.handler?()
        #expect(presses == 1)
    }

    @Test func switchingReleasesThePreviousShortcutFirst() {
        let service = FakeHotkeyService()
        let controller = HotkeyController(service: service, onPress: {})
        controller.apply(.controlOptionV)
        service.events.removeAll()
        controller.apply(.commandShiftV)
        #expect(service.events == ["unregister", "register:9:\(0x100 | 0x200)"])
    }

    @Test func offReleasesAndRegistersNothing() {
        let service = FakeHotkeyService()
        let controller = HotkeyController(service: service, onPress: {})
        controller.apply(.controlOptionV)
        service.events.removeAll()
        #expect(controller.apply(.off) == .off)
        #expect(service.events == ["unregister"])
        #expect(service.handler == nil)
    }

    @Test func aCombinationMacOSRefusesIsReportedNotClaimed() {
        let service = FakeHotkeyService()
        service.registerSucceeds = false
        let controller = HotkeyController(service: service, onPress: {})
        #expect(controller.apply(.controlOptionCommandV) == .unavailable(.controlOptionCommandV))
        #expect(controller.status == .unavailable(.controlOptionCommandV))
    }

    @Test func stopReleasesTheShortcut() {
        let service = FakeHotkeyService()
        let controller = HotkeyController(service: service, onPress: {})
        controller.apply(.controlOptionV)
        controller.stop()
        #expect(controller.status == .off)
        #expect(service.handler == nil)
    }
}

@Suite struct ShortcutPreferencesTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacClipBoardTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theShortcutIsOnByDefaultAndSurvivesOtherChanges() {
        var preferences = Preferences()
        #expect(preferences.hotkey == .commandShiftV)
        preferences.setHotkey(.controlOptionV)
        preferences.setMaxEntries(200); preferences.setMaxTotalMiB(64)
        #expect(preferences.hotkey == .controlOptionV)
        #expect(preferences.maxEntries == 200 && preferences.maxTotalMiB == 64)
    }

    @Test func settingsWrittenBeforeTheShortcutExistedStillLoad() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = try PropertyListSerialization.data(fromPropertyList: ["maxEntries": 50, "maxTotalMiB": 16], format: .binary, options: 0)
        try old.write(to: directory.appendingPathComponent("settings.plist"))
        let loaded = PreferencesStore(directory: directory).load()
        #expect(loaded.maxEntries == 50 && loaded.maxTotalMiB == 16)
        #expect(loaded.hotkey == .default)
    }

    @Test func anUnknownStoredShortcutFallsBackToTheDefault() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let odd = try PropertyListSerialization.data(fromPropertyList: ["hotkey": "controlShiftZ", "maxEntries": 200], format: .binary, options: 0)
        try odd.write(to: directory.appendingPathComponent("settings.plist"))
        let loaded = PreferencesStore(directory: directory).load()
        #expect(loaded.hotkey == .default)
        #expect(loaded.maxEntries == 200)
    }

    @Test func theChoiceRoundTripsThroughTheFile() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var preferences = Preferences()
        preferences.setHotkey(.off)
        try PreferencesStore(directory: directory).save(preferences)
        #expect(PreferencesStore(directory: directory).load().hotkey == .off)
    }
}

@Suite @MainActor struct FileWarningTests {
    func fileRepresentation(_ path: String) -> [ClipboardRepresentation] {
        [ClipboardRepresentation(type: "public.file-url", data: Data(("file://" + path).utf8))]
    }

    /// Finder attaches legacy and dynamic types to every copied file; none of them is content that was lost.
    @Test func copyingAFileDoesNotClaimThatFormatsWereLost() {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        for name in ["picture.png", "notes.md", "table.csv", "slides.pptx"] {
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString("file:///private/tmp/macclipboard-fixture/\(name)", forType: .fileURL)
            item.setString(name, forType: .string)
            item.setData(Data([1]), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
            item.setData(Data([2]), forType: NSPasteboard.PasteboardType("com.apple.finder.node"))
            item.setData(Data([3]), forType: NSPasteboard.PasteboardType("dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu"))
            board.writeObjects([item])
            guard case .payload(let payload) = MacPasteboard(board).capture(limits: HistoryLimits()) else {
                Issue.record("Expected a file payload for \(name)"); continue
            }
            #expect(payload.containsOnlyFileReferences)
            #expect(payload.omittedTypeCount == 0)
            #expect(!payload.showsOmittedWarning)
        }
    }

    @Test func historySavedBeforeTheFixNoLongerShowsTheWarningForFiles() {
        let oldFile = ClipboardPayload(items: [fileRepresentation("/private/tmp/a.png")], omittedTypeCount: 4, lostContentCount: 4)
        #expect(!oldFile.showsOmittedWarning)
    }

    @Test func realLostFormatsStillShowTheWarning() {
        let text = ClipboardPayload(items: [[ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("x".utf8))]],
                                    omittedTypeCount: 2, lostContentCount: 2)
        #expect(text.showsOmittedWarning)
        // Dropped by-products alone are not "lost formats".
        let byProducts = ClipboardPayload(items: text.items, omittedTypeCount: 5)
        #expect(!byProducts.showsOmittedWarning)
        let none = ClipboardPayload(items: [[ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("x".utf8))]])
        #expect(!none.showsOmittedWarning)
    }
}

@Suite @MainActor struct TextWarningTests {
    func board() -> NSPasteboard { NSPasteboard.withUniqueName() }

    /// Copying text from a browser or editor always attaches by-products; none of them is content that was lost.
    @Test func plainTextWithWebByProductsDoesNotWarn() {
        let board = board(); defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("Synthetic plain text", forType: .string)
        for type in ["public.utf16-external-plain-text", "NSStringPboardType", "org.chromium.source-url",
                     "org.chromium.web-custom-data", "com.apple.WebKit.custom-pasteboard-data",
                     "dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu"] {
            item.setData(Data([1]), forType: NSPasteboard.PasteboardType(type))
        }
        board.writeObjects([item])
        guard case .payload(let payload) = MacPasteboard(board).capture(limits: HistoryLimits()) else { Issue.record("Expected text"); return }
        #expect(payload.omittedTypeCount >= 1) // the by-products were dropped ...
        #expect(payload.lostContentCount == 0) // ... but nothing of value was
        #expect(!payload.showsOmittedWarning)
    }

    @Test func droppingARealImageOrDocumentFormatStillWarns() {
        let board = board(); defer { board.releaseGlobally() }
        for type in ["public.jpeg", "com.adobe.pdf", "public.rtfd"] {
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString("Synthetic text beside a \(type)", forType: .string)
            item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType(type))
            board.writeObjects([item])
            guard case .payload(let payload) = MacPasteboard(board).capture(limits: HistoryLimits()) else { Issue.record("Expected text"); continue }
            #expect(payload.lostContentCount == 1, "\(type)")
            #expect(payload.showsOmittedWarning, "\(type)")
        }
    }

    @Test func supportedFormatsAreKeptNotCountedAsLost() {
        let board = board(); defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("Synthetic rich text", forType: .string)
        item.setData(Data("<b>x</b>".utf8), forType: .html)
        board.writeObjects([item])
        guard case .payload(let payload) = MacPasteboard(board).capture(limits: HistoryLimits()) else { Issue.record("Expected text"); return }
        #expect(payload.omittedTypeCount == 0 && payload.lostContentCount == 0)
        #expect(payload.types.contains("public.html"))
    }
}

@Suite struct PayloadBookkeepingTests {
    func text(_ value: String, omitted: Int = 0, lost: Int = 0) -> ClipboardPayload {
        ClipboardPayload(items: [[ClipboardRepresentation(type: "public.utf8-plain-text", data: Data(value.utf8))]],
                         omittedTypeCount: omitted, lostContentCount: lost)
    }

    /// An older version stored `omittedTypeCount` inflated by by-products. Such entries must load, and must not warn.
    @Test func historySavedBeforeTheFixLoadsWithoutAWarning() throws {
        struct OldPayload: Codable { let items: [[ClipboardRepresentation]]; let omittedTypeCount: Int }
        let old = OldPayload(items: text("Synthetic old text").items, omittedTypeCount: 5)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder().decode(ClipboardPayload.self, from: try encoder.encode(old))
        #expect(decoded.omittedTypeCount == 5)
        #expect(decoded.lostContentCount == 0)
        #expect(!decoded.showsOmittedWarning)
    }

    @Test func theLostContentCountRoundTrips() throws {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder().decode(ClipboardPayload.self, from: try encoder.encode(text("Synthetic", omitted: 3, lost: 2)))
        #expect(decoded.lostContentCount == 2 && decoded.omittedTypeCount == 3)
        #expect(decoded.showsOmittedWarning)
    }

    /// Copying again text that an older version saved with different bookkeeping must collapse into one entry.
    @Test func samePayloadWithDifferentBookkeepingCountsAsTheSameCopy() {
        #expect(text("Same", omitted: 4) == text("Same", omitted: 0))
        #expect(text("Same", lost: 1) == text("Same"))
        #expect(text("Same") != text("Different"))
    }
}
