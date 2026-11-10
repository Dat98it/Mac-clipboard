import SwiftUI
import MacClipBoardCore

// Follows AppClean's ObservableObject + explicit Binding pattern (no @State macro/extra dependency).
struct HistoryView: View {
    @ObservedObject var model: AppModel
    let isolated: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isolated {
                Label(L("Test mode · isolated clipboard and storage"), systemImage: "testtube.2")
                    .font(.caption).padding(8).frame(maxWidth: .infinity).background(Color.orange.opacity(0.1))
            }
            if !model.hasPermission { permissionCard }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search text and links"), text: Binding(get: { model.filter }, set: { model.filter = $0 }))
                    .textFieldStyle(.plain).accessibilityIdentifier("history.search")
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 8)

            if model.busy && model.entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleEntries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.visibleEntries) { entry in
                                EntryRow(entry: entry, thumbnail: model.thumbnail(for: entry), selected: model.selectedID == entry.id,
                                         hovered: model.hoveredID == entry.id, onHover: { model.setHover(entry.id, inside: $0) },
                                         selectDisabled: model.busy || model.pasting, actionsDisabled: model.busy,
                                         onSelect: { model.select(entry) },
                                         onTogglePin: { model.togglePin(entry) },
                                         onDelete: { model.delete(entry) })
                                    .id(entry.id)
                            }
                        }.padding(.horizontal, 18).padding(.vertical, 8)
                    }
                    .onChange(of: model.selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: Binding(get: { model.showingSettings }, set: { model.showingSettings = $0 })) {
            SettingsView(model: model)
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard.fill").font(.system(size: 27)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Mac ClipBoard").font(.title2.bold())
                Text(L("Your clipboard, kept on this Mac.")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { model.requestUninstall?() } label: { Label(L("Uninstall…"), systemImage: "app.badge.minus") }
                .disabled(model.busy || !model.canUninstall)
                .accessibilityIdentifier("app.uninstall")
                .help(model.uninstallExplanation)
            Button { model.openSettings() } label: { Image(systemName: "gearshape") }
                .disabled(model.busy)
                .accessibilityIdentifier("app.settings")
                .help(L("Settings…"))
            Button(action: model.clearAll) { Label(L("Clear All"), systemImage: "trash") }
                .disabled(model.busy)
                .accessibilityIdentifier("history.clearAll")
                .help(L("Delete all saved history and clear the system clipboard"))
        }.padding(18)
    }
    var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Allow automatic paste"), systemImage: "hand.raised").font(.callout.bold())
            Text(L("Accessibility lets Mac ClipBoard return to your editor and send Cmd+V. Without it, items are copied and you can paste manually."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L("System Settings → Privacy & Security → Accessibility → + → Mac ClipBoard. Enable it, then return to your editor before opening history."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Open Settings")) { model.router.openAccessibilitySettings() }
                Button(L("Check Again")) { model.refresh() }
            }.controlSize(.small)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.07)))
        .padding(.horizontal, 18).padding(.top, 12)
    }
    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.filter.isEmpty ? "clipboard" : "magnifyingglass")
                .font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
            Text(L(model.filter.isEmpty ? "Your history starts here" : "No matching items")).font(.headline)
            Text(L(model.filter.isEmpty
                   ? "Copy text, an image or a file while Mac ClipBoard is running. New copies appear here, newest first."
                   : "Try a different search."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 330).fixedSize(horizontal: false, vertical: true)
            if model.filter.isEmpty {
                Text(L("Items copied before monitoring started are not recovered."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("history.status")
            if let destination = model.destinationName {
                Text(String(format: L("Paste destination: %@"), destination)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Circle().fill(model.paused ? Color.orange : Color.green).frame(width: 6, height: 6)
                Text(L(model.paused ? "Paused" : "Monitoring")).font(.caption)
                Text("· \(model.entries.count)/\(model.preferences.maxEntries) · \(bytes(model.totalBytes))/\(model.preferences.maxTotalMiB) MiB").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button(L(model.paused ? "Resume" : "Pause"), action: model.togglePaused)
                    .buttonStyle(.link).font(.caption).disabled(model.busy)
            }
            Text(L("Stored locally, unencrypted. File entries are references; custom formats and file promises are not stored."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
}

/// The card is one button (paste) plus two small ones (pin, remove), so the actions are not nested inside the paste button.
struct EntryRow: View {
    let entry: ClipboardEntry
    let thumbnail: NSImage?
    let selected: Bool
    let hovered: Bool
    let onHover: (Bool) -> Void
    let selectDisabled: Bool
    let actionsDisabled: Bool
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: onSelect) { EntryView(entry: entry, thumbnail: thumbnail) }
                .buttonStyle(.plain)
                .disabled(selectDisabled)
                .accessibilityIdentifier("history.item.\(entry.id.uuidString)")
                .help(L("Restore this item and paste into the previous app"))
            VStack(spacing: 4) {
                Button(action: onTogglePin) {
                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(entry.isPinned ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .accessibilityIdentifier("history.pin.\(entry.id.uuidString)")
                .help(L(entry.isPinned ? "Unpin this item" : "Pin this item so newer copies never remove it"))
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .foregroundStyle(Color.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .accessibilityIdentifier("history.delete.\(entry.id.uuidString)")
                .help(L("Remove this item from history"))
            }
            .buttonStyle(.borderless).disabled(actionsDisabled)
            .padding(.top, 10).padding(.trailing, 10)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        // Keyboard selection is the strongest cue; hover is lighter, so the two stay distinguishable.
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(selected ? 0.12 : (hovered ? 0.07 : 0))))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.accentColor
                          : (hovered ? Color.accentColor.opacity(0.55)
                             : (entry.isPinned ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.07))),
                          lineWidth: selected ? 2 : (hovered ? 1.5 : 1)))
        .onHover { onHover($0) }
    }
}

struct EntryView: View {
    let entry: ClipboardEntry
    let thumbnail: NSImage?
    var isFile: Bool { entry.payload.types.contains("public.file-url") }
    var isImage: Bool { !entry.payload.types.isDisjoint(with: ["public.png", "public.tiff"]) }
    var title: String {
        if !entry.payload.preview.isEmpty { return entry.payload.preview }
        if isImage { return L("Image") }
        return L("Formatted text")
    }
    var formats: String {
        if entry.payload.containsOnlyFileReferences {
            let extensions = Set((entry.payload.fileURLs ?? []).map { $0.pathExtension.uppercased() }.filter { !$0.isEmpty }).sorted()
            return ([L("File")] + extensions).joined(separator: " · ")
        }
        let names = [
            ("public.utf8-plain-text", "Text"), ("public.rtf", "RTF"), ("public.html", "HTML"),
            ("public.png", "PNG"), ("public.tiff", "TIFF"), ("public.url", "URL"), ("public.file-url", "File reference"),
        ]
        return names.filter { entry.payload.types.contains($0.0) }.map { L($0.1) }.joined(separator: " · ")
    }
    var imagePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.title3).foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        .accessibilityHidden(true)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isImage {
                imagePreview
            } else {
                Image(systemName: isFile ? "doc" : "text.alignleft")
                    .font(.title3).foregroundStyle(Color.accentColor).frame(width: 24).padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.body).lineLimit(3).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(formats).lineLimit(1)
                    if entry.payload.items.count > 1 { Text("×\(entry.payload.items.count)") }
                    Spacer()
                    Text(bytes(entry.payload.byteCount))
                    Text(entry.capturedAt, style: .time)
                }.font(.caption).foregroundStyle(.secondary)
                if entry.payload.showsOmittedWarning {
                    Label(L("Custom formats were not saved"), systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 14).padding(.leading, 14).padding(.trailing, 6).frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
