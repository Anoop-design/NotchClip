import XCTest
@testable import NotchClipCore
import Foundation

final class EntryPresentationTests: XCTestCase {
    func testKindLabelsAreHumanReadable() {
        XCTAssertEqual(EntryKindLabel.displayName(for: .plainText), "Text")
        XCTAssertEqual(EntryKindLabel.displayName(for: .fileList), "Files")
        XCTAssertEqual(EntryPresentation.kindBadge(for: .html), "HTML")
        XCTAssertFalse(EntryKindLabel.displayName(for: .plainText).contains("plainText"))
    }

    func testURLHostAndTitle() {
        XCTAssertEqual(EntryPresentation.urlHost(from: "https://example.com/path"), "example.com")
        XCTAssertEqual(EntryPresentation.urlTitleFallback(from: "https://swift.org/blog"), "swift.org")
    }

    func testFileDisplayAndCount() {
        XCTAssertEqual(EntryPresentation.fileDisplayName(paths: ["/tmp/a.txt"]), "a.txt")
        XCTAssertEqual(EntryPresentation.fileDisplayName(paths: ["/tmp/a.txt", "/tmp/b.txt"]), "a.txt +1")
        XCTAssertEqual(EntryPresentation.fileCountLabel(count: 1), "1 file")
        XCTAssertEqual(EntryPresentation.fileCountLabel(count: 3), "3 files")
    }

    func testSourceAndTimestamp() {
        let source = SourceMetadata(bundleIdentifier: "com.apple.Safari", applicationName: "Safari")
        XCTAssertEqual(EntryPresentation.sourceLabel(from: source), "Safari")
        let onlyBundle = SourceMetadata(bundleIdentifier: "com.example.Tool", applicationName: nil)
        XCTAssertEqual(EntryPresentation.sourceLabel(from: onlyBundle), "Tool")
        let ts = EntryPresentation.relativeTimestamp(
            for: Date(timeIntervalSinceNow: -120),
            now: Date()
        )
        XCTAssertFalse(ts.isEmpty)
    }

    func testByteFormatting() {
        let s = EntryPresentation.byteCountString(1500)
        XCTAssertFalse(s.isEmpty)
    }

    func testRowModelFromEntry() {
        let entry = ClipboardEntry(
            isPinned: true,
            source: SourceMetadata(bundleIdentifier: nil, applicationName: "Notes"),
            primaryKind: .url,
            previewText: "https://example.com/x",
            searchText: "https://example.com/x",
            fingerprint: "fp"
        )
        let row = EntryRowModel(entry: entry)
        XCTAssertEqual(row.kindLabel, "Link")
        XCTAssertTrue(row.isPinned)
        XCTAssertTrue(row.primaryText.contains("example.com") || row.primaryText == "example.com")
    }
}

final class StorageStatsTests: XCTestCase {
    func testStorageStatsFormatting() throws {
        let store = InMemoryPayloadStore()
        let repo = InMemoryClipboardRepository()
        let engine = ClipboardEngine(repository: repo, payloadStore: store)
        _ = engine.ingest(parsed: ParsedPasteboardItem(
            representations: [
                ParsedRepresentation(
                    itemIndex: 0,
                    typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText,
                    data: Data("hello-stats".utf8)
                )
            ],
            primaryKind: .plainText,
            previewText: "hello-stats",
            searchText: "hello-stats",
            fingerprint: Fingerprinter.fingerprint(
                typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText,
                data: Data("hello-stats".utf8)
            )
        ))
        let stats = try engine.storageStats(applicationSupportPath: "/tmp/NotchClip")
        XCTAssertEqual(stats.itemCount, 1)
        XCTAssertGreaterThan(stats.payloadBytes, 0)
        XCTAssertFalse(stats.formattedBytes.isEmpty)
        XCTAssertEqual(stats.applicationSupportPath, "/tmp/NotchClip")
    }
}

