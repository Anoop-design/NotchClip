import Foundation

/// Pure projection used by the notch's glanceable quick shelf.
///
/// The shelf deliberately exposes a bounded, stable working set rather than the
/// entire archive. Pinned clips receive priority, while recent clips retain most
/// of the eight-item shelf. Any unused space is filled from the other group.
public enum QuickShelfPolicy {
    public static let itemLimit = 8
    public static let preferredPinnedLimit = 3

    public static func entries(
        from entries: [ClipboardEntry],
        limit: Int = itemLimit,
        preferredPinnedLimit: Int = preferredPinnedLimit
    ) -> [ClipboardEntry] {
        guard limit > 0 else { return [] }

        let sorted = ClipboardSorting.pinnedFirst(entries)
        let pinned = sorted.filter(\.isPinned)
        let recent = sorted.filter { !$0.isPinned }

        guard !pinned.isEmpty else { return Array(recent.prefix(limit)) }
        guard !recent.isEmpty else { return Array(pinned.prefix(limit)) }

        let pinnedCap = min(
            pinned.count,
            max(1, min(preferredPinnedLimit, limit))
        )
        var chosenPinned = Array(pinned.prefix(pinnedCap))
        let chosenRecent = Array(recent.prefix(max(0, limit - chosenPinned.count)))

        let unfilled = limit - chosenPinned.count - chosenRecent.count
        if unfilled > 0 {
            chosenPinned.append(contentsOf: pinned.dropFirst(chosenPinned.count).prefix(unfilled))
        }

        return chosenPinned + chosenRecent
    }

    /// Move within the bounded shelf; selection never leaks into hidden archive rows.
    public static func moveSelection(
        currentID: UUID?,
        delta: Int,
        entries: [ClipboardEntry]
    ) -> UUID? {
        guard !entries.isEmpty else { return nil }
        guard let currentID,
              let index = entries.firstIndex(where: { $0.id == currentID }) else {
            return entries.first?.id
        }
        let next = max(0, min(entries.count - 1, index + delta))
        return entries[next].id
    }
}
