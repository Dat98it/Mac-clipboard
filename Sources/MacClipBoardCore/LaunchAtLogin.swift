import Foundation

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    /// Registered, but macOS wants the user to allow it in System Settings → General → Login Items.
    case requiresApproval
    case disabled
    /// macOS cannot find this app to register (for example, it is not a proper app bundle).
    case unavailable
}

/// What the login-item logic needs from macOS. A protocol so tests never touch the real login items.
@MainActor public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// The logic behind "Launch at Login". It is off until the user turns it on.
@MainActor public final class LaunchAtLogin {
    /// `.unavailable` means there is no login-item service at all (test environments). A service that merely
    /// reports "not found" is `.off`: macOS answers that way for an app that was never registered.
    public enum State: Equatable, Sendable { case on, off, needsApproval, unavailable }
    public enum Outcome: Equatable, Sendable {
        case enabled, disabled
        /// register() did not fail, but macOS still does not list the app: not confirmed, so not claimed.
        case unavailable
        /// The user has to switch it on in System Settings; that pane was opened for them.
        case needsApproval
        case failed(String)
    }
    public let service: LoginItemService
    public init(service: LoginItemService) { self.service = service }

    public var state: State {
        switch service.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .disabled: return .off
        case .unavailable: return .off
        }
    }

    @discardableResult
    public func toggle() -> Outcome {
        switch service.status {
        case .enabled:
            do { try service.unregister(); return .disabled }
            catch { return .failed(error.localizedDescription) }
        case .requiresApproval:
            // Already registered; only the user can approve it, so take them there.
            service.openSystemSettings()
            return .needsApproval
        case .disabled, .unavailable:
            do { try service.register() } catch { return .failed(error.localizedDescription) }
            if service.status == .requiresApproval { service.openSystemSettings(); return .needsApproval }
            if service.status == .unavailable { return .unavailable }
            return .enabled
        }
    }
}
