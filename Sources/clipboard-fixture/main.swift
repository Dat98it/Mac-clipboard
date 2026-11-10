// A standalone, synthetic-only editor for verifying the real Cmd+V path without opening user files.
import AppKit

@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let editor = NSTextView()
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Mac ClipBoard — Synthetic Editor"
        window.isReleasedWhenClosed = false
        let root = NSStackView()
        root.orientation = .vertical; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let label = NSTextField(labelWithString: "Synthetic fixtures only · Click Copy A, then Copy B, then select A in history.")
        label.lineBreakMode = .byWordWrapping
        root.addArrangedSubview(label)
        let buttons = NSStackView()
        for (title, action) in [("Copy Fixture A", #selector(copyA)), ("Copy Fixture B", #selector(copyB)), ("Focus Editor", #selector(focusEditor))] {
            let button = NSButton(title: title, target: self, action: action)
            button.refusesFirstResponder = true
            buttons.addArrangedSubview(button)
        }
        root.addArrangedSubview(buttons)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        editor.isRichText = true; editor.isEditable = true; editor.isSelectable = true
        editor.font = NSFont.systemFont(ofSize: 17)
        editor.autoresizingMask = [.width]; editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityIdentifier("fixture.editor")
        scroll.documentView = editor
        root.addArrangedSubview(scroll)
        window.contentView = root
        let menu = NSMenu(), edit = NSMenu()
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit; menu.addItem(item)
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        window.setFrameOrigin(NSPoint(x: 80, y: 180))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.activate()
    }
    @objc func copyA() {
        let item = NSPasteboardItem()
        item.setString("Fixture A — Tiếng Việt 🧪\nSecond line", forType: .string)
        item.setString("<html><head><meta charset=\"utf-8\"></head><body><b>Fixture A — Tiếng Việt 🧪</b><br>Second line</body></html>", forType: .html)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        window.makeFirstResponder(editor)
    }
    @objc func copyB() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Fixture B — newest", forType: .string)
        window.makeFirstResponder(editor)
    }
    @objc func focusEditor() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.activate()
        NSRunningApplication.current.activate(options: [])
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { FixtureDelegate() }
app.delegate = delegate
app.run()
