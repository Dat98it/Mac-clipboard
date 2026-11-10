import Foundation
import Testing
@testable import MacClipBoardCore
@testable import MacClipBoardSystem

@Suite struct PreferencesTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacClipBoardTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func defaultsMatchTheDocumentedLimits() {
        let limits = Preferences().limits
        #expect(limits.maxEntries == 100)
        #expect(limits.maxTotalBytes == 32 * 1024 * 1024)
        #expect(limits.maxEntryBytes == 8 * 1024 * 1024)
    }

    @Test func onlyOfferedChoicesAreAccepted() {
        #expect(Preferences(maxEntries: 7, maxTotalMiB: 5).maxEntries == 100)
        #expect(Preferences(maxEntries: 7, maxTotalMiB: 5).maxTotalMiB == 32)
        #expect(Preferences(maxEntries: Int.max, maxTotalMiB: Int.max).limits.maxTotalBytes == 32 * 1024 * 1024)
        var preferences = Preferences()
        preferences.setMaxEntries(200); preferences.setMaxTotalMiB(64)
        #expect(preferences.limits.maxEntries == 200 && preferences.limits.maxTotalBytes == 64 * 1024 * 1024)
        preferences.setMaxEntries(-1)
        #expect(preferences.maxEntries == 100)
    }

    /// A new copy (up to 8 MiB) must always fit beside a full set of pinned items, whatever the user picks.
    @Test func everyChoiceLeavesRoomForANewCopyBesideThePinnedItems() {
        for entries in Preferences.entryChoices {
            for mib in Preferences.totalMiBChoices {
                let limits = Preferences(maxEntries: entries, maxTotalMiB: mib).limits
                #expect(limits.maxPinnedBytes + limits.maxEntryBytes <= limits.maxTotalBytes)
                #expect(limits.maxPinnedEntries < limits.maxEntries)
            }
        }
    }

    @Test func historyFileCeilingCoversEveryChoice() {
        let ceiling = HistoryLimits.ceiling
        #expect(ceiling.maxEntries == Preferences.entryChoices.max())
        #expect(ceiling.maxTotalBytes == Preferences.totalMiBChoices.max()! * 1024 * 1024)
    }

    @Test func roundTripsThroughTheFileWithPrivatePermissions() throws {
        let directory = try temporaryDirectory().appendingPathComponent("support")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = PreferencesStore(directory: directory)
        #expect(store.load() == Preferences()) // no file yet
        var preferences = Preferences()
        preferences.setMaxEntries(50); preferences.setMaxTotalMiB(16)
        try store.save(preferences)
        #expect(PreferencesStore(directory: directory).load() == preferences)
        let file = directory.appendingPathComponent("settings.plist")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func damagedOrHandEditedFilesFallBackToDefaults() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.plist")
        try Data("not a plist".utf8).write(to: file)
        #expect(PreferencesStore(directory: directory).load() == Preferences())
        let absurd = try PropertyListSerialization.data(fromPropertyList: ["maxEntries": 999_999_999, "maxTotalMiB": 1_000_000], format: .binary, options: 0)
        try absurd.write(to: file)
        #expect(PreferencesStore(directory: directory).load() == Preferences())
    }
}

@Suite @MainActor struct LimitChangeTests {
    func fill(_ values: [String], _ board: FakeClipboard, _ session: ClipboardSession) {
        for value in values { board.copy(value); session.poll() }
    }

    @Test func loweringLimitsDropsOldestUnpinnedAndKeepsPinned() async {
        let board = FakeClipboard(), store = MemoryHistory()
        let session = ClipboardSession(clipboard: board, store: store,
                                       limits: HistoryLimits(maxEntries: 10, maxTotalBytes: 100, maxEntryBytes: 10))
        await session.start()
        fill(["A", "B", "C", "D", "E"], board, session)
        session.setPinned(session.entries.first { $0.payload.preview == "A" }!.id, true)
        let smaller = HistoryLimits(maxEntries: 3, maxTotalBytes: 100, maxEntryBytes: 10)
        #expect(session.entriesRemoved(under: smaller) == 2)
        session.setLimits(smaller)
        #expect(session.entries.map { $0.payload.preview } == ["E", "D", "A"])
        await session.flush()
        #expect(await store.entries.map { $0.payload.preview } == ["E", "D", "A"])
    }

