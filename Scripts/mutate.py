#!/usr/bin/env python3 -I
"""Mutation check for the safety gates: breaks one guard at a time (a literal text replacement),
runs the tests, and expects them to fail. A mutation the tests do not catch is reported as SURVIVED.
Every file is restored after each mutation, also on Ctrl-C or SIGTERM.

Adapted from MacClean's Scripts/mutate.py (same idea, literal replacements).
Usage: Scripts/mutate.py [name-filter ...] run the mutations whose name contains any filter (all by default)
       Scripts/mutate.py --check           only verify that every pattern still matches the sources
Refuses to run while Sources/ has uncommitted changes, so a restore can never lose work.
"""
import os
import signal
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = "Sources/MacClipBoardCore/"
SYS = "Sources/MacClipBoardSystem/"

# name, file, text to find (must occur), replacement (every occurrence)
MUTATIONS = [
    # ClipboardSession: monitoring, paste, clear, load
    ("session-start-reads-clipboard", CORE + "ClipboardSession.swift",
     "observedCount = clipboard.changeCount\n        isLoading = true; onChange?()", "observedCount = -1\n        isLoading = true; onChange?()"),
    ("session-own-restore-suppressed", CORE + "ClipboardSession.swift",
     "observedCount = clipboard.changeCount // Suppress only our own write, not a future user copy.", ""),
    ("session-resume-skips-pause-copies", CORE + "ClipboardSession.swift",
     "isPaused = paused\n        // Resuming never reads material copied during the pause.\n        observedCount = clipboard.changeCount", "isPaused = paused"),
    ("session-poll-ignores-pause", CORE + "ClipboardSession.swift",
     "guard hasStarted, !isLoading, !isPaused, !isClearing else { return }", "guard hasStarted, !isLoading, !isClearing else { return }"),
    ("session-poll-during-clear", CORE + "ClipboardSession.swift",
     "guard hasStarted, !isLoading, !isPaused, !isClearing else { return }", "guard hasStarted, !isLoading, !isPaused else { return }"),
    ("session-poll-during-load", CORE + "ClipboardSession.swift",
     "guard hasStarted, !isLoading, !isPaused, !isClearing else { return }", "guard hasStarted, !isPaused, !isClearing else { return }"),
    ("session-unstable-read-retry", CORE + "ClipboardSession.swift", "if result == .changedDuringRead { return }", ""),
    ("session-dedup", CORE + "ClipboardSession.swift", "entries.removeAll { $0.payload == payload }", ""),
    ("session-dedup-keeps-pin", CORE + "ClipboardSession.swift",
     "let wasPinned = entries.contains { $0.payload == payload && $0.isPinned }", "let wasPinned = false"),
    ("session-restore-failure", CORE + "ClipboardSession.swift",
     "guard restored else { isPasting = false; notice = .restoreFailed; onChange?(); return }", ""),
    ("session-restore-failure-leaves-busy", CORE + "ClipboardSession.swift",
     "guard restored else { isPasting = false; notice = .restoreFailed; onChange?(); return }",
     "guard restored else { notice = .restoreFailed; onChange?(); return }"),
    ("session-paste-token", CORE + "ClipboardSession.swift", "return self.operation == token && !self.isClearing", "return true"),
    ("session-select-during-clear", CORE + "ClipboardSession.swift",
     "guard !isClearing, !isLoading, let entry = entries.first(where: { $0.id == id }) else { return }",
     "guard let entry = entries.first(where: { $0.id == id }) else { return }"),
    ("session-clear-cancels-save", CORE + "ClipboardSession.swift",
     "saveTask?.cancel(); saveTask = nil\n        isClearing = true; isPasting = false", "isClearing = true; isPasting = false"),
    ("session-clear-invalidates-paste", CORE + "ClipboardSession.swift",
     "operation += 1; revision += 1\n        let clearRevision = revision", "revision += 1\n        let clearRevision = revision"),
    ("session-clear-empties-clipboard", CORE + "ClipboardSession.swift", "entries = []\n        clipboard.clear()", "entries = []"),
    ("session-clear-failure-pauses", CORE + "ClipboardSession.swift",
     "isPaused = true // Do not silently overwrite a failed deletion with new history.", ""),
    ("session-load-failure-pauses", CORE + "ClipboardSession.swift",
     "catch { notice = .loadFailed; isPaused = true }", "catch { notice = .loadFailed }"),
    ("session-flush-after-clear-failure", CORE + "ClipboardSession.swift",
     "guard notice != .clearFailed, !isLoading else { return }", "guard !isLoading else { return }"),
    ("session-load-bounded", CORE + "ClipboardSession.swift",
     "if revision == initialRevision { entries = limits.bounded(loaded) }", "if revision == initialRevision { entries = loaded }"),
    ("session-load-race", CORE + "ClipboardSession.swift", "if revision == initialRevision {", "if true {"),
    # Pinning, deleting, limit changes
    ("session-pin-count-cap", CORE + "ClipboardSession.swift",
     "guard current.count < limits.maxPinnedEntries, bytes <= limits.maxPinnedBytes else {", "guard bytes <= limits.maxPinnedBytes else {"),
    ("session-pin-bytes-cap", CORE + "ClipboardSession.swift",
     "guard current.count < limits.maxPinnedEntries, bytes <= limits.maxPinnedBytes else {", "guard current.count < limits.maxPinnedEntries else {"),
    ("session-delete-guard", CORE + "ClipboardSession.swift",
     "guard !isClearing, !isLoading, let index = entries.firstIndex(where: { $0.id == id }) else { return }",
     "guard let index = entries.firstIndex(where: { $0.id == id }) else { return }"),
    ("session-setlimits-guard", CORE + "ClipboardSession.swift",
     "guard !isLoading, !isClearing else { return }\n        limits = newLimits", "limits = newLimits"),
    ("session-setlimits-bounded", CORE + "ClipboardSession.swift", "let bounded = newLimits.bounded(entries)", "let bounded = entries"),
    ("session-removal-count", CORE + "ClipboardSession.swift", "entries.count - candidate.bounded(entries).count", "0"),
    # Limits, payload validity, entry coding
    ("bounded-pinned-first", CORE + "ClipboardEntry.swift", "for entry in valid where entry.isPinned {", "for entry in valid where false {"),
    ("bounded-pinned-count-cap", CORE + "ClipboardEntry.swift",
     "guard keep.count < min(maxPinnedEntries, maxEntries), pinnedUsed + size <= maxPinnedBytes else { continue }",
     "guard pinnedUsed + size <= maxPinnedBytes else { continue }"),
    ("bounded-pinned-bytes-cap", CORE + "ClipboardEntry.swift",
     "guard keep.count < min(maxPinnedEntries, maxEntries), pinnedUsed + size <= maxPinnedBytes else { continue }",
     "guard keep.count < min(maxPinnedEntries, maxEntries) else { continue }"),
    ("bounded-total-bytes", CORE + "ClipboardEntry.swift", "guard used + entry.payload.byteCount <= maxTotalBytes else { continue }", ""),
    ("bounded-entry-count", CORE + "ClipboardEntry.swift", ".prefix(max(0, maxEntries - keep.count))", ".prefix(Int.max)"),
    ("bounded-unique-ids", CORE + "ClipboardEntry.swift", "ids.insert($0.id).inserted", "true"),
    ("bounded-valid-only", CORE + "ClipboardEntry.swift", "$0.payload.isValid(limits: self) && ", ""),
    ("entry-legacy-decode", CORE + "ClipboardEntry.swift",
     "isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false", "isPinned = try values.decode(Bool.self, forKey: .isPinned)"),
    ("payload-valid-bytes", CORE + "ClipboardEntry.swift", "byteCount > 0 && byteCount <= limits.maxEntryBytes", "byteCount > 0"),
    ("payload-valid-types", CORE + "ClipboardEntry.swift", "item.allSatisfy { Self.supportedTypes.contains($0.type) }", "true"),
    ("payload-valid-item-count", CORE + "ClipboardEntry.swift", "!items.isEmpty && items.count <= 128 &&", "!items.isEmpty &&"),
    ("payload-file-detection", CORE + "ClipboardEntry.swift",
     '!items.isEmpty && items.allSatisfy { $0.contains { $0.type == "public.file-url" } }',
     '!items.isEmpty && items.contains { $0.contains { $0.type == "public.file-url" } }'),
    # FileHistoryStore: stale writes, freezing, permissions, bad files
    ("store-stale-save-after-clear", SYS + "FileHistoryStore.swift", "clearedRevision.map({ revision > $0 }) ?? true else { return }", "true else { return }"),
    ("store-stale-revision-save", SYS + "FileHistoryStore.swift", "guard (!hasRevision || revision >= latestRevision),", "guard true,"),
    ("store-stale-revision-clear", SYS + "FileHistoryStore.swift", "guard !hasRevision || revision >= latestRevision else { return }", "guard true else { return }"),
    ("store-freeze-save", SYS + "FileHistoryStore.swift", "guard !writesFrozen else { return }\n        guard (!hasRevision", "guard (!hasRevision"),
    ("store-freeze-clear", SYS + "FileHistoryStore.swift", "guard !writesFrozen else { return }\n        guard !hasRevision ||", "guard !hasRevision ||"),
    ("store-file-permissions", SYS + "FileHistoryStore.swift", "[.posixPermissions: 0o600], ofItemAtPath: file.path", "[.posixPermissions: 0o644], ofItemAtPath: file.path"),
    ("store-dir-permissions", SYS + "FileHistoryStore.swift", "try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)", ""),
    ("store-atomic-write", SYS + "FileHistoryStore.swift", "try data.write(to: file, options: [.atomic])", "try data.write(to: file)"),
    ("store-archive-version", SYS + "FileHistoryStore.swift", "guard archive.version == 1 else { throw StoreError.invalidArchive }", ""),
    ("store-size-limit", SYS + "FileHistoryStore.swift", "guard size <= limits.maxTotalBytes + 2 * 1024 * 1024 else { throw StoreError.invalidArchive }", ""),
    ("store-load-bounded", SYS + "FileHistoryStore.swift", "return limits.bounded(archive.entries)", "return archive.entries"),
    ("store-save-bounded", SYS + "FileHistoryStore.swift", "try write(limits.bounded(entries))", "try write(entries)"),
    ("store-missing-file-is-empty", SYS + "FileHistoryStore.swift", "guard FileManager.default.fileExists(atPath: file.path) else { return [] }", ""),
    # PreferencesStore
    ("prefs-dir-permissions", SYS + "PreferencesStore.swift", "attributes: [.posixPermissions: 0o700])", "attributes: [.posixPermissions: 0o755])"),
    ("prefs-file-permissions", SYS + "PreferencesStore.swift", "[.posixPermissions: 0o600], ofItemAtPath: file.path", "[.posixPermissions: 0o644], ofItemAtPath: file.path"),
    # MacPasteboard: what is captured and how it is restored
    ("capture-private-content", SYS + "MacPasteboard.swift",
     "if source.contains(where: { !$0.types.map({ $0.rawValue }).filter(privateTypes.contains).isEmpty }) {", "if false {"),
    ("capture-item-limit", SYS + "MacPasteboard.swift", "guard source.count <= 128 else { return .tooLarge }", ""),
    ("capture-size-limit", SYS + "MacPasteboard.swift", "guard bytes <= limits.maxEntryBytes else { return .tooLarge }", ""),
    ("capture-unstable", SYS + "MacPasteboard.swift", "guard before == changeCount else { return .changedDuringRead }", ""),
    ("capture-partial-item", SYS + "MacPasteboard.swift", "guard !item.isEmpty else { return .unsupported }", ""),
    ("capture-file-count", SYS + "MacPasteboard.swift", "urls.count == source.count else {", "true else {"),
    ("restore-validates", SYS + "MacPasteboard.swift", "guard payload.isValid(limits: HistoryLimits()) else { return false }", ""),
    ("restore-all-files-reachable", SYS + "MacPasteboard.swift",
     "(try? pathURL.checkResourceIsReachable()) == true else { return false }", "true else { return false }"),
    ("restore-files-stay-files", SYS + "MacPasteboard.swift", "return pasteboard.writeObjects(files)",
     'pasteboard.setString(files.map { $0.path ?? "" }.joined(separator: "\\n"), forType: .string); return true'),
    # Self-uninstall
    ("rules-development-build", CORE + "SelfUninstallRules.swift", 'guard bundleURL.pathExtension == "app" else { return .developmentBuild }', ""),
    ("rules-identity", CORE + "SelfUninstallRules.swift", "guard identifier == bundleIdentifier else { return .wrongApplication }", ""),
    ("rules-read-only", CORE + "SelfUninstallRules.swift", "guard !readOnly else { return .readOnlyVolume }", ""),
    ("rules-deletable", CORE + "SelfUninstallRules.swift", "guard deletable else { return .notDeletable }", ""),
    ("uninstall-test-environment", SYS + "SelfUninstaller.swift", "guard !testEnvironment else { return .testEnvironment }", ""),
    ("uninstall-own-directory", SYS + "SelfUninstaller.swift", "guard historyDirectory.standardizedFileURL == expected else { return .testEnvironment }", ""),
    ("uninstall-checks-first", SYS + "SelfUninstaller.swift",
     "let state = availability\n        guard state == .available else { return .refused(state) }", "let state = availability"),
    ("uninstall-login-off", SYS + "SelfUninstaller.swift", "do { try loginItem?.unregister() } catch { loginItemRemovalFailed = true }", ""),
    ("uninstall-login-restore", SYS + "SelfUninstaller.swift", "if loginWasOn && !loginItemRemovalFailed { try? loginItem?.register() }", ""),
    ("uninstall-trash-failure", SYS + "SelfUninstaller.swift", "return .trashFailed", "return .removed(historyMoved: true)"),
    ("uninstall-history-failure-reported", SYS + "SelfUninstaller.swift", "catch { return .removed(historyMoved: false) }", "catch { return .removed(historyMoved: true) }"),
    ("uninstall-history-exists-check", SYS + "SelfUninstaller.swift", "guard checks.exists(historyDirectory) else { return .removed(historyMoved: true) }", ""),
    # Paste focus: when it is safe to press Cmd+V
    ("paste-focus-prefers-window", CORE + "PasteFocusRules.swift", "if hasElement { return .element }", "if hasWindow { return .window }"),
    ("paste-focus-nothing-is-fine", CORE + "PasteFocusRules.swift", "return hasWindow ? .window : .refuse", "return .window"),
    ("paste-allowed-when-refused", CORE + "PasteFocusRules.swift", "plan != .refuse && frontmostIsTarget", "frontmostIsTarget"),
    ("paste-allowed-when-not-frontmost", CORE + "PasteFocusRules.swift", "frontmostIsTarget && focusMatches", "focusMatches"),
    ("paste-allowed-when-focus-differs", CORE + "PasteFocusRules.swift", "focusMatches && !modifiersHeld", "!modifiersHeld"),
    ("paste-allowed-with-modifiers-held", CORE + "PasteFocusRules.swift", "focusMatches && !modifiersHeld", "focusMatches"),
    # Global shortcut and its setting
    ("hotkey-key-code", CORE + "Hotkey.swift", "self == .off ? nil : 9", "self == .off ? nil : 0"),
    ("hotkey-control-option", CORE + "Hotkey.swift", "case .controlOptionV: return 0x1000 | 0x800", "case .controlOptionV: return 0x1000"),
    ("hotkey-all-three-modifiers", CORE + "Hotkey.swift", "case .controlOptionCommandV: return 0x1000 | 0x800 | 0x100", "case .controlOptionCommandV: return 0x1000 | 0x800"),
    ("hotkey-command-shift", CORE + "Hotkey.swift", "case .commandShiftV: return 0x100 | 0x200", "case .commandShiftV: return 0x100"),
    ("hotkey-default", CORE + "Hotkey.swift", "public static let `default` = HotkeyChoice.commandShiftV", "public static let `default` = HotkeyChoice.controlOptionV"),
    ("hotkey-unregister-first", CORE + "Hotkey.swift", "service.unregister()\n        guard let keyCode", "guard let keyCode"),
    ("hotkey-off-registers", CORE + "Hotkey.swift",
     "guard let keyCode = choice.keyCode else { status = .off; return status }", "let keyCode = choice.keyCode ?? 9"),
    ("hotkey-failure-claimed", CORE + "Hotkey.swift", "? .registered(choice) : .unavailable(choice)", "? .registered(choice) : .registered(choice)"),
    ("hotkey-stop-releases", CORE + "Hotkey.swift", "public func stop() { service.unregister(); status = .off }", "public func stop() { status = .off }"),
    ("prefs-hotkey-default", CORE + "Preferences.swift", "HotkeyChoice.init(rawValue:)) ?? .default)", "HotkeyChoice.init(rawValue:)) ?? .off)"),
    ("prefs-hotkey-kept", CORE + "Preferences.swift",
     "self = Preferences(maxEntries: value, maxTotalMiB: maxTotalMiB, hotkey: hotkey)", "self = Preferences(maxEntries: value, maxTotalMiB: maxTotalMiB)"),
    # Files are not "lost formats"
    ("file-warning-hidden", CORE + "ClipboardEntry.swift",
     "public var showsOmittedWarning: Bool { lostContentCount > 0 && !containsOnlyFileReferences }", "public var showsOmittedWarning: Bool { lostContentCount > 0 }"),
    ("text-warning-from-by-products", CORE + "ClipboardEntry.swift",
     "public var showsOmittedWarning: Bool { lostContentCount > 0 && !containsOnlyFileReferences }", "public var showsOmittedWarning: Bool { omittedTypeCount > 0 && !containsOnlyFileReferences }"),
    ("payload-equality-counts", CORE + "ClipboardEntry.swift",
     "lhs.items == rhs.items }", "lhs.items == rhs.items && lhs.omittedTypeCount == rhs.omittedTypeCount }"),
    ("payload-legacy-decode", CORE + "ClipboardEntry.swift",
     "lostContentCount = try values.decodeIfPresent(Int.self, forKey: .lostContentCount) ?? 0",
     "lostContentCount = try values.decode(Int.self, forKey: .lostContentCount)"),
    ("lost-content-types", CORE + "ClipboardEntry.swift", '"public.jpeg", "public.heic",', '"public.heic",'),
    ("capture-counts-lost-content", SYS + "MacPasteboard.swift",
     "if ClipboardPayload.lostContentTypes.contains(type.rawValue) { lost += 1 }", ""),
    ("file-capture-counts-extras", SYS + "MacPasteboard.swift",
     "return .payload(ClipboardPayload(items: items, omittedTypeCount: 0))",
     "return .payload(ClipboardPayload(items: items, omittedTypeCount: source.reduce(0) { $0 + $1.types.count }))"),
    # File access: macOS only lets the destination read pasted files when the writer can read them
    ("access-probe-never-denies", SYS + "FileReadAccess.swift", "return errno == EPERM || errno == EACCES", "return false"),
    ("access-missing-file-is-denied", SYS + "FileReadAccess.swift", "return errno == EPERM || errno == EACCES", "return true"),
    ("access-only-eperm", SYS + "FileReadAccess.swift", "return errno == EPERM || errno == EACCES", "return errno == EPERM"),
    ("access-prepare-skipped", SYS + "MacPasteboard.swift", "return denied ? .fileAccessDenied : .ready", "return .ready"),
    ("access-prepare-any-file", SYS + "MacPasteboard.swift", "paths.contains { FileReadAccess.isDenied(path: $0) }", "paths.allSatisfy { FileReadAccess.isDenied(path: $0) }"),
    ("session-denied-still-restores", CORE + "ClipboardSession.swift",
     "guard preparation == .ready else { isPasting = false; notice = .fileAccessDenied; onChange?(); return }", ""),
    ("session-denied-leaves-busy", CORE + "ClipboardSession.swift",
     "guard preparation == .ready else { isPasting = false; notice = .fileAccessDenied; onChange?(); return }",
     "guard preparation == .ready else { notice = .fileAccessDenied; onChange?(); return }"),
    ("session-stale-select-after-prepare", CORE + "ClipboardSession.swift",
     "let preparation = await clipboard.prepareRestore(entry.payload)\n        guard operation == token else { return }", "let preparation = await clipboard.prepareRestore(entry.payload)"),
    # Settings, Launch at Login, list selection, thumbnails
    ("prefs-entries-snapped", CORE + "Preferences.swift",
     "self.maxEntries = Self.entryChoices.contains(maxEntries) ? maxEntries : Self.defaultEntries", "self.maxEntries = maxEntries"),
    ("prefs-size-snapped", CORE + "Preferences.swift",
     "self.maxTotalMiB = Self.totalMiBChoices.contains(maxTotalMiB) ? maxTotalMiB : Self.defaultTotalMiB", "self.maxTotalMiB = maxTotalMiB"),
    ("login-notfound-never-registers", CORE + "LaunchAtLogin.swift",
     "case .disabled, .unavailable:\n            do { try service.register()", "case .unavailable:\n            return .unavailable\n        case .disabled:\n            do { try service.register()"),
    ("login-notfound-looks-on", CORE + "LaunchAtLogin.swift", "case .unavailable: return .off", "case .unavailable: return .on"),
    ("login-unconfirmed-registration", CORE + "LaunchAtLogin.swift", "if service.status == .unavailable { return .unavailable }", ""),
    ("login-approval-opens-settings", CORE + "LaunchAtLogin.swift",
     "if service.status == .requiresApproval { service.openSystemSettings(); return .needsApproval }", ""),
    ("login-failure-reported", CORE + "LaunchAtLogin.swift",
     "do { try service.register() } catch { return .failed(error.localizedDescription) }", "try? service.register()"),
    ("selection-clamped", CORE + "ListSelection.swift", "ids[min(max(index + delta, 0), ids.count - 1)]", "ids[(index + delta + ids.count) % ids.count]"),
    ("selection-starts-at-first", CORE + "ListSelection.swift", "else { return ids[0] }", "else { return ids[ids.count - 1] }"),
    ("thumbnail-pixel-cap", SYS + "Thumbnailer.swift", "width * height <= maxSourcePixels else { return nil }", "true else { return nil }"),
    ("panel-hotkey-ignores-space", CORE + "PanelToggleRules.swift", "isVisible && isOnActiveSpace && isKey ? .hide : .show", "isVisible && isKey ? .hide : .show"),
    ("panel-hotkey-hides-unfocused", CORE + "PanelToggleRules.swift", "isVisible && isOnActiveSpace && isKey ? .hide : .show", "isVisible && isOnActiveSpace ? .hide : .show"),
    ("panel-status-ignores-space", CORE + "PanelToggleRules.swift", "isVisible && isOnActiveSpace ? .hide : .show\n    }\n}", "isVisible ? .hide : .show\n    }\n}"),
]


