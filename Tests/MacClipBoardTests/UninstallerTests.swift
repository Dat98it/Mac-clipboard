import Foundation
import Testing
@testable import MacClipBoardCore
@testable import MacClipBoardSystem

@Suite @MainActor struct UninstallerTests {
    let app = URL(fileURLWithPath: "/Applications/Mac ClipBoard.app")
    // A path value only: fake checks/effects never access this directory.
    var history: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/local.macclipboard.app")
    }
    let checks = SelfUninstaller.Checks(readOnly: { _ in false }, deletable: { _ in true }, exists: { _ in true })

    @Test func developmentFoldersOtherAppsAndRestrictedVolumesAreNeverRemovable() {
        let rules = SelfUninstallRules.self
        #expect(rules.availability(bundleURL: URL(fileURLWithPath: "/tmp/project/.build/debug"), identifier: rules.bundleIdentifier, readOnly: false, deletable: true) == .developmentBuild)
        #expect(rules.availability(bundleURL: app, identifier: "local.other.app", readOnly: false, deletable: true) == .wrongApplication)
        #expect(rules.availability(bundleURL: app, identifier: nil, readOnly: false, deletable: true) == .wrongApplication)
        #expect(rules.availability(bundleURL: app, identifier: rules.bundleIdentifier, readOnly: true, deletable: true) == .readOnlyVolume)
        #expect(rules.availability(bundleURL: app, identifier: rules.bundleIdentifier, readOnly: false, deletable: false) == .notDeletable)
    }

    @Test func movesExactlyOwnBundleThenOwnHistory() {
        var moved: [URL] = []
        let uninstaller = SelfUninstaller(bundleURL: app, identifier: SelfUninstallRules.bundleIdentifier,
                                          historyDirectory: history, checks: checks, trash: { moved.append($0) })
        #expect(uninstaller.availability == .available)
        #expect(uninstaller.uninstall() == .removed(historyMoved: true))
        #expect(moved == [app, history])
    }

    @Test func failedAppRemovalLeavesHistoryInPlace() {
        var attempted: [URL] = []
        let uninstaller = SelfUninstaller(bundleURL: app, identifier: SelfUninstallRules.bundleIdentifier,
                                          historyDirectory: history, checks: checks, trash: {
            attempted.append($0); throw Failure.trash
        })
        #expect(uninstaller.uninstall() == .trashFailed)
        #expect(attempted == [app])
    }

    @Test func historyRemovalFailureIsReportedSeparately() {
        let uninstaller = SelfUninstaller(bundleURL: app, identifier: SelfUninstallRules.bundleIdentifier,
                                          historyDirectory: history, checks: checks, trash: {
            if $0 == history { throw Failure.trash }
        })
        #expect(uninstaller.uninstall() == .removed(historyMoved: false))
    }

    @Test func refusesTestModeAndArbitraryDataDirectoriesWithoutEffects() {
        var calls = 0
        let test = SelfUninstaller(bundleURL: app, identifier: SelfUninstallRules.bundleIdentifier,
                                  historyDirectory: history, testEnvironment: true, checks: checks, trash: { _ in calls += 1 })
        let wrongFolder = SelfUninstaller(bundleURL: app, identifier: SelfUninstallRules.bundleIdentifier,
                                         historyDirectory: URL(fileURLWithPath: "/tmp/unrelated-fixture"), checks: checks, trash: { _ in calls += 1 })
        #expect(test.uninstall() == .refused(.testEnvironment))
        #expect(wrongFolder.uninstall() == .refused(.testEnvironment))
        #expect(calls == 0)
    }

    @Test func refusesWrongIdentityBeforeAnyEffect() {
        var calls = 0
        let uninstaller = SelfUninstaller(bundleURL: app, identifier: "local.fixture.other",
                                          historyDirectory: history, checks: checks, trash: { _ in calls += 1 })
        #expect(uninstaller.uninstall() == .refused(.wrongApplication))
        #expect(calls == 0)
    }
    enum Failure: Error { case trash }
}

@Suite struct UninstallPersistenceTests {
    @Test func frozenStoreCannotRecreateHistoryAfterUninstall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClipBoardUninstall-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("support")
        let store = FileHistoryStore(directory: directory)
        let entry = ClipboardEntry(payload: payload("Synthetic uninstall fixture"))
        try await store.save([entry], revision: 1)
        await store.freezeWrites()
        try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("trashed-fixture"))
        try await store.save([entry], revision: 2)
        try await store.clear(revision: 3)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await store.resumeWrites()
        try await store.save([entry], revision: 4)
        let restored = try await store.load()
        #expect(restored == [entry])
    }
}
