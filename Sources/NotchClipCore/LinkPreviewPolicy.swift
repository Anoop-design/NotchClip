import Foundation
import CryptoKit

/// Pure URL acceptance for link preview fetches (unit-testable, no network).
public enum LinkPreviewURLPolicy {
    public static let maxTitleLength = 200
    public static let maxImageBytes = 1 * 1024 * 1024

    /// Returns a canonical http/https URL or nil for unsafe/invalid input.
    public static func canonicalHTTPURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme?.lowercased() else { return nil }
        guard scheme == "http" || scheme == "https" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        components.fragment = nil
        components.host = host.lowercased()
        components.scheme = scheme
        return components.url
    }

    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && !(url.host ?? "").isEmpty
    }

    /// Stable cache key: lowercase SHA-256 hex of the canonical absolute string.
    public static func cacheKey(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Accept only exactly 64 lowercase hex characters.
    public static func isValidCacheKey(_ key: String) -> Bool {
        guard key.count == 64 else { return false }
        return key.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Image path must be exactly `images/<key>.png` under the cache root.
    public static func imageRelativePath(forKey key: String) -> String? {
        guard isValidCacheKey(key) else { return nil }
        return "images/\(key).png"
    }

    public static func isSafeImageRelativePath(_ path: String, forKey key: String) -> Bool {
        path == "images/\(key).png" && isValidCacheKey(key) && !path.contains("..")
    }

    public static func trimmedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        return String(t.prefix(maxTitleLength))
    }

    public static func boundedImageData(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty, data.count <= maxImageBytes else { return nil }
        return data
    }
}

/// Network-agnostic metadata result used by cache and UI.
public struct LinkMetadataResult: Equatable, Sendable {
    public var title: String?
    public var imagePNGData: Data?

    public init(title: String? = nil, imagePNGData: Data? = nil) {
        self.title = LinkPreviewURLPolicy.trimmedTitle(title)
        self.imagePNGData = LinkPreviewURLPolicy.boundedImageData(imagePNGData)
    }

    public var isEmpty: Bool {
        (title == nil || title?.isEmpty == true) && (imagePNGData == nil || imagePNGData?.isEmpty == true)
    }
}

/// Injectable fetcher for tests (no network).
public protocol LinkMetadataFetching: Sendable {
    func fetch(url: URL) async throws -> LinkMetadataResult
}

/// Disk + memory cache record (app-owned Codable; never LPLinkMetadata archives).
public struct LinkPreviewCacheRecord: Codable, Equatable, Sendable {
    public var canonicalURL: String
    public var title: String?
    public var imageRelativePath: String?
    public var updatedAt: Date
    public var lastAccessAt: Date

    public init(
        canonicalURL: String,
        title: String? = nil,
        imageRelativePath: String? = nil,
        updatedAt: Date = .now,
        lastAccessAt: Date = .now
    ) {
        self.canonicalURL = canonicalURL
        self.title = LinkPreviewURLPolicy.trimmedTitle(title)
        self.imageRelativePath = imageRelativePath
        self.updatedAt = updatedAt
        self.lastAccessAt = lastAccessAt
    }
}

/// Local bounded cache under Caches/NotchClip/LinkPreviews.
/// Memory: 32 records / 16 MiB LRU. Disk: 200 records / 64 MiB / 30-day TTL.
public final class LinkPreviewCache: @unchecked Sendable {
    public static let maxDiskRecords = 200
    public static let maxDiskBytes = 64 * 1024 * 1024
    public static let maxMemoryRecords = 32
    public static let maxMemoryBytes = 16 * 1024 * 1024
    public static let ttl: TimeInterval = 30 * 24 * 60 * 60

    public let rootDirectory: URL
    public var maxRecordsLimit: Int
    public var maxBytesLimit: Int
    public var maxMemoryRecordsLimit: Int
    public var maxMemoryBytesLimit: Int
    public var ttlInterval: TimeInterval
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.anoop.notchclip.link-cache")
    /// Memory LRU: most-recently-used at the end.
    private var memoryOrder: [String] = []
    private var memory: [String: (LinkPreviewCacheRecord, Data?)] = [:]

