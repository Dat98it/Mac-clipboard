import Foundation
import ServiceManagement
import MacClipBoardCore

/// The real thing: registers the running app itself as a login item. Never constructed in test
/// environments (`--sandbox`, `--test-system-clipboard`), so a test run cannot change anyone's login items.
@MainActor public final class SystemLoginItemService: LoginItemService {
    public init() {}
    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