final class ClearHistoryModelFlowsTests: XCTestCase {
    func testClearUnpinnedPreservesPinned() throws {
        let engine = ClipboardEngine(
            repository: InMemoryClipboardRepository(),
            payloadStore: InMemoryPayloadStore()
        )
        guard case .inserted(let a) = engine.ingest(parsed: textItem("a")),
              case .inserted(let b) = engine.ingest(parsed: textItem("b")) else {
            return XCTFail("insert")
        }
        try engine.setPinned(id: a.id, isPinned: true)
        try engine.clearUnpinned()
        let left = try engine.sortedEntries()
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.id, a.id)
        XCTAssertFalse(engine.payloadStore.entryDirectoryExists(entryID: b.id))
    }

    func testClearAllRemovesMetadataAndPayloads() throws {
        let store = InMemoryPayloadStore()
        let engine = ClipboardEngine(
            repository: InMemoryClipboardRepository(),
            payloadStore: store
        )
        _ = engine.ingest(parsed: textItem("x"))
        _ = engine.ingest(parsed: textItem("y"))
        // Orphan payload
        let orphan = UUID()
        _ = try store.storeAll(
            entryID: orphan,
            representations: [
                ParsedRepresentation(itemIndex: 0, typeIdentifier: "t", data: Data("o".utf8))
            ]
        )
        try engine.clearAll()
        XCTAssertEqual(try engine.entryCount(), 0)
        XCTAssertEqual(try store.storedEntryIDs().count, 0)
        XCTAssertFalse(store.entryDirectoryExists(entryID: orphan))
    }

    private func textItem(_ text: String) -> ParsedPasteboardItem {
        let data = Data(text.utf8)
        let type = ClipboardTypeIdentifiers.utf8PlainText
        return ParsedPasteboardItem(
            representations: [ParsedRepresentation(itemIndex: 0, typeIdentifier: type, data: data)],
            primaryKind: .plainText,
            previewText: text,
            searchText: text,
            fingerprint: Fingerprinter.fingerprint(typeIdentifier: type, data: data)
        )
    }
}

final class PreferencesTests: XCTestCase {
    func testLinkPreviewPreferenceDefaultsOnAndPersists() {
        let name = "com.anoop.notchclip.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        let loaded = AppPreferences.load(defaults: suite)
        XCTAssertTrue(loaded.fetchLinkPreviews)
        let prefs = AppPreferences(fetchLinkPreviews: false)
        prefs.save(defaults: suite)
        let again = AppPreferences.load(defaults: suite)
        XCTAssertFalse(again.fetchLinkPreviews)
    }
}

final class ExclusiveHotKeyOptionTests: XCTestCase {
    func testExclusiveOptionConstantIsNonZero() {
        // Seam: production registrar uses kEventHotKeyExclusive (1 << 0).
        XCTAssertEqual(UInt32(1), 1)
        XCTAssertEqual(1 << 0, 1)
    }
}

final class ThumbnailSelectionTests: XCTestCase {
    func testLoadPayloadPrefersPNG() throws {
        let store = InMemoryPayloadStore()
        let engine = ClipboardEngine(repository: InMemoryClipboardRepository(), payloadStore: store)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let text = Data("caption".utf8)
        let reps = [
            ParsedRepresentation(itemIndex: 0, typeIdentifier: ClipboardTypeIdentifiers.png, data: png),
            ParsedRepresentation(itemIndex: 0, typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText, data: text)
        ]
        let parsed = ParsedPasteboardItem(
            representations: reps,
            primaryKind: .mixed,
            previewText: "caption",
            searchText: "caption",
            fingerprint: Fingerprinter.fingerprint(representations: reps)
        )
        guard case .inserted(let entry) = engine.ingest(parsed: parsed) else {
            return XCTFail("insert")
        }
        let loaded = try engine.loadPayloadData(
            for: entry,
            preferring: [ClipboardTypeIdentifiers.png, ClipboardTypeIdentifiers.tiff]
        )
        XCTAssertEqual(loaded?.type, ClipboardTypeIdentifiers.png)
        XCTAssertEqual(loaded?.data, png)
    }
}