    @Test func raisingLimitsRemovesNothingAndAllowsMoreItems() async {
        let board = FakeClipboard()
        let session = ClipboardSession(clipboard: board, store: MemoryHistory(),
                                       limits: HistoryLimits(maxEntries: 2, maxTotalBytes: 100, maxEntryBytes: 10))
        await session.start()
        fill(["A", "B", "C"], board, session)
        #expect(session.entries.count == 2)
        let bigger = HistoryLimits(maxEntries: 4, maxTotalBytes: 100, maxEntryBytes: 10)
        #expect(session.entriesRemoved(under: bigger) == 0)
        session.setLimits(bigger)
        fill(["D", "E", "F"], board, session)
        #expect(session.entries.map { $0.payload.preview } == ["F", "E", "D", "C"])
    }

    @Test func byteLimitChangeIsAppliedToo() async {
        let board = FakeClipboard()
        let session = ClipboardSession(clipboard: board, store: MemoryHistory(),
                                       limits: HistoryLimits(maxEntries: 10, maxTotalBytes: 100, maxEntryBytes: 10))
        await session.start()
        fill(["AAAAA", "BBBBB", "CCCCC"], board, session)
        let tighter = HistoryLimits(maxEntries: 10, maxTotalBytes: 10, maxEntryBytes: 10)
        #expect(session.entriesRemoved(under: tighter) == 1)
        session.setLimits(tighter)
        #expect(session.entries.map { $0.payload.preview } == ["CCCCC", "BBBBB"])
    }

    @Test func limitsAreNotChangedWhileClearIsInFlight() async {
        let board = FakeClipboard(), store = GatedClearHistory()
        let session = ClipboardSession(clipboard: board, store: store)
        await session.start()
        let before = session.limits
        let clearing = Task { await session.clearAll() }
        while !(await store.isWaiting) { await Task.yield() }
        #expect(session.isClearing)
        session.setLimits(HistoryLimits(maxEntries: 1, maxTotalBytes: 10, maxEntryBytes: 5))
        #expect(session.limits.maxEntries == before.maxEntries)
        await store.release()
        await clearing.value
        #expect(!session.isClearing)
    }
}

/// A store whose `clear` stays pending until the test releases it, so Clear All is genuinely in flight.
actor GatedClearHistory: HistoryPersisting {
    private var gate: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { gate != nil }
    func load() -> [ClipboardEntry] { [] }
    func save(_ entries: [ClipboardEntry], revision: UInt64) {}
    func clear(revision: UInt64) async { await withCheckedContinuation { gate = $0 } }
    func release() { gate?.resume(); gate = nil }
}

enum LoginFailure: Error { case denied }

@MainActor final class FakeLoginItem: LoginItemService {
    var status: LoginItemStatus
    var events: [String] = []
    var failRegister = false, failUnregister = false, approvalNeeded = false, registerHasNoEffect = false
    init(_ status: LoginItemStatus) { self.status = status }
    func register() throws {
        events.append("register")
        if failRegister { throw LoginFailure.denied }
        if !registerHasNoEffect { status = approvalNeeded ? .requiresApproval : .enabled }
    }
    func unregister() throws {
        events.append("unregister")
        if failUnregister { throw LoginFailure.denied }
        status = .disabled
    }
    func openSystemSettings() { events.append("settings") }
}

@Suite @MainActor struct LaunchAtLoginTests {
    @Test func turnsOnAndOffAndReportsState() {
        let service = FakeLoginItem(.disabled), login = LaunchAtLogin(service: service)
        #expect(login.state == .off)
        #expect(login.toggle() == .enabled)
        #expect(login.state == .on)
        #expect(login.toggle() == .disabled)
        #expect(login.state == .off)
        #expect(service.events == ["register", "unregister"])
    }

    @Test func approvalIsLeftToTheUserAndOpensSystemSettings() {
        let service = FakeLoginItem(.disabled), login = LaunchAtLogin(service: service)
        service.approvalNeeded = true
        #expect(login.toggle() == .needsApproval)
        #expect(login.state == .needsApproval)
        #expect(login.toggle() == .needsApproval) // already registered: only point at the settings pane
        #expect(service.events == ["register", "settings", "settings"])
    }