# Mutations no test can observe from outside. Each needs a reason; a plausible-sounding one is not enough,
# so prefer a test and keep this list short.
EQUIVALENT = {
    "session-select-during-clear": "redundant: clearAll empties `entries` before its first await and poll() is blocked while "
                                   "clearing or loading, so there is never an entry to find in those states",
    "session-delete-guard": "redundant for the same reason as session-select-during-clear",
    "store-atomic-write": "atomic replacement only differs from a plain write when the process dies mid-write; "
                          "that needs fault injection the tests do not have",
    "capture-file-count": "measured on macOS 27: readObjects returns one URL per item even for garbage or non-file data, "
                          "and the per-URL filePathURL check right after it already refuses those, so the count never differs",
    "capture-unstable": "needs another process changing the pasteboard between two reads inside one capture; "
                        "NSPasteboard offers no hook to inject that",
}


def run_tests(attempts=2):
    # A run that ends without a test report (a build error, or the toolchain's TestingMacros quirk
    # outlasting Scripts/test.sh's retries) is tried once more before it counts as BUILD-FAILED.
    for _ in range(attempts):
        result = subprocess.run([os.path.join(ROOT, "Scripts/test.sh")], cwd=ROOT, capture_output=True, text=True)
        output = result.stdout + result.stderr
        if "Test run" in output:
            return "KILLED" if result.returncode != 0 else "SURVIVED"
    return "BUILD-FAILED"


