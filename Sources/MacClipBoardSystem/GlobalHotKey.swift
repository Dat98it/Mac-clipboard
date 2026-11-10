import Carbon.HIToolbox
import Foundation
import MacClipBoardCore

/// A system-wide shortcut through Carbon's RegisterEventHotKey. Unlike an event tap it needs no Accessibility
/// or Input Monitoring permission and never sees any other keystroke: macOS only reports the one combination.
/// Never created in test environments unless explicitly asked, so a test run cannot take over the real shortcut.
@MainActor public final class GlobalHotKey: HotkeyRegistering {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handler: (@MainActor () -> Void)?
    public init() {}

    public func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        installEventHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4D43_4248), id: 1) // 'MCBH'
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        hotKeyRef = reference
        self.handler = handler
        return true
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        handler = nil
    }

    private func installEventHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { hotKey.handler?() } }
            return noErr
        }, 1, &spec, me, &handlerRef)
    }
}
