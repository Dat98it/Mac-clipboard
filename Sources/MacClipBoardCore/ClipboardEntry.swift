import Foundation

public struct ClipboardRepresentation: Codable, Equatable, Sendable {
    public let type: String
    public let data: Data
    public init(type: String, data: Data) { self.type = type; self.data = data }
}

public struct ClipboardPayload: Codable, Equatable, Sendable {
    /// Preserve pasteboard item boundaries (including multiple Finder file URLs).
    public let items: [[ClipboardRepresentation]]
    /// Every type on the pasteboard that was not saved. Informational only: copies from browsers and editors always
    /// carry by-products (a UTF-16 copy of the text, `org.chromium.*`, `dyn.*`...), so this alone is no reason to warn.
    public let omittedTypeCount: Int
    /// How many of the dropped types were real content (a JPEG, a PDF...). Only this drives the warning.
    public let lostContentCount: Int
    public init(items: [[ClipboardRepresentation]], omittedTypeCount: Int = 0, lostContentCount: Int = 0) {
        self.items = items
        self.omittedTypeCount = omittedTypeCount
        self.lostContentCount = lostContentCount
    }
    private enum CodingKeys: String, CodingKey { case items, omittedTypeCount, lostContentCount }
    /// History saved before `lostContentCount` existed has no such key: those entries carry no warning, because
    /// their old `omittedTypeCount` was inflated by by-products and cannot say whether anything real was lost.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode([[ClipboardRepresentation]].self, forKey: .items)
        omittedTypeCount = try values.decode(Int.self, forKey: .omittedTypeCount)
        lostContentCount = try values.decodeIfPresent(Int.self, forKey: .lostContentCount) ?? 0
    }
    /// Two payloads are the same copy when their content is the same; the bookkeeping counts do not matter,
    /// otherwise copying again text that an older version saved would create a duplicate.
    public static func == (lhs: ClipboardPayload, rhs: ClipboardPayload) -> Bool { lhs.items == rhs.items }

    /// Dropped types that are genuine content rather than by-products. Anything else on the pasteboard is noise.
    public static let lostContentTypes: Set<String> = [
        "public.jpeg", "public.heic", "public.heif", "com.compuserve.gif", "public.webp", "org.webmproject.webp",
        "com.adobe.pdf", "public.svg-image", "public.rtfd", "com.apple.flat-rtfd",
    ]
    /// "Some formats were not saved" is only meaningful when real content was dropped from a text or image copy. A file
    /// reference is restored natively from its URL (Finder's extra types are not content), so it never shows it.
    public var showsOmittedWarning: Bool { lostContentCount > 0 && !containsOnlyFileReferences }
    public var byteCount: Int { items.flatMap { $0 }.reduce(0) { $0 + $1.data.count } }
    public var types: Set<String> { Set(items.flatMap { $0 }.map { $0.type }) }
    /// File identity is established by the file-URL type, never by a text path or filename.
    public var containsOnlyFileReferences: Bool {
        !items.isEmpty && items.allSatisfy { $0.contains { $0.type == "public.file-url" } }
    }
    public var fileURLs: [URL]? {
        guard containsOnlyFileReferences else { return nil }
        var result: [URL] = []
        for item in items {
            guard let value = item.first(where: { $0.type == "public.file-url" }),
                  let text = String(data: value.data, encoding: .utf8),
                  let url = URL(string: text), url.isFileURL else { return nil }
            result.append(url)
        }
        return result
    }
    /// Original PNG (preferred) or TIFF bytes, used only to draw a thumbnail. Never re-encoded or stored again.
    public var imageData: Data? {
        let representations = items.flatMap { $0 }
        for type in ["public.png", "public.tiff"] {
            if let data = representations.first(where: { $0.type == type })?.data { return data }
        }
        return nil
    }
    public var preview: String {
        if let urls = fileURLs, urls.allSatisfy({ !$0.path.hasPrefix("/.file/id=") }) {
            return String(urls.map { $0.lastPathComponent }.joined(separator: "\n").prefix(320))
        }
        let representations = items.flatMap { $0 }
        for type in ["public.utf8-plain-text", "public.file-url", "public.url"] {
            if let data = representations.first(where: { $0.type == type })?.data,
               let text = String(data: data, encoding: .utf8) {
                // Limit preview only; the original bytes remain intact.
                return String(text.prefix(320))
            }
        }
        return ""
    }
    public static let supportedTypes: Set<String> = [
        "public.utf8-plain-text", "public.rtf", "public.html",
        "public.png", "public.tiff", "public.url", "public.file-url",
    ]
    public func isValid(limits: HistoryLimits) -> Bool {
        !items.isEmpty && items.count <= 128 && omittedTypeCount >= 0 &&
        items.allSatisfy { item in
            !item.isEmpty && item.count <= Self.supportedTypes.count &&
            Set(item.map { $0.type }).count == item.count &&
            item.allSatisfy { Self.supportedTypes.contains($0.type) }
        } && byteCount > 0 && byteCount <= limits.maxEntryBytes
    }
}

public struct ClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let payload: ClipboardPayload
    /// Pinned entries are never evicted by newer copies; only unpinning, deleting or Clear All removes them.
    public let isPinned: Bool
    public init(id: UUID = UUID(), capturedAt: Date = Date(), payload: ClipboardPayload, isPinned: Bool = false) {
        self.id = id; self.capturedAt = capturedAt; self.payload = payload; self.isPinned = isPinned
    }
    public func pinned(_ value: Bool) -> ClipboardEntry {
        ClipboardEntry(id: id, capturedAt: capturedAt, payload: payload, isPinned: value)
    }
    private enum CodingKeys: String, CodingKey { case id, capturedAt, payload, isPinned }
    /// History written before pinning existed has no `isPinned` key; it must still load.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        payload = try values.decode(ClipboardPayload.self, forKey: .payload)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

public struct HistoryLimits: Sendable {
    public var maxEntries: Int
    public var maxTotalBytes: Int
    public var maxEntryBytes: Int
    public var maxPinnedEntries: Int
    /// Half the budget at most, so a new copy can always be stored next to the pinned items.
    public var maxPinnedBytes: Int { maxTotalBytes / 2 }
    public init(maxEntries: Int = 100, maxTotalBytes: Int = 32 * 1024 * 1024, maxEntryBytes: Int = 8 * 1024 * 1024,
                maxPinnedEntries: Int = 20) {
        self.maxEntries = maxEntries; self.maxTotalBytes = maxTotalBytes; self.maxEntryBytes = maxEntryBytes
        self.maxPinnedEntries = maxPinnedEntries
    }
    /// Pinned entries are kept first (within their own caps); the rest fill what remains, newest first.
    public func bounded(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        var ids = Set<UUID>()
        let valid = entries.filter { $0.payload.isValid(limits: self) && ids.insert($0.id).inserted }
        var keep = Set<UUID>()
        var used = 0, pinnedUsed = 0
        for entry in valid where entry.isPinned {
            let size = entry.payload.byteCount
            guard keep.count < min(maxPinnedEntries, maxEntries), pinnedUsed + size <= maxPinnedBytes else { continue }
            keep.insert(entry.id); pinnedUsed += size
        }
        used = pinnedUsed
        for entry in valid.filter({ !$0.isPinned }).prefix(max(0, maxEntries - keep.count)) {
            guard used + entry.payload.byteCount <= maxTotalBytes else { continue }
            keep.insert(entry.id); used += entry.payload.byteCount
        }
        return valid.filter { keep.contains($0.id) }
    }
}
