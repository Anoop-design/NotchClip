import Foundation

/// Content filter applied to the history list.
///
/// Pure and AppKit-free so the filter predicate stays unit-testable. The unified
/// panel exposes these as ⌘1–⌘6 rather than as a sidebar, so the ordering here is
/// also the shortcut ordering.
public enum ClipScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case pinned
    case text
    case links
    case images
    case files

    public var id: Self { self }

    public var title: String {
        switch self {
        case .all: return "All"
        case .pinned: return "Pinned"
        case .text: return "Text"
        case .links: return "Links"
        case .images: return "Images"
        case .files: return "Files"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .pinned: return "pin"
        case .text: return "text.alignleft"
        case .links: return "link"
        case .images: return "photo"
        case .files: return "folder"
        }
    }

    /// 1-based position, used for the ⌘1–⌘6 shortcuts.
    public var shortcutNumber: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }

    public static func scope(forShortcutNumber number: Int) -> ClipScope? {
        let index = number - 1
        guard index >= 0, index < allCases.count else { return nil }
        return allCases[index]
    }

    public func includes(_ entry: ClipboardEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .pinned:
            return entry.isPinned
        case .text:
            return [.plainText, .rtf, .html].contains(entry.primaryKind)
        case .links:
            return entry.primaryKind == .url
        case .images:
            return entry.primaryKind == .image
        case .files:
            return entry.primaryKind == .fileList
        }
    }

    /// Copy shown when a scope has no matching entries.
    public var emptyDescription: String {
        switch self {
        case .all: return "Copy something and it will appear here."
        case .pinned: return "Pin a clip to keep it easy to reach."
        case .text: return "Copied text, rich text, and HTML will appear here."
        case .links: return "Copied web links will appear here."
        case .images: return "Copied images will appear here."
        case .files: return "Files copied from Finder will appear here."
        }
    }
}

/// One titled run of entries in the history list.
public struct ClipSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let entries: [ClipboardEntry]

    public init(id: String, title: String, entries: [ClipboardEntry]) {
        self.id = id
        self.title = title
        self.entries = entries
    }
}

/// Filtered, sorted, and sectioned snapshot of history for the current inputs.
///
/// Built once per (history revision, query, scope) change rather than on every
/// selection or hover, so an indefinitely large archive is not re-projected
/// while the user is only moving the selection.
public struct ClipProjection: Equatable, Sendable {
    public let visibleEntries: [ClipboardEntry]
    public let visibleIDs: Set<UUID>
    public let sections: [ClipSection]

    public init(visibleEntries: [ClipboardEntry], visibleIDs: Set<UUID>, sections: [ClipSection]) {
        self.visibleEntries = visibleEntries
        self.visibleIDs = visibleIDs
        self.sections = sections
    }

    public static let empty = ClipProjection(visibleEntries: [], visibleIDs: [], sections: [])

    public static func make(
        entries: [ClipboardEntry],
        query: String,
        scope: ClipScope,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ClipProjection {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = trimmed.lowercased()
        let localizedNeedle = trimmed.localizedLowercase

        let matching = entries.filter { entry in
            guard scope.includes(entry) else { return false }
            guard !trimmed.isEmpty else { return true }
            return entry.searchText.contains(needle)
                || entry.previewText.lowercased().contains(needle)
                || entry.source.applicationName?.localizedLowercase.contains(localizedNeedle) == true
                || entry.source.bundleIdentifier?.localizedLowercase.contains(localizedNeedle) == true
        }
        let visible = ClipboardSorting.pinnedFirst(matching)

        var pinned: [ClipboardEntry] = []
        var today: [ClipboardEntry] = []
        var yesterday: [ClipboardEntry] = []
        var earlier: [ClipboardEntry] = []
        var ids = Set<UUID>()
        ids.reserveCapacity(visible.count)

        for entry in visible {
            ids.insert(entry.id)
            if entry.isPinned {
                pinned.append(entry)
            } else if calendar.isDateInToday(entry.updatedAt) {
                today.append(entry)
            } else if calendar.isDateInYesterday(entry.updatedAt) {
                yesterday.append(entry)
            } else {
                earlier.append(entry)
            }
        }

        var sections: [ClipSection] = []
        sections.reserveCapacity(4)
        if !pinned.isEmpty { sections.append(ClipSection(id: "pinned", title: "Pinned", entries: pinned)) }
        if !today.isEmpty { sections.append(ClipSection(id: "today", title: "Today", entries: today)) }
        if !yesterday.isEmpty { sections.append(ClipSection(id: "yesterday", title: "Yesterday", entries: yesterday)) }
        if !earlier.isEmpty { sections.append(ClipSection(id: "earlier", title: "Earlier", entries: earlier)) }

        return ClipProjection(visibleEntries: visible, visibleIDs: ids, sections: sections)
    }

    public func contains(id: UUID) -> Bool { visibleIDs.contains(id) }

    public func entry(id: UUID) -> ClipboardEntry? {
        visibleEntries.first { $0.id == id }
    }

    /// Move selection by `delta` through the flattened display order, clamping at both ends.
    public func moveSelection(from currentID: UUID?, delta: Int) -> UUID? {
        guard !visibleEntries.isEmpty else { return nil }
        guard let currentID,
              let index = visibleEntries.firstIndex(where: { $0.id == currentID }) else {
            return visibleEntries.first?.id
        }
        let next = max(0, min(visibleEntries.count - 1, index + delta))
        return visibleEntries[next].id
    }
}
