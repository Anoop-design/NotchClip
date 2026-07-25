import Foundation

/// Human-readable kind labels (never raw camelCase enum).
public enum EntryKindLabel {
    public static func displayName(for kind: ClipboardContentKind) -> String {
        switch kind {
        case .plainText: return "Text"
        case .rtf: return "Rich Text"
        case .html: return "HTML"
        case .url: return "Link"
        case .image: return "Image"
        case .fileList: return "Files"
        case .mixed: return "Mixed"
        case .other: return "Item"
        }
    }
}

/// Pure formatting helpers for history rows (unit-testable, no I/O).
public enum EntryPresentation {
    public static func kindBadge(for kind: ClipboardContentKind) -> String {
        EntryKindLabel.displayName(for: kind)
    }

    /// Normalized host for URL strings; nil if not a usable URL.
    public static func urlHost(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            return host
        }
        if let url = URL(string: "https://\(trimmed)"), let host = url.host, !host.isEmpty {
            return host
        }
        return nil
    }

    public static func urlTitleFallback(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = urlHost(from: trimmed) {
            return host
        }
        return String(trimmed.prefix(80))
    }

    public static func fileDisplayName(paths: [String]) -> String {
        guard let first = paths.first else { return "Files" }
        let name = (first as NSString).lastPathComponent
        if paths.count == 1 { return name }
        return "\(name) +\(paths.count - 1)"
    }

    public static func fileCountLabel(count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    public static func sourceLabel(from source: SourceMetadata) -> String? {
        if let name = source.applicationName, !name.isEmpty { return name }
        if let bid = source.bundleIdentifier, !bid.isEmpty {
            return bid.split(separator: ".").last.map(String.init) ?? bid
        }
        return nil
    }

    public static func relativeTimestamp(
        for date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    public static func primaryLine(for entry: ClipboardEntry) -> String {
        switch entry.primaryKind {
        case .url:
            return urlTitleFallback(from: entry.previewText)
        case .fileList:
            let paths = entry.originalFilePaths
            return fileDisplayName(paths: paths.isEmpty ? [entry.previewText] : paths)
        default:
            let t = entry.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? EntryKindLabel.displayName(for: entry.primaryKind) : t
        }
    }

    public static func secondaryLine(for entry: ClipboardEntry) -> String? {
        var parts: [String] = []
        if entry.primaryKind == .url, let host = urlHost(from: entry.previewText) {
            parts.append(host)
        }
        if entry.primaryKind == .fileList {
            let count = max(entry.originalFilePaths.count, entry.previewText.isEmpty ? 0 : 1)
            if count > 0 { parts.append(fileCountLabel(count: count)) }
            if entry.hasMissingFiles() { parts.append("Missing") }
        }
        if let source = sourceLabel(from: entry.source) {
            parts.append(source)
        }
        parts.append(relativeTimestamp(for: entry.updatedAt))
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func byteCountString(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// Lightweight presentation model for a row (no payload bytes).
public struct EntryRowModel: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var fingerprint: String
    public var primaryText: String
    public var secondaryText: String?
    public var kindLabel: String
    public var isPinned: Bool
    public var hasMissingFiles: Bool
    public var kind: ClipboardContentKind
    public var sourceBundleID: String?
    public var originalPaths: [String]

    public init(entry: ClipboardEntry, linkTitle: String? = nil) {
        id = entry.id
        fingerprint = entry.fingerprint
        if let linkTitle, !linkTitle.isEmpty, entry.primaryKind == .url {
            primaryText = linkTitle
        } else {
            primaryText = EntryPresentation.primaryLine(for: entry)
        }
        secondaryText = EntryPresentation.secondaryLine(for: entry)
        kindLabel = EntryPresentation.kindBadge(for: entry.primaryKind)
        isPinned = entry.isPinned
        hasMissingFiles = entry.hasMissingFiles()
        kind = entry.primaryKind
        sourceBundleID = entry.source.bundleIdentifier
        originalPaths = entry.originalFilePaths
    }
}
