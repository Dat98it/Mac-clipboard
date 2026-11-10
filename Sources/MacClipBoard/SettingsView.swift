import SwiftUI
import MacClipBoardCore

/// A sheet over the history panel. History limits are applied with the Apply button (reducing them drops
/// items, so the cost is shown first); Launch at Login is a system setting and takes effect immediately.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Settings")).font(.title2.bold())

            VStack(alignment: .leading, spacing: 10) {
                Text(L("History size")).font(.headline)
                Picker(L("Items to keep"), selection: Binding(get: { model.draft.maxEntries }, set: { model.draft.setMaxEntries($0) })) {
                    ForEach(Preferences.entryChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("settings.entries")
                Picker(L("Total size"), selection: Binding(get: { model.draft.maxTotalMiB }, set: { model.draft.setMaxTotalMiB($0) })) {
                    ForEach(Preferences.totalMiBChoices, id: \.self) { Text("\($0) MiB").tag($0) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("settings.size")
                Text(String(format: L("Pinned items are never removed by newer copies: up to %d items and at most %d MiB."),
                            model.draft.limits.maxPinnedEntries, model.draft.limits.maxPinnedBytes / (1024 * 1024)))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.draftRemovalCount > 0 {
                    Label(String(format: L("Applying removes the %d oldest unpinned items. This cannot be undone."), model.draftRemovalCount),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.removalWarning")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(L("Shortcut")).font(.headline)
                Picker(L("Open history"), selection: Binding(get: { model.draft.hotkey }, set: { model.draft.setHotkey($0) })) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { Text($0 == .off ? L("Off") : $0.symbols).tag($0) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("settings.hotkey")
                Text(model.hotkeyExplanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.hotkeyStatus")
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Startup")).font(.headline)
                Toggle(L("Launch at Login"), isOn: Binding(get: { model.loginState == .on || model.loginState == .needsApproval },
                                                           set: { _ in model.toggleLaunchAtLogin() }))
                .disabled(model.busy || model.loginState == .unavailable)
                .accessibilityIdentifier("settings.launchAtLogin")
                Text(model.loginExplanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.loginError.isEmpty {
                    Text(String(format: L("Launch at Login could not be changed: %@"), model.loginError))
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !model.settingsError.isEmpty {
                Text(model.settingsError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { model.showingSettings = false }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("settings.cancel")
                Button(L("Apply")) { model.applySettings() }
                    .keyboardShortcut(.defaultAction).disabled(model.busy || model.draft == model.preferences)
                    .accessibilityIdentifier("settings.apply")
            }
        }
        .padding(22).frame(width: 440)
    }
}
