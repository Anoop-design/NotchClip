import Foundation

public enum PayloadStoreError: Error, Equatable, Sendable {
    case writeFailed
    case readFailed
    case notFound
}

/// Atomic on-disk storage for pasteboard representation payloads.
/// Does **not** copy user source files into the store — only serialized pasteboard data.
public protocol PayloadStoring: Sendable {
    var rootDirectory: URL { get }
    func store(entryID: UUID, representation: ParsedRepresentation) throws -> PayloadReference
    /// Transactional multi-representation store: publish a complete entry directory or nothing.
    func storeAll(entryID: UUID, representations: [ParsedRepresentation]) throws -> [PayloadReference]
    func loadData(for reference: PayloadReference) throws -> Data
    func removeAll(for entryID: UUID) throws
    func removeAll() throws
    /// UUIDs of published entry directories under the store root (skips staging dirs).
    func storedEntryIDs() throws -> [UUID]
    /// Total bytes of stored payload files (not original source files).
    func totalByteCount() throws -> Int
    /// Whether a published entry directory exists.
    func entryDirectoryExists(entryID: UUID) -> Bool
    /// Remove orphan published entry dirs and leftover staging directories under the store root.
    /// Does not touch original source files outside this root.
    @discardableResult
    func removeOrphansAndStaging(validEntryIDs: Set<UUID>) throws -> Int
}

public final class PayloadStore: PayloadStoring, @unchecked Sendable {
    public let rootDirectory: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.notchclip.payload-store")

    public init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    public func store(entryID: UUID, representation: ParsedRepresentation) throws -> PayloadReference {
        // Single-rep path still uses a transactional batch of one.
        try storeAll(entryID: entryID, representations: [representation])[0]
    }

    /// Write the full set into a unique staging directory, then rename to the entry UUID
    /// directory in one move. On any failure, staging is removed and no final entry is left.
    public func storeAll(entryID: UUID, representations: [ParsedRepresentation]) throws -> [PayloadReference] {
        try queue.sync {
            let stagingName = ".\(entryID.uuidString).staging-\(UUID().uuidString)"
            let stagingDir = rootDirectory.appendingPathComponent(stagingName, isDirectory: true)
            let finalDir = rootDirectory.appendingPathComponent(entryID.uuidString, isDirectory: true)

            do {
                try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                var refs: [PayloadReference] = []
                for rep in representations {
                    let base = sanitize(rep.typeIdentifier)
                    let fileName = "\(rep.itemIndex)-\(base)-\(UUID().uuidString.prefix(8))"
                    let stagingFile = stagingDir.appendingPathComponent(fileName)
                    try rep.data.write(to: stagingFile, options: .atomic)
                    let relative = "\(entryID.uuidString)/\(fileName)"
                    refs.append(
                        PayloadReference(
                            itemIndex: rep.itemIndex,
                            typeIdentifier: rep.typeIdentifier,
                            relativePath: relative,
                            byteCount: rep.data.count,
                            originalFilePath: rep.originalFilePath
                        )
                    )
                }

                // Publish: move staging → final. Never leave a partial final directory.
                if fileManager.fileExists(atPath: finalDir.path) {
                    try fileManager.removeItem(at: finalDir)
                }
                try fileManager.moveItem(at: stagingDir, to: finalDir)
                return refs
            } catch {
                try? fileManager.removeItem(at: stagingDir)
                // Ensure no partial final from a failed mid-publish.
                if !fileManager.fileExists(atPath: finalDir.path) {
                    // ok
                }
                throw PayloadStoreError.writeFailed
            }
        }
    }

    public func loadData(for reference: PayloadReference) throws -> Data {
        try queue.sync {
            let url = rootDirectory.appendingPathComponent(reference.relativePath)
            guard fileManager.fileExists(atPath: url.path) else {
                throw PayloadStoreError.notFound
            }
            guard let data = try? Data(contentsOf: url) else {
                throw PayloadStoreError.readFailed
            }
            return data
        }
    }

    public func removeAll(for entryID: UUID) throws {
        try queue.sync {
            let dir = rootDirectory.appendingPathComponent(entryID.uuidString, isDirectory: true)
            if fileManager.fileExists(atPath: dir.path) {
                try fileManager.removeItem(at: dir)
            }
        }
    }

    public func removeAll() throws {
        try queue.sync {
            if fileManager.fileExists(atPath: rootDirectory.path) {
                try fileManager.removeItem(at: rootDirectory)
            }
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        }
    }

