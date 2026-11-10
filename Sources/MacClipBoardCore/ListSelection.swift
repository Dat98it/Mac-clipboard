import Foundation

/// Keyboard selection over the visible list. Pure so it can be tested without any UI.
public enum ListSelection {
    /// Moves one step per unit of `delta`, clamped to the ends (no wrap). With no (or a stale)
    /// selection the first item is chosen, whichever direction was pressed.
    public static func moved(from current: UUID?, in ids: [UUID], by delta: Int) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids[0] }
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }

    /// The item to select once `removed` is gone: the one below it, else the one above, else none.
    public static func neighbour(afterRemoving removed: UUID, in ids: [UUID]) -> UUID? {
        guard let index = ids.firstIndex(of: removed) else { return nil }
        if index + 1 < ids.count { return ids[index + 1] }
        return index > 0 ? ids[index - 1] : nil
    }
}
