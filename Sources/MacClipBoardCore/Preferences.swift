import Foundation

/// The few user-adjustable limits. Only fixed choices are accepted, so a hand-edited or damaged
/// settings file can never produce an absurd limit: unknown values fall back to the defaults.
public struct Preferences: Codable, Equatable, Sendable {
    public static let entryChoices = [50, 100, 200]
    public static let totalMiBChoices = [16, 32, 64]
    public static let defaultEntries = 100
    public static let defaultTotalMiB = 32

    public private(set) var maxEntries: Int
    public private(set) var maxTotalMiB: Int
    public private(set) var hotkey: HotkeyChoice

    public init(maxEntries: Int = Preferences.defaultEntries, maxTotalMiB: Int = Preferences.defaultTotalMiB,
                hotkey: HotkeyChoice = .default) {
        self.hotkey = hotkey
        self.maxEntries = Self.entryChoices.contains(maxEntries) ? maxEntries : Self.defaultEntries
        self.maxTotalMiB = Self.totalMiBChoices.contains(maxTotalMiB) ? maxTotalMiB : Self.defaultTotalMiB
    }
    public mutating func setMaxEntries(_ value: Int) { self = Preferences(maxEntries: value, maxTotalMiB: maxTotalMiB, hotkey: hotkey) }
    public mutating func setMaxTotalMiB(_ value: Int) { self = Preferences(maxEntries: maxEntries, maxTotalMiB: value, hotkey: hotkey) }
    public mutating func setHotkey(_ value: HotkeyChoice) { hotkey = value }

    private enum CodingKeys: String, CodingKey { case maxEntries, maxTotalMiB, hotkey }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Settings written before the shortcut existed have no `hotkey`; an unknown value also means the default.
        let storedHotkey = (try? values.decodeIfPresent(String.self, forKey: .hotkey)) ?? nil
        self.init(maxEntries: try values.decodeIfPresent(Int.self, forKey: .maxEntries) ?? Self.defaultEntries,
                  maxTotalMiB: try values.decodeIfPresent(Int.self, forKey: .maxTotalMiB) ?? Self.defaultTotalMiB,
                  hotkey: storedHotkey.flatMap(HotkeyChoice.init(rawValue:)) ?? .default)
    }

    public var limits: HistoryLimits {
        HistoryLimits(maxEntries: maxEntries, maxTotalBytes: maxTotalMiB * 1024 * 1024)
    }
}

extension HistoryLimits {
    /// The largest limits the settings allow. The history file is bounded by these, never by the smaller
    /// active limits, so raising a limit later cannot find the file already trimmed.
    public static var ceiling: HistoryLimits {
        HistoryLimits(maxEntries: Preferences.entryChoices.max()!, maxTotalBytes: Preferences.totalMiBChoices.max()! * 1024 * 1024)
    }
}
