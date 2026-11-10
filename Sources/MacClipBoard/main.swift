import AppKit
import MacClipBoardCore
import MacClipBoardSystem

// Like the sibling apps, testing uses an explicit isolated environment. This mode never accesses
// NSPasteboard.general or ~/Library; it contains no fabricated history items.
let args = CommandLine.arguments
let isolated: Bool
let pasteboard: NSPasteboard
let directory: URL
if args.contains("--sandbox") && args.contains("--test-system-clipboard") { exit(64) }
if let i = args.firstIndex(of: "--sandbox") {
    guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { exit(64) }
    isolated = true
    directory = URL(fileURLWithPath: args[i + 1], isDirectory: true)
    pasteboard = NSPasteboard(name: NSPasteboard.Name("local.macclipboard.test.\(directory.lastPathComponent)"))
} else if let i = args.firstIndex(of: "--test-system-clipboard") {
    guard i + 1 < args.count else { exit(64) }
    let path = URL(fileURLWithPath: args[i + 1]).standardizedFileURL.path
    guard path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/") else { exit(64) }
    isolated = false
    directory = URL(fileURLWithPath: path, isDirectory: true)
    pasteboard = .general
    // Intentionally replace, never read/restore the user's existing clipboard during this opt-in test.
    pasteboard.clearContents()
    pasteboard.setString("Mac ClipBoard synthetic test baseline", forType: .string)
} else {
    isolated = false
    directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/local.macclipboard.app", isDirectory: true)
    pasteboard = .general
}
let testing = isolated || args.contains("--test-system-clipboard")
let preferencesStore = PreferencesStore(directory: directory)
let preferences = preferencesStore.load()
// Real login items are touched only by a normal run, never by --sandbox or --test-system-clipboard.
// The global shortcut is likewise a normal-run feature; --enable-hotkey lets a --sandbox run try it deliberately.
let hotkeyAllowed = !testing || (isolated && args.contains("--enable-hotkey"))
let launchAtLogin: LaunchAtLogin? = testing ? nil : MainActor.assumeIsolated { LaunchAtLogin(service: SystemLoginItemService()) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated {
    AppDelegate(clipboard: MacPasteboard(pasteboard), store: FileHistoryStore(directory: directory, limits: .ceiling), isolated: isolated,
                preferencesStore: preferencesStore, preferences: preferences, launchAtLogin: launchAtLogin,
                hotkeyAllowed: hotkeyAllowed)
}
app.delegate = delegate
app.run()
