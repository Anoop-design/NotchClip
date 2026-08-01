import Foundation

public enum ClipboardRepositoryError: Error, Equatable, Sendable {
    case notFound
    case persistenceFailed
}

/// Abstraction over clipboard history metadata storage.
public protocol ClipboardRepository: AnyObject, Sendable {
    func allEntries() throws -> [ClipboardEntry]
    func entry(id: UUID) throws -> ClipboardEntry?
    func upsert(_ entry: ClipboardEntry) throws
    func remove(id: UUID) throws
    /// Bulk removal in a single publish (retention eviction).
    func remove(ids: Set<UUID>) throws
    func removeAll() throws
    func sortedEntries() throws -> [ClipboardEntry]
    func search(query: String) throws -> [ClipboardEntry]
}

extension ClipboardRepository {
    public func remove(ids: Set<UUID>) throws {
        for id in ids {
            try remove(id: id)
        }
    }
}

public enum ClipboardSorting {
    public static func pinnedFirst(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public static func matches(entry: ClipboardEntry, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return true }
        return entry.searchText.lowercased().contains(q)
            || entry.previewText.lowercased().contains(q)
    }
}

/// Ephemeral repository for tests and previews.
public final class InMemoryClipboardRepository: ClipboardRepository, @unchecked Sendable {
    private var entries: [UUID: ClipboardEntry] = [:]
    private let lock = NSLock()

    public init(entries: [ClipboardEntry] = []) {
        for entry in entries {
            self.entries[entry.id] = entry
        }
    }

    public func allEntries() throws -> [ClipboardEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.values)
    }

    public func entry(id: UUID) throws -> ClipboardEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]
    }

    public func upsert(_ entry: ClipboardEntry) throws {
        lock.lock(); defer { lock.unlock() }
        entries[entry.id] = entry
    }

    public func remove(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: id)
    }

    public func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    public func sortedEntries() throws -> [ClipboardEntry] {
        ClipboardSorting.pinnedFirst(try allEntries())
    }

    public func search(query: String) throws -> [ClipboardEntry] {
        ClipboardSorting.pinnedFirst(try allEntries().filter {
            ClipboardSorting.matches(entry: $0, query: query)
        })
    }
}

/// JSON metadata store under a configurable directory.
///
/// Dates are encoded as `timeIntervalSinceReferenceDate` doubles so full `Date` precision
/// round-trips. Legacy ISO-8601 strings from earlier development builds are still decoded.
///
/// History replacement uses `Data.write(options: .atomic)`, which writes to a temporary
/// file and renames over the destination — the previous `history.json` is never deleted
/// before the new content is published. A best-effort `history.json.bak` is updated after
/// each successful write for recovery if the primary file becomes unreadable.
public final class PersistentClipboardRepository: ClipboardRepository, @unchecked Sendable {
    public let directory: URL
    private let fileURL: URL
    private let backupURL: URL
    private let queue = DispatchQueue(label: "com.notchclip.repository")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private struct Envelope: Codable {
        var entries: [ClipboardEntry]
    }

    public init(directory: URL) throws {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("history.json")
        self.backupURL = directory.appendingPathComponent("history.json.bak")
        self.encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        self.decoder = JSONDecoder()
        let dateDecoder: @Sendable (Decoder) throws -> Date = { decoder in
            try PersistentClipboardRepository.decodeDate(from: decoder)
        }
        decoder.dateDecodingStrategy = .custom(dateDecoder)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try writeEnvelope(Envelope(entries: []))
        }
    }

    /// Decode numeric (current) or ISO-8601 string (legacy development) date values.
    private static func decodeDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        if let string = try? container.decode(String.self) {
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle()) {
                return date
            }
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected Date as timeIntervalSinceReferenceDate Double or ISO-8601 string"
        )
    }

    public static func temporary() throws -> PersistentClipboardRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchClip-tests-\(UUID().uuidString)", isDirectory: true)
        return try PersistentClipboardRepository(directory: url)
    }

    public func allEntries() throws -> [ClipboardEntry] {
        try queue.sync { try load().entries }
    }

    public func entry(id: UUID) throws -> ClipboardEntry? {
        try allEntries().first { $0.id == id }
    }

    public func upsert(_ entry: ClipboardEntry) throws {
        try queue.sync {
            var envelope = try load()
            if let idx = envelope.entries.firstIndex(where: { $0.id == entry.id }) {
                envelope.entries[idx] = entry
            } else {
                envelope.entries.append(entry)
            }
            try writeEnvelope(envelope)
        }
    }

    public func remove(id: UUID) throws {
        try queue.sync {
            var envelope = try load()
            envelope.entries.removeAll { $0.id == id }
            try writeEnvelope(envelope)
        }
    }

    /// One decode + one publish regardless of how many entries are dropped.
    public func remove(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            var envelope = try load()
            envelope.entries.removeAll { ids.contains($0.id) }
            try writeEnvelope(envelope)
        }
    }

    public func removeAll() throws {
        try queue.sync {
            try writeEnvelope(Envelope(entries: []))
        }
    }

    public func sortedEntries() throws -> [ClipboardEntry] {
        ClipboardSorting.pinnedFirst(try allEntries())
    }

    public func search(query: String) throws -> [ClipboardEntry] {
        ClipboardSorting.pinnedFirst(try allEntries().filter {
            ClipboardSorting.matches(entry: $0, query: query)
        })
    }

    private func load() throws -> Envelope {
        if let envelope = try? decodeEnvelope(from: fileURL) {
            return envelope
        }
        // Recovery from last-known-good backup.
        if let envelope = try? decodeEnvelope(from: backupURL) {
            return envelope
        }
        throw ClipboardRepositoryError.persistenceFailed
    }

    private func decodeEnvelope(from url: URL) throws -> Envelope {
        let data = try Data(contentsOf: url)
        if data.isEmpty { return Envelope(entries: []) }
        return try decoder.decode(Envelope.self, from: data)
    }

    /// Publishes a new history snapshot without deleting the previous valid file first.
    private func writeEnvelope(_ envelope: Envelope) throws {
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw ClipboardRepositoryError.persistenceFailed
        }
        do {
            // Atomic rename over destination on Apple file systems.
            try data.write(to: fileURL, options: .atomic)
            // Best-effort last-known-good after primary succeeded.
            try? data.write(to: backupURL, options: .atomic)
        } catch {
            throw ClipboardRepositoryError.persistenceFailed
        }
    }
}