    public init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        maxRecordsLimit: Int = LinkPreviewCache.maxDiskRecords,
        maxBytesLimit: Int = LinkPreviewCache.maxDiskBytes,
        maxMemoryRecordsLimit: Int = LinkPreviewCache.maxMemoryRecords,
        maxMemoryBytesLimit: Int = LinkPreviewCache.maxMemoryBytes,
        ttlInterval: TimeInterval = LinkPreviewCache.ttl
    ) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.maxRecordsLimit = maxRecordsLimit
        self.maxBytesLimit = maxBytesLimit
        self.maxMemoryRecordsLimit = maxMemoryRecordsLimit
        self.maxMemoryBytesLimit = maxMemoryBytesLimit
        self.ttlInterval = ttlInterval
        try fileManager.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: self.rootDirectory.appendingPathComponent("images", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    public static func defaultRoot() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("NotchClip/LinkPreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public func load(key: String) -> (record: LinkPreviewCacheRecord, imageData: Data?)? {
        queue.sync {
            guard LinkPreviewURLPolicy.isValidCacheKey(key) else { return nil }
            if let mem = memory[key] {
                var rec = mem.0
                if Date().timeIntervalSince(rec.updatedAt) > ttlInterval {
                    try? removeUnlocked(key: key, record: rec)
                    return nil
                }
                touchMemory(key: key)
                rec.lastAccessAt = .now
                memory[key] = (rec, mem.1)
                return (rec, mem.1)
            }
            let url = recordURL(key: key)
            guard isPathUnderRoot(url) else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard var rec = try? JSONDecoder().decode(LinkPreviewCacheRecord.self, from: data) else {
                try? fileManager.removeItem(at: url)
                // Drop orphan image if present for this key.
                if let rel = LinkPreviewURLPolicy.imageRelativePath(forKey: key) {
                    try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(rel))
                }
                return nil
            }
            if Date().timeIntervalSince(rec.updatedAt) > ttlInterval {
                try? removeUnlocked(key: key, record: rec)
                return nil
            }
            rec.lastAccessAt = .now
            var imageData: Data?
            if let rel = rec.imageRelativePath {
                guard LinkPreviewURLPolicy.isSafeImageRelativePath(rel, forKey: key) else {
                    try? removeUnlocked(key: key, record: rec)
                    return nil
                }
                let imgURL = rootDirectory.appendingPathComponent(rel)
                guard isPathUnderRoot(imgURL),
                      let bytes = try? Data(contentsOf: imgURL),
                      bytes.count <= LinkPreviewURLPolicy.maxImageBytes else {
                    // Corrupt/oversize image: drop image, keep title if any.
                    rec.imageRelativePath = nil
                    imageData = nil
                    try? writeIndexRecordAtomic(rec, key: key)
                    putMemory(key: key, record: rec, image: nil)
                    return (rec, nil)
                }
                imageData = bytes
            }
            putMemory(key: key, record: rec, image: imageData)
            try? writeIndexRecordAtomic(rec, key: key)
            return (rec, imageData)
        }
    }

    public func store(key: String, url: URL, result: LinkMetadataResult) throws {
        try queue.sync {
            guard LinkPreviewURLPolicy.isValidCacheKey(key) else {
                throw ClipboardRepositoryError.persistenceFailed
            }
            let title = LinkPreviewURLPolicy.trimmedTitle(result.title)
            let img = LinkPreviewURLPolicy.boundedImageData(result.imagePNGData)
            var imageRel: String?
            if let img, let rel = LinkPreviewURLPolicy.imageRelativePath(forKey: key) {
                let imgURL = rootDirectory.appendingPathComponent(rel)
                guard isPathUnderRoot(imgURL) else {
                    throw ClipboardRepositoryError.persistenceFailed
                }
                // Atomic image write.
                try img.write(to: imgURL, options: .atomic)
                imageRel = rel
            }
            let rec = LinkPreviewCacheRecord(
                canonicalURL: url.absoluteString,
                title: title,
                imageRelativePath: imageRel,
                updatedAt: .now,
                lastAccessAt: .now
            )
            try writeIndexRecordAtomic(rec, key: key)
            putMemory(key: key, record: rec, image: img)
            try enforceDiskLimitsUnlocked()
        }
    }

    /// Synchronous wipe (call off MainActor for large trees).
    public func removeAll() throws {
        try queue.sync {
            memory.removeAll()
            memoryOrder.removeAll()
            if fileManager.fileExists(atPath: rootDirectory.path) {
                try fileManager.removeItem(at: rootDirectory)
            }
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: rootDirectory.appendingPathComponent("images", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    public func recordCountForTesting() -> Int {
        queue.sync {
            (try? fileManager.contentsOfDirectory(atPath: rootDirectory.path))?
                .filter { $0.hasSuffix(".json") }.count ?? 0
        }
    }

    public func memoryCountForTesting() -> Int {
        queue.sync { memory.count }
    }

    // MARK: - Private

    private func recordURL(key: String) -> URL {
        rootDirectory.appendingPathComponent("\(key).json")
    }

    private func isPathUnderRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let root = rootDirectory.path
        return path == root || path.hasPrefix(root + "/")
    }

    /// Atomic replace without an unlink gap (`Data.write(options: .atomic)`).
    private func writeIndexRecordAtomic(_ rec: LinkPreviewCacheRecord, key: String) throws {
        let data = try JSONEncoder().encode(rec)
        let final = recordURL(key: key)
        guard isPathUnderRoot(final) else {
            throw ClipboardRepositoryError.persistenceFailed
        }
        try data.write(to: final, options: .atomic)
    }

    private func putMemory(key: String, record: LinkPreviewCacheRecord, image: Data?) {
        memory[key] = (record, image)
        touchMemory(key: key)
        enforceMemoryLimitsUnlocked()
    }

    private func touchMemory(key: String) {
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }

    private func enforceMemoryLimitsUnlocked() {
        var totalBytes = memory.values.reduce(0) { $0 + ($1.1?.count ?? 0) }
        while memory.count > maxMemoryRecordsLimit || totalBytes > maxMemoryBytesLimit {
            guard let oldest = memoryOrder.first else { break }
            memoryOrder.removeFirst()
            if let removed = memory.removeValue(forKey: oldest) {
                totalBytes -= removed.1?.count ?? 0
            }
        }
    }

    private func removeUnlocked(key: String, record: LinkPreviewCacheRecord) throws {
        try? fileManager.removeItem(at: recordURL(key: key))
        if let rel = record.imageRelativePath,
           LinkPreviewURLPolicy.isSafeImageRelativePath(rel, forKey: key) {
            let img = rootDirectory.appendingPathComponent(rel)
            if isPathUnderRoot(img) {
                try? fileManager.removeItem(at: img)
            }
        } else if let rel = LinkPreviewURLPolicy.imageRelativePath(forKey: key) {
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(rel))
        }
        memory.removeValue(forKey: key)
        memoryOrder.removeAll { $0 == key }
    }

    private func enforceDiskLimitsUnlocked() throws {
        let files = (try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var records: [(key: String, rec: LinkPreviewCacheRecord, size: Int)] = []
        var total = 0
        for url in files where url.pathExtension == "json" {
            let key = url.deletingPathExtension().lastPathComponent
            guard LinkPreviewURLPolicy.isValidCacheKey(key) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let rec = try? JSONDecoder().decode(LinkPreviewCacheRecord.self, from: data) else {
                try? fileManager.removeItem(at: url)
                if let rel = LinkPreviewURLPolicy.imageRelativePath(forKey: key) {
                    try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(rel))
                }
                continue
            }
            if Date().timeIntervalSince(rec.updatedAt) > ttlInterval {
                try? removeUnlocked(key: key, record: rec)
                continue
            }
            var size = data.count
            if let rel = rec.imageRelativePath,
               LinkPreviewURLPolicy.isSafeImageRelativePath(rel, forKey: key) {
                let img = rootDirectory.appendingPathComponent(rel)
                size += (try? img.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
            total += size
            records.append((key, rec, size))
        }
        records.sort { $0.rec.lastAccessAt < $1.rec.lastAccessAt }
        while records.count > maxRecordsLimit || total > maxBytesLimit {
            guard let victim = records.first else { break }
            try? removeUnlocked(key: victim.key, record: victim.rec)
            total -= victim.size
            records.removeFirst()
        }
    }
}

/// Coordinates visible-row link preview requests with **canonical-URL** shared fetches.
@MainActor
public final class LinkPreviewService {
    private let cache: LinkPreviewCache
    private let fetcher: any LinkMetadataFetching
    /// Shared fetch task per cache key.
    private var fetchTasks: [String: Task<Void, Never>] = [:]
    /// Waiters: cache key → entry IDs still visible.
    private var waiters: [String: Set<UUID>] = [:]
    /// Visible entry → canonical URL string (for cancel).
    private var visibleURLByEntry: [UUID: String] = [:]
    /// Visible entry → ClipboardEntry snapshot for re-enable.
    private var visibleEntries: [UUID: ClipboardEntry] = [:]
    /// Bumped when panel hides / preference-off so late completions cannot publish.
    private var publishGeneration: UInt64 = 0

    public private(set) var enabled: Bool = true
    /// Panel-visibility seam: when false, no new fetches and no result publishing.
    public private(set) var isPanelVisible: Bool = true
    public private(set) var fetchAttemptCount: Int = 0
    public private(set) var results: [UUID: LinkMetadataResult] = [:]
    /// Completed results keyed by cache key for same-URL reuse.
    private var resultsByKey: [String: LinkMetadataResult] = [:]
    public var onUpdate: ((UUID, LinkMetadataResult) -> Void)?

    public init(cache: LinkPreviewCache, fetcher: any LinkMetadataFetching) {
        self.cache = cache
        self.fetcher = fetcher
    }

    public var activeRequestCount: Int { fetchTasks.count }
    public var visibleCount: Int { visibleEntries.count }

    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            publishGeneration &+= 1
            cancelAll()
            results.removeAll()
            resultsByKey.removeAll()
        }
        // Re-request is the caller's responsibility (HistoryModel resolves retained URLs;
        // pure service tests call `requestVisible` again after re-enable).
    }

    /// Panel-visibility gate (tests + production). Hiding cancels in-flight work and
    /// invalidates publish generation so late completions cannot fan out.
    public func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
        if !visible {
            publishGeneration &+= 1
            cancelAll()
        }
        // Showing does not auto-fetch; HistoryModel / tests re-request tracked rows.
    }

    public func cancelAll() {
        for (_, task) in fetchTasks { task.cancel() }
        fetchTasks.removeAll()
        waiters.removeAll()
        // Keep visibleEntries so re-enable can re-request only those.
    }

    public func cancel(entryID: UUID) {
        visibleEntries.removeValue(forKey: entryID)
        guard let urlString = visibleURLByEntry.removeValue(forKey: entryID),
              let url = URL(string: urlString) else {
            return
        }
        let key = LinkPreviewURLPolicy.cacheKey(for: url)
        waiters[key]?.remove(entryID)
        if waiters[key]?.isEmpty != false {
            waiters[key] = nil
            fetchTasks[key]?.cancel()
            fetchTasks[key] = nil
        }
    }

    /// Async clear: filesystem I/O off MainActor.
    public func clearCache() async throws {
        cancelAll()
        results.removeAll()
        resultsByKey.removeAll()
        // Keep visibleEntries + visibleURLByEntry so re-enable / panel re-show can re-request.
        let cache = self.cache
        try await Task.detached(priority: .utility) {
            try cache.removeAll()
        }.value
    }

    /// Convenience for pure service tests: derives URL from `entry.previewText`.
    /// Production `HistoryModel` must use `requestVisible(entry:url:)` with the retained payload URL.
    public func requestVisible(entry: ClipboardEntry) {
        visibleEntries[entry.id] = entry
        guard enabled, isPanelVisible else { return }
        guard entry.primaryKind == .url else { return }
        guard let url = LinkPreviewURLPolicy.canonicalHTTPURL(from: entry.previewText) else { return }
        requestVisible(entry: entry, url: url)
    }

    /// Primary API: fetch/cache keyed by an already-resolved canonical http(s) URL.
    public func requestVisible(entry: ClipboardEntry, url: URL) {
        visibleEntries[entry.id] = entry
        guard enabled, isPanelVisible else { return }
        guard entry.primaryKind == .url else { return }
        guard LinkPreviewURLPolicy.isAllowed(url) else { return }

        let id = entry.id
        let key = LinkPreviewURLPolicy.cacheKey(for: url)
        visibleURLByEntry[id] = url.absoluteString
        let generation = publishGeneration

        if let existing = results[id], !existing.isEmpty {
            return
        }
        // Same canonical URL already resolved — fan out without a second fetch.
        if let shared = resultsByKey[key], !shared.isEmpty {
            guard isPanelVisible, enabled, publishGeneration == generation else { return }
            results[id] = shared
            onUpdate?(id, shared)
            return
        }

        var set = waiters[key] ?? []
        set.insert(id)
        waiters[key] = set

        if fetchTasks[key] != nil {
            return // Shared fetch already in flight.
        }

        let cache = self.cache
        let fetcher = self.fetcher

        fetchTasks[key] = Task { [weak self] in
            let cached = await Task.detached(priority: .utility) {
                cache.load(key: key)
            }.value

            if Task.isCancelled {
                await MainActor.run { self?.finishTask(key: key) }
                return
            }

            // A title-only cache entry must not permanently suppress artwork.
            // Publish complete cache hits immediately; otherwise refetch once
            // per service lifetime so upgraded image extraction can fill it in.
            if let cached, cached.imageData != nil {
                let result = LinkMetadataResult(
                    title: cached.record.title,
                    imagePNGData: cached.imageData
                )
                await MainActor.run {
                    self?.fanout(key: key, result: result, generation: generation)
                }
                return
            }

            await MainActor.run { self?.fetchAttemptCount += 1 }
            do {
                let result = try await fetcher.fetch(url: url)
                if Task.isCancelled {
                    await MainActor.run { self?.finishTask(key: key) }
                    return
                }
                try? await Task.detached(priority: .utility) {
                    try cache.store(key: key, url: url, result: result)
                }.value
                if Task.isCancelled {
                    await MainActor.run { self?.finishTask(key: key) }
                    return
                }
                await MainActor.run {
                    self?.fanout(key: key, result: result, generation: generation)
                }
            } catch {
                await MainActor.run { self?.finishTask(key: key) }
            }
        }
    }

    private func fanout(key: String, result: LinkMetadataResult, generation: UInt64) {
        guard enabled, isPanelVisible, publishGeneration == generation else {
            finishTask(key: key)
            return
        }
        resultsByKey[key] = result
        let ids = waiters[key] ?? []
        for id in ids {
            // Skip waiters that disappeared (row hide / delete) while the fetch was in flight.
            guard visibleEntries[id] != nil else { continue }
            results[id] = result
            onUpdate?(id, result)
        }
        finishTask(key: key)
    }

    private func finishTask(key: String) {
        fetchTasks[key] = nil
        waiters[key] = nil
    }
}
