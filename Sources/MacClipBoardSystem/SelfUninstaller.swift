import AppKit
import MacClipBoardCore

/// Adapted from AppClean/SelfUninstaller.swift and ShelfDrop/Uninstaller.swift.
/// All destructive effects are injectable. Tests never trash real apps or user data.
@MainActor public final class SelfUninstaller {
    public struct Checks {
        public var readOnly: (URL) -> Bool
        public var deletable: (URL) -> Bool
        public var exists: (URL) -> Bool
        public init(readOnly: @escaping (URL) -> Bool, deletable: @escaping (URL) -> Bool, exists: @escaping (URL) -> Bool) {
            self.readOnly = readOnly; self.deletable = deletable; self.exists = exists
        }
        public static var live: Checks {
            Checks(readOnly: { (try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? true },
                   deletable: { FileManager.default.isDeletableFile(atPath: $0.path) },
                   exists: { FileManager.default.fileExists(atPath: $0.path) })
        }
    }
    public enum Outcome: Equatable {
        case removed(historyMoved: Bool), refused(SelfUninstallRules.Availability), trashFailed
    }
    public let bundleURL: URL
    private let identifier: String?
    private let historyDirectory: URL
    private let testEnvironment: Bool
    private let checks: Checks
    private let trash: (URL) throws -> Void
    private let loginItem: LoginItemService?
    /// Set when Launch at Login was on and could not be turned off, so the caller can say where to remove it.
    public private(set) var loginItemRemovalFailed = false

    public init(bundleURL: URL = Bundle.main.bundleURL, identifier: String? = Bundle.main.bundleIdentifier,
                historyDirectory: URL, testEnvironment: Bool = false, checks: Checks = .live,
                loginItem: LoginItemService? = nil,
                trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.bundleURL = bundleURL; self.identifier = identifier; self.historyDirectory = historyDirectory
        self.testEnvironment = testEnvironment; self.checks = checks; self.trash = trash; self.loginItem = loginItem
    }
    public var availability: SelfUninstallRules.Availability {
        guard !testEnvironment else { return .testEnvironment }
        // The only data directory eligible for removal is this app's dedicated support directory.
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/" + SelfUninstallRules.bundleIdentifier).standardizedFileURL
        guard historyDirectory.standardizedFileURL == expected else { return .testEnvironment }
        return SelfUninstallRules.availability(bundleURL: bundleURL, identifier: identifier,
                                              readOnly: checks.readOnly(bundleURL), deletable: checks.deletable(bundleURL))
    }
    /// Caller must stop monitoring, finish saves and freeze the history store before invoking this.
    public func uninstall() -> Outcome {
        let state = availability
        guard state == .available else { return .refused(state) }
        // Stop it launching at login first, while the app is still where macOS expects it.
        loginItemRemovalFailed = false
        let loginWasOn = loginItem.map { $0.status == .enabled || $0.status == .requiresApproval } ?? false
        if loginWasOn {
            do { try loginItem?.unregister() } catch { loginItemRemovalFailed = true }
        }
        do { try trash(bundleURL) } catch {
            if loginWasOn && !loginItemRemovalFailed { try? loginItem?.register() }
            return .trashFailed
        }
        guard checks.exists(historyDirectory) else { return .removed(historyMoved: true) }
        do { try trash(historyDirectory); return .removed(historyMoved: true) }
        catch { return .removed(historyMoved: false) }
    }
}
