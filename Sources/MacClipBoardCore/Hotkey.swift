import Foundation

/// The global shortcut that shows or hides the history. Fixed choices only (a hand-edited settings file
/// cannot register an arbitrary key), all on the V key and none of them needing any permission.
public enum HotkeyChoice: String, Codable, CaseIterable, Sendable {
    case commandShiftV, controlOptionV, controlOptionCommandV, off

    /// ⇧⌘V is the usual "paste from history" shortcut of clipboard managers. It is also "paste as plain text" in many
    /// apps, which a global shortcut shadows system-wide; ⌃⌥V and ⌃⌥⌘V are the choices that leave that alone.
    public static let `default` = HotkeyChoice.commandShiftV

    /// Virtual key code of V (kVK_ANSI_V), nil when the shortcut is off.
    public var keyCode: UInt32? { self == .off ? nil : 9 }

    /// Carbon modifier masks: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
    public var modifiers: UInt32 {
        switch self {
        case .controlOptionV: return 0x1000 | 0x800
        case .controlOptionCommandV: return 0x1000 | 0x800 | 0x100
        case .commandShiftV: return 0x100 | 0x200
        case .off: return 0
        }
    }

    public var symbols: String {
        switch self {
        case .controlOptionV: return "⌃⌥V"
        case .controlOptionCommandV: return "⌃⌥⌘V"
        case .commandShiftV: return "⇧⌘V"
        case .off: return ""
        }
    }
}

public enum HotkeyStatus: Equatable, Sendable {
    case off
    case registered(HotkeyChoice)
    /// macOS refused the combination, typically because another app already owns it.
    case unavailable(HotkeyChoice)
}

/// What the shortcut logic needs from the system. A protocol so tests never register a real global shortcut.
@MainActor public protocol HotkeyRegistering: AnyObject {
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

@MainActor public final class HotkeyController {
    public private(set) var status: HotkeyStatus = .off
    private let service: HotkeyRegistering
    private let onPress: @MainActor () -> Void
    public init(service: HotkeyRegistering, onPress: @escaping @MainActor () -> Void) {
        self.service = service; self.onPress = onPress
    }

    /// Replaces whatever was registered. The previous shortcut is released first, so switching never leaves two.
    @discardableResult
    public func apply(_ choice: HotkeyChoice) -> HotkeyStatus {
        service.unregister()
        guard let keyCode = choice.keyCode else { status = .off; return status }
        status = service.register(keyCode: keyCode, modifiers: choice.modifiers, handler: onPress)
            ? .registered(choice) : .unavailable(choice)
        return status
    }

    public func stop() { service.unregister(); status = .off }
}
