import Foundation

/// Pure history list projection for the panel (pinned then recent).
public struct HistorySections: Equatable, Sendable {
    public var pinned: [ClipboardEntry]
    public var recent: [ClipboardEntry]

    public init(pinned: [ClipboardEntry] = [], recent: [ClipboardEntry] = []) {
        self.pinned = pinned
        self.recent = recent
    }

    public var allInDisplayOrder: [ClipboardEntry] {
        pinned + recent
    }

    public var isEmpty: Bool { pinned.isEmpty && recent.isEmpty }
}

public enum HistoryQuery {
    /// Filter and section entries. Query is case-insensitive substring over search/preview text.
    public static func sections(from entries: [ClipboardEntry], query: String) -> HistorySections {
        let filtered = ClipboardSorting.pinnedFirst(
            entries.filter { ClipboardSorting.matches(entry: $0, query: query) }
        )
        let pinned = filtered.filter(\.isPinned)
        let recent = filtered.filter { !$0.isPinned }
        return HistorySections(pinned: pinned, recent: recent)
    }

    /// Move selection by delta within display order; clamps to bounds.
    public static func moveSelection(
        currentID: UUID?,
        delta: Int,
        sections: HistorySections
    ) -> UUID? {
        let items = sections.allInDisplayOrder
        guard !items.isEmpty else { return nil }
        guard let currentID,
              let idx = items.firstIndex(where: { $0.id == currentID }) else {
            return items.first?.id
        }
        let next = max(0, min(items.count - 1, idx + delta))
        return items[next].id
    }

    public static func indexOf(id: UUID?, in sections: HistorySections) -> Int? {
        guard let id else { return nil }
        return sections.allInDisplayOrder.firstIndex(where: { $0.id == id })
    }
}
