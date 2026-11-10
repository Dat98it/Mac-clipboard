import Foundation
import MacClipBoardCore

/// A private binary property list in Application Support, matching the existing apps' local files.
/// Actor serialization + revisions prevent a save queued before Clear All from resurrecting data.
public actor FileHistoryStore: HistoryPersisting {
    public nonisolated let directory: URL
    private let limits: HistoryLimits
    private var latestRevision: UInt64 = 0
    private var hasRevision = false
    private var clearedRevision: UInt64?
    private var writesFrozen = false
    private var file: URL { directory.appendingPathComponent("history.plist") }
    public init(directory: URL, limits: HistoryLimits = HistoryLimits()) {
        self.directory = directory; self.limits = limits
    }
    public func load() throws -> [ClipboardEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= limits.maxTotalBytes + 2 * 1024 * 1024 else { throw StoreError.invalidArchive }
        let data = try Data(contentsOf: file)
        let archive = try PropertyListDecoder().decode(Archive.self, from: data)
        guard archive.version == 1 else { throw StoreError.invalidArchive }
        return limits.bounded(archive.entries)
    }
    public func save(_ entries: [ClipboardEntry], revision: UInt64) throws {
        guard !writesFrozen else { return }
        guard (!hasRevision || revision >= latestRevision),
              clearedRevision.map({ revision > $0 }) ?? true else { return }
        // Claim before I/O, including failures: older pending requests must stay invalid.
        latestRevision = revision; hasRevision = true
        try write(limits.bounded(entries))
    }
    public func clear(revision: UInt64) throws {
        guard !writesFrozen else { return }
        guard !hasRevision || revision >= latestRevision else { return }
        latestRevision = revision; hasRevision = true
        clearedRevision = revision
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { try FileManager.default.removeItem(at: file) }
        catch {
            // If unlink is denied but replacement is allowed, destroy payload with an empty archive.
            try write([])
        }
    }
    /// An uninstall barrier: requests queued before stopping the monitor cannot recreate the
    /// support directory after it has moved to the Trash. Resume only if app removal fails.
    public func freezeWrites() { writesFrozen = true }
    public func resumeWrites() { writesFrozen = false }
    private func write(_ entries: [ClipboardEntry]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Archive(version: 1, entries: entries))
        // Atomic replacement; .atomic leaves no separate persistent backup of removed history.
        try data.write(to: file, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private struct Archive: Codable { let version: Int; let entries: [ClipboardEntry] }
    private enum StoreError: Error { case invalidArchive }
}
