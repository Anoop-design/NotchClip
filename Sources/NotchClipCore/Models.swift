import Foundation

/// Primary classification of a clipboard item's dominant content.
public enum ClipboardContentKind: String, Codable, Sendable, CaseIterable {
    case plainText
    case rtf
    case html
    case url
    case image
    case fileList
    case mixed
    case other
}

/// Source application metadata captured at pasteboard read time.
public struct SourceMetadata: Codable, Equatable, Sendable, Hashable {
    public var bundleIdentifier: String?
    public var applicationName: String?

    public init(bundleIdentifier: String? = nil, applicationName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
    }
}

/// Reference to a retained pasteboard representation stored on disk (never source file copies of originals).
public struct PayloadReference: Equatable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Zero-based index of the `NSPasteboardItem` this representation belonged to.
    /// Legacy metadata without this field decodes as `0`.
    public var itemIndex: Int
    /// UTI / pasteboard type string.
    public var typeIdentifier: String
    /// Path relative to the payload store root.
    public var relativePath: String
    public var byteCount: Int
    /// When this representation is a file URL, the original absolute path for existence checks.
    public var originalFilePath: String?

    public init(
        id: UUID = UUID(),
        itemIndex: Int = 0,
        typeIdentifier: String,
        relativePath: String,
        byteCount: Int,
        originalFilePath: String? = nil
    ) {
        self.id = id
        self.itemIndex = itemIndex
        self.typeIdentifier = typeIdentifier
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.originalFilePath = originalFilePath
    }
}

extension PayloadReference: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, itemIndex, typeIdentifier, relativePath, byteCount, originalFilePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        // Pre-item-index development metadata defaults to item 0.
        itemIndex = try c.decodeIfPresent(Int.self, forKey: .itemIndex) ?? 0
        typeIdentifier = try c.decode(String.self, forKey: .typeIdentifier)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        byteCount = try c.decode(Int.self, forKey: .byteCount)
        originalFilePath = try c.decodeIfPresent(String.self, forKey: .originalFilePath)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(itemIndex, forKey: .itemIndex)
        try c.encode(typeIdentifier, forKey: .typeIdentifier)
        try c.encode(relativePath, forKey: .relativePath)
        try c.encode(byteCount, forKey: .byteCount)
        try c.encodeIfPresent(originalFilePath, forKey: .originalFilePath)
    }
}

/// Stable clipboard history entry with representation metadata.
public struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var isPinned: Bool
    public var source: SourceMetadata
    public var primaryKind: ClipboardContentKind
    /// Short human-readable preview.
    public var previewText: String
    /// Normalized text used for local search.
    public var searchText: String
    /// SHA-256 hex fingerprint of retained representation contents.
    public var fingerprint: String
    public var payloadRefs: [PayloadReference]

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isPinned: Bool = false,
        source: SourceMetadata = SourceMetadata(),
        primaryKind: ClipboardContentKind,
        previewText: String,
        searchText: String,
        fingerprint: String,
        payloadRefs: [PayloadReference] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.source = source
        self.primaryKind = primaryKind
        self.previewText = previewText
        self.searchText = searchText
        self.fingerprint = fingerprint
        self.payloadRefs = payloadRefs
    }

    /// True when any original file-path reference no longer exists on disk.
    public func hasMissingFiles(fileManager: FileManager = .default) -> Bool {
        for ref in payloadRefs {
            guard let path = ref.originalFilePath else { continue }
            if !fileManager.fileExists(atPath: path) {
                return true
            }
        }
        return false
    }

    public var originalFilePaths: [String] {
        payloadRefs.compactMap(\.originalFilePath)
    }
}

/// Parsed pasteboard snapshot prior to persistence.
public struct ParsedPasteboardItem: Equatable, Sendable {
    public var representations: [ParsedRepresentation]
    public var primaryKind: ClipboardContentKind
    public var previewText: String
    public var searchText: String
    public var source: SourceMetadata
    public var fingerprint: String
    public var originalFilePaths: [String]

    public init(
        representations: [ParsedRepresentation],
        primaryKind: ClipboardContentKind,
        previewText: String,
        searchText: String,
        source: SourceMetadata = SourceMetadata(),
        fingerprint: String,
        originalFilePaths: [String] = []
    ) {
        self.representations = representations
        self.primaryKind = primaryKind
        self.previewText = previewText
        self.searchText = searchText
        self.source = source
        self.fingerprint = fingerprint
        self.originalFilePaths = originalFilePaths
    }
}

/// One retained representation from a specific pasteboard item.
public struct ParsedRepresentation: Equatable, Sendable {
    /// Zero-based `NSPasteboardItem` index within the pasteboard.
    public var itemIndex: Int
    public var typeIdentifier: String
    public var data: Data
    public var originalFilePath: String?

    public init(
        itemIndex: Int = 0,
        typeIdentifier: String,
        data: Data,
        originalFilePath: String? = nil
    ) {
        self.itemIndex = itemIndex
        self.typeIdentifier = typeIdentifier
        self.data = data
        self.originalFilePath = originalFilePath
    }
}

/// Distinguishes storage / I/O failures from “clipboard had nothing retainable”.
public enum CaptureFailure: Error, Equatable, Sendable {
    /// Metadata repository write/read failure.
    case repository(String)
    /// Payload directory / byte storage failure.
    case payload(String)
    /// Other unexpected failure.
    case unknown(String)

    public var message: String {
        switch self {
        case .repository(let m), .payload(let m), .unknown(let m):
            return m
        }
    }
}

/// Outcome of attempting to ingest the current pasteboard.
public enum CaptureResult: Equatable, Sendable {
    case ignoredTransient
    /// Clipboard had no retainable content (empty, all over-cap, or unreadable types).
    case ignoredEmpty
    case ignoredSelfWrite
    case inserted(ClipboardEntry)
    case updatedExisting(ClipboardEntry)
    /// Disk-full, permission, corruption, or other storage failure — never means empty clipboard.
    case failed(CaptureFailure)
}
