import Foundation

/// Pure eviction decisions for the automatic history cap.
public enum RetentionPolicy {
    /// Sentinel limit meaning "keep everything" (the Unlimited choice in Settings).
    public static let unlimited = 0
    public static let defaultLimit = 500

    /// Entries beyond `limit`, oldest first.
    ///
    /// Pinned entries are exempt: they are never evicted and never counted against
    /// the cap. Recency is derived from `updatedAt` here rather than trusted from
    /// the caller, so repositories with unordered storage still evict exactly the
    /// items the panel shows last. Sorting happens only once the cap is exceeded.
    public static func idsToEvict(entries: [ClipboardEntry], limit: Int) -> [UUID] {
        guard limit > unlimited else { return [] }
        var unpinnedCount = 0
        for entry in entries where !entry.isPinned {
            unpinnedCount += 1
        }
        guard unpinnedCount > limit else { return [] }

        let ordered = entries
            .filter { !$0.isPinned }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt < rhs.updatedAt
                }
                // Stable tie-break: same-instant entries must evict deterministically.
                return lhs.id.uuidString < rhs.id.uuidString
            }
        return ordered.prefix(unpinnedCount - limit).map(\.id)
    }
}