    public func storedEntryIDs() throws -> [UUID] {
        try queue.sync {
            let contents = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            return contents.compactMap { url -> UUID? in
                // Skip staging directories (leading '.')
                let name = url.lastPathComponent
                if name.hasPrefix(".") { return nil }
                return UUID(uuidString: name)
            }
        }
    }

    public func totalByteCount() throws -> Int {
        try queue.sync {
            guard let enumerator = fileManager.enumerator(
                at: rootDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            var total = 0
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true {
                    total += values.fileSize ?? 0
                }
            }
            return total
        }
    }

    public func entryDirectoryExists(entryID: UUID) -> Bool {
        queue.sync {
            let dir = rootDirectory.appendingPathComponent(entryID.uuidString, isDirectory: true)
            return fileManager.fileExists(atPath: dir.path)
        }
    }

    @discardableResult
    public func removeOrphansAndStaging(validEntryIDs: Set<UUID>) throws -> Int {
        try queue.sync {
            let contents = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
            var removed = 0
            for url in contents {
                let name = url.lastPathComponent
                if name.hasPrefix(".") {
                    // Staging directories: .uuid.staging-...
                    try? fileManager.removeItem(at: url)
                    removed += 1
                    continue
                }
                if let id = UUID(uuidString: name), !validEntryIDs.contains(id) {
                    try fileManager.removeItem(at: url)
                    removed += 1
                }
            }
            return removed
        }
    }

    private func sanitize(_ typeIdentifier: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scaled = typeIdentifier.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let name = String(scaled)
        return name.isEmpty ? "payload" : String(name.prefix(120))
    }
}

/// In-memory payload store for tests.
public final class InMemoryPayloadStore: PayloadStoring, @unchecked Sendable {
    public let rootDirectory: URL
    private var storage: [String: Data] = [:]
    private var publishedEntries: Set<UUID> = []
    private let lock = NSLock()
    /// Test seam: fail on the Nth representation during `storeAll` (1-based). Nil = never fail.
    public var failOnRepresentationIndex: Int?
    /// Test seam: number of successful `loadData` calls (lazy-drag verification).
    public private(set) var loadCount: Int = 0

    public init(rootDirectory: URL = URL(fileURLWithPath: "/tmp/notchclip-memory-payloads")) {
        self.rootDirectory = rootDirectory
    }

    public func resetLoadCount() {
        lock.lock()
        loadCount = 0
        lock.unlock()
    }

    public func store(entryID: UUID, representation: ParsedRepresentation) throws -> PayloadReference {
        try storeAll(entryID: entryID, representations: [representation])[0]
    }

    public func storeAll(entryID: UUID, representations: [ParsedRepresentation]) throws -> [PayloadReference] {
        lock.lock()
        defer { lock.unlock() }
        var refs: [PayloadReference] = []
        var stagedKeys: [String] = []
        for (i, rep) in representations.enumerated() {
            if let failAt = failOnRepresentationIndex, i + 1 == failAt {
                // Roll back staged keys for this entry — no publish.
                for key in stagedKeys { storage.removeValue(forKey: key) }
                throw PayloadStoreError.writeFailed
            }
            let relative = "\(entryID.uuidString)/\(rep.itemIndex)-\(rep.typeIdentifier)-\(UUID().uuidString)"
            storage[relative] = rep.data
            stagedKeys.append(relative)
            refs.append(
                PayloadReference(
                    itemIndex: rep.itemIndex,
                    typeIdentifier: rep.typeIdentifier,
                    relativePath: relative,
                    byteCount: rep.data.count,
                    originalFilePath: rep.originalFilePath
                )
            )
        }
        publishedEntries.insert(entryID)
        return refs
    }

    public func loadData(for reference: PayloadReference) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let data = storage[reference.relativePath] else {
            throw PayloadStoreError.notFound
        }
        loadCount += 1
        return data
    }

    public func removeAll(for entryID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let prefix = entryID.uuidString + "/"
        storage = storage.filter { !$0.key.hasPrefix(prefix) }
        publishedEntries.remove(entryID)
    }

    public func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        publishedEntries.removeAll()
    }

    public func storedEntryIDs() throws -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return Array(publishedEntries)
    }

    public func totalByteCount() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.reduce(0) { $0 + $1.count }
    }

    public func entryDirectoryExists(entryID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return publishedEntries.contains(entryID)
    }

    @discardableResult
    public func removeOrphansAndStaging(validEntryIDs: Set<UUID>) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let orphans = publishedEntries.subtracting(validEntryIDs)
        for id in orphans {
            let prefix = id.uuidString + "/"
            storage = storage.filter { !$0.key.hasPrefix(prefix) }
            publishedEntries.remove(id)
        }
        return orphans.count
    }
}