    @Test func failuresAreReportedAndLeaveStateUnchanged() {
        let service = FakeLoginItem(.disabled), login = LaunchAtLogin(service: service)
        service.failRegister = true
        if case .failed = login.toggle() {} else { Issue.record("register failure must be reported") }
        #expect(login.state == .off)
        let on = FakeLoginItem(.enabled), onLogin = LaunchAtLogin(service: on)
        on.failUnregister = true
        if case .failed = onLogin.toggle() {} else { Issue.record("unregister failure must be reported") }
        #expect(onLogin.state == .on)
    }

    /// macOS reports "not found" for an app that was never registered, so that must look like "off" and be switchable.
    @Test func aNotFoundStatusLooksOffAndStillTriesToRegister() {
        let service = FakeLoginItem(.unavailable), login = LaunchAtLogin(service: service)
        #expect(login.state == .off)
        #expect(login.toggle() == .enabled)
        #expect(service.events == ["register"])
        #expect(login.state == .on)
    }

    @Test func aRegistrationMacOSDoesNotConfirmIsReportedNotClaimed() {
        let service = FakeLoginItem(.unavailable), login = LaunchAtLogin(service: service)
        service.registerHasNoEffect = true
        #expect(login.toggle() == .unavailable)
        #expect(login.state == .off)
    }

    @Test func aFailedRegistrationFromANotFoundStatusIsReported() {
        let service = FakeLoginItem(.unavailable), login = LaunchAtLogin(service: service)
        service.failRegister = true
        if case .failed = login.toggle() {} else { Issue.record("register failure must be reported") }
    }
}

@Suite @MainActor struct UninstallLoginItemTests {
    let app = URL(fileURLWithPath: "/Applications/Mac ClipBoard.app")
    var history: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/local.macclipboard.app")
    }
    let checks = SelfUninstaller.Checks(readOnly: { _ in false }, deletable: { _ in true }, exists: { _ in true })

    func uninstaller(login: FakeLoginItem?, log: @escaping (String) -> Void, failTrash: Bool = false) -> SelfUninstaller {
        SelfUninstaller(bundleURL: app, identifier: SelfUninstallRules.bundleIdentifier, historyDirectory: history,
                        checks: checks, loginItem: login, trash: { url in
            log("trash:" + url.lastPathComponent)
            if failTrash { throw LoginFailure.denied }
        })
    }

    @Test func loginItemIsTurnedOffBeforeTheAppMovesToTheTrash() {
        let login = FakeLoginItem(.enabled)
        var order: [String] = []
        let u = uninstaller(login: login, log: { order.append($0) })
        #expect(u.uninstall() == .removed(historyMoved: true))
        #expect(login.events == ["unregister"])
        #expect(order.first == "trash:Mac ClipBoard.app")
        #expect(login.status == .disabled)
        #expect(!u.loginItemRemovalFailed)
    }

    @Test func loginItemIsRestoredWhenTheAppCannotBeTrashed() {
        let login = FakeLoginItem(.enabled)
        let u = uninstaller(login: login, log: { _ in }, failTrash: true)
        #expect(u.uninstall() == .trashFailed)
        #expect(login.events == ["unregister", "register"])
        #expect(login.status == .enabled)
    }

    @Test func aLoginItemThatCannotBeRemovedIsReportedButUninstallContinues() {
        let login = FakeLoginItem(.enabled)
        login.failUnregister = true
        let u = uninstaller(login: login, log: { _ in })
        #expect(u.uninstall() == .removed(historyMoved: true))
        #expect(u.loginItemRemovalFailed)
    }

    @Test func nothingIsTouchedWhenLaunchAtLoginWasOffOrUninstallIsRefused() {
        let off = FakeLoginItem(.disabled)
        #expect(uninstaller(login: off, log: { _ in }).uninstall() == .removed(historyMoved: true))
        #expect(off.events.isEmpty)
        let on = FakeLoginItem(.enabled)
        let refused = SelfUninstaller(bundleURL: app, identifier: "local.other.app", historyDirectory: history,
                                      checks: checks, loginItem: on, trash: { _ in Issue.record("must not trash") })
        #expect(refused.uninstall() == .refused(.wrongApplication))
        #expect(on.events.isEmpty)
    }
}
