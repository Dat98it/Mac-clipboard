import Foundation
import MacClipBoardCore

/// Settings live in the app's own data directory (not UserDefaults), so `--sandbox` stays isolated and
/// uninstalling takes them along with the history. They hold no clipboard content, so a missing or damaged
/// file simply means the defaults.
public struct PreferencesStore: Sendable {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("settings.plist") }
    public init(directory: URL) { self.directory = directory }

    public func load() -> Preferences {
        guard let data = try? Data(contentsOf: file),
              let preferences = try? PropertyListDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return preferences
    }

    public func save(_ preferences: Preferences) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(preferences).write(to: file, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