def sources_are_clean():
    changed = subprocess.run(["git", "status", "--porcelain", "--", "Sources"], cwd=ROOT, capture_output=True, text=True)
    return changed.returncode == 0 and not changed.stdout.strip()


def main():
    args = sys.argv[1:]
    check_only = "--check" in args
    filters = [a for a in args if not a.startswith("--")]
    if not check_only and not sources_are_clean():
        sys.exit("Sources/ has uncommitted changes (or this is not a git checkout). Commit or stash them first.")
    # A killed run must still restore the file it was holding.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))

    names = [m[0] for m in MUTATIONS]
    duplicated = {n for n in names if names.count(n) > 1}
    if duplicated:
        sys.exit("Duplicate mutation names: " + ", ".join(sorted(duplicated)))

    not_killed = []
    ran = 0
    for name, path, find, replace in MUTATIONS:
        if filters and not any(f in name for f in filters):
            continue
        full = os.path.join(ROOT, path)
        with open(full, encoding="utf-8") as f:
            original = f.read()
        if find not in original:
            print(f"MISSING   {name}: text not found in {path}")
            not_killed.append(name)
            continue
        if check_only:
            print(f"ok        {name}")
            continue
        try:
            with open(full, "w", encoding="utf-8") as f:
                f.write(original.replace(find, replace))
            status = run_tests()
        finally:
            with open(full, "w", encoding="utf-8") as f:
                f.write(original)
        ran += 1
        if status == "SURVIVED" and name in EQUIVALENT:
            status = "EQUIVALENT"
        print(f"{status:12} {name}", flush=True)
        if status not in ("KILLED", "EQUIVALENT"):
            not_killed.append(name)
    if not check_only and not sources_are_clean():
        print("WARNING: Sources/ differs from the committed tree after the run. Inspect it with git diff.")
        not_killed.append("(sources not restored)")
    print(f"\n{len(not_killed)} not killed" + (": " + ", ".join(not_killed) if not_killed else ""))
    sys.exit(1 if not_killed else 0)


if __name__ == "__main__":
    main()
