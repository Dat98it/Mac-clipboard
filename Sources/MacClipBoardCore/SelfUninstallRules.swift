import Foundation

/// Safety decisions stay in Core, as in AppClean/MacClean.
public enum SelfUninstallRules {
    public static let bundleIdentifier = "local.macclipboard.app"
    public enum Availability: Equatable {
        case available, developmentBuild, wrongApplication, readOnlyVolume, notDeletable, testEnvironment
    }
    public static func availability(bundleURL: URL, identifier: String?, readOnly: Bool, deletable: Bool) -> Availability {
        guard bundleURL.pathExtension == "app" else { return .developmentBuild }
        guard identifier == bundleIdentifier else { return .wrongApplication }
        guard !readOnly else { return .readOnlyVolume }
        guard deletable else { return .notDeletable }
        return .available
    }
}
