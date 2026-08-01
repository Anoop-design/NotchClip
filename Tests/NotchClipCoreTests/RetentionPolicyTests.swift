import XCTest
@testable import NotchClipCore

final class RetentionPolicyTests: XCTestCase {
    func testUnderAndAtLimitEvictNothing() {
        let entries = makeEntries(count: 500)
        XCTAssertTrue(RetentionPolicy.idsToEvict(entries: entries, limit: 500).isEmpty)
        XCTAssertTrue(RetentionPolicy.idsToEvict(entries: Array(entries.prefix(3)), limit: 500).isEmpty)
        XCTAssertTrue(RetentionPolicy.idsToEvict(entries: [], limit: 500).isEmpty)
    }

    func testOneOverLimitEvictsExactlyTheOldest() {
        let entries = makeEntries(count: 501)
        let evicted = RetentionPolicy.idsToEvict(entries: entries, limit: 500)
        XCTAssertEqual(evicted, [entries[500].id])
    }

    func testEvictsOldestFirstInOrder() {
        // Newest-first input: e0 newest … e5 oldest.
        let entries = makeEntries(count: 6)
        let evicted = RetentionPolicy.idsToEvict(entries: entries, limit: 2)
        XCTAssertEqual(evicted, [entries[5].id, entries[4].id, entries[3].id, entries[2].id])
    }

    func testPinnedAreExemptAndDoNotCountAgainstLimit() {
        var entries = makeEntries(count: 3)
        let pinned = makeEntries(count: 3, pinned: true, minuteOffset: 100)
        entries.append(contentsOf: pinned)
        let evicted = RetentionPolicy.idsToEvict(entries: entries, limit: 2)
        // Three pinned + u1/u2/u3 with limit 2 evicts only the oldest unpinned.
        XCTAssertEqual(evicted, [entries[2].id])
        for entry in pinned {
            XCTAssertFalse(evicted.contains(entry.id))
        }
    }

    func testAllPinnedNeverEvictsRegardlessOfLimit() {
        let entries = makeEntries(count: 10, pinned: true)
        XCTAssertTrue(RetentionPolicy.idsToEvict(entries: entries, limit: 1).isEmpty)
    }

    func testUnlimitedAndNonPositiveLimitsKeepEverything() {
        let entries = makeEntries(count: 40)
        XCTAssertTrue(RetentionPolicy.idsToEvict(entries: entries, limit: RetentionPolicy.unlimited).isEmpty)
        XCTAssertTrue(RetentionPolicy.idsToEvict(entries: entries, limit: -1).isEmpty)
    }

    func testLoweringTheLimitPrunesOldestFirst() {
        let entries = makeEntries(count: 10)
        XCTAssertTrue(RetentionPolicy.idsToEvict(entries: entries, limit: 10).isEmpty)
        let lowered = RetentionPolicy.idsToEvict(entries: entries, limit: 4)
        XCTAssertEqual(lowered.count, 6)
        XCTAssertEqual(lowered, entries.suffix(6).reversed().map(\.id))
        // The four newest survive.
        for entry in entries.prefix(4) {
            XCTAssertFalse(lowered.contains(entry.id))
        }
    }

    func testResultIsIndependentOfInputOrdering() {
        let entries = makeEntries(count: 8)
        let expected = RetentionPolicy.idsToEvict(entries: entries, limit: 3)
        let shuffled = RetentionPolicy.idsToEvict(entries: entries.shuffled(), limit: 3)
        XCTAssertEqual(shuffled, expected)
        XCTAssertEqual(expected.count, 5)
    }

    func testDefaultLimitIsFiveHundred() {
        XCTAssertEqual(RetentionPolicy.defaultLimit, 500)
        XCTAssertEqual(AppPreferences().historyLimit, 500)
    }

    func testHistoryLimitPreferenceDefaultsToFiveHundredAndPersists() {
        let name = "com.anoop.notchclip.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppPreferences.load(defaults: suite).historyLimit, 500)
        AppPreferences(historyLimit: RetentionPolicy.unlimited).save(defaults: suite)
        XCTAssertEqual(
            AppPreferences.load(defaults: suite).historyLimit,
            RetentionPolicy.unlimited
        )
    }

    /// Newest-first entries, one minute apart.
    private func makeEntries(
        count: Int,
        pinned: Bool = false,
        minuteOffset: Int = 0
    ) -> [ClipboardEntry] {
        (0..<count).map { index in
            let date = Date(
                timeIntervalSinceReferenceDate: 800_000_000 - Double(index + minuteOffset) * 60
            )
            return ClipboardEntry(
                createdAt: date,
                updatedAt: date,
                isPinned: pinned,
                primaryKind: .plainText,
                previewText: "entry-\(minuteOffset + index)",
                searchText: "entry-\(minuteOffset + index)",
                fingerprint: "fp-\(pinned ? "p" : "u")-\(minuteOffset + index)"
            )
        }
    }
}

final class RetentionEnforcementTests: XCTestCase {
    func testCaptureEvictsOldestAndRemovesPayloads() throws {
        let repository = InMemoryClipboardRepository()
        let payloadStore = RecordingPayloadStore()
        let engine = ClipboardEngine(repository: repository, payloadStore: payloadStore)
        engine.setHistoryLimit(3)

        var inserted: [ClipboardEntry] = []
        for index in 0..<5 {
            let result = engine.ingest(parsed: makeParsed(text: "clip-\(index)"))
            guard case .inserted(let entry) = result else {
                return XCTFail("expected insert, got \(result)")
            }
            inserted.append(entry)
        }

        let remaining = try repository.allEntries()
        XCTAssertEqual(remaining.count, 3)
        let removedIDs = Set(inserted.prefix(2).map(\.id))
        XCTAssertTrue(removedIDs.isDisjoint(with: Set(remaining.map(\.id))))
        // Eviction must clean payload bytes, never orphan them.
        XCTAssertEqual(payloadStore.removedEntryIDs, removedIDs)
    }

    func testPinnedSurviveCaptureEviction() throws {
        let repository = InMemoryClipboardRepository()
        let engine = ClipboardEngine(repository: repository, payloadStore: RecordingPayloadStore())
        engine.setHistoryLimit(1)

        guard case .inserted(let first) = engine.ingest(parsed: makeParsed(text: "keep-me")) else {
            return XCTFail("expected insert")
        }
        try engine.setPinned(id: first.id, isPinned: true)
        for index in 0..<4 {
            _ = engine.ingest(parsed: makeParsed(text: "clip-\(index)"))
        }

        let remaining = try repository.allEntries()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertTrue(remaining.contains { $0.id == first.id })
    }

    func testLoweringTheLimitPrunesImmediately() throws {
        let repository = InMemoryClipboardRepository()
        let engine = ClipboardEngine(repository: repository, payloadStore: RecordingPayloadStore())
        engine.setHistoryLimit(RetentionPolicy.unlimited)
        for index in 0..<6 {
            _ = engine.ingest(parsed: makeParsed(text: "clip-\(index)"))
        }
        XCTAssertEqual(try repository.allEntries().count, 6)

        engine.setHistoryLimit(2)
        XCTAssertEqual(try engine.enforceRetentionLimit(), 4)
        XCTAssertEqual(try repository.allEntries().count, 2)
        XCTAssertEqual(try engine.enforceRetentionLimit(), 0)
    }

    func testBulkPruneOnPersistentRepositoryKeepsNewest() throws {
        let repository = try PersistentClipboardRepository.temporary()
        let engine = ClipboardEngine(repository: repository, payloadStore: RecordingPayloadStore())
        engine.setHistoryLimit(RetentionPolicy.unlimited)
        for index in 0..<600 {
            _ = engine.ingest(parsed: makeParsed(text: "clip-\(index)"))
        }
        let before = try repository.sortedEntries()
        XCTAssertEqual(before.count, 600)

        engine.setHistoryLimit(100)
        XCTAssertEqual(try engine.enforceRetentionLimit(), 500)
        let after = try repository.sortedEntries()
        XCTAssertEqual(after.count, 100)
        XCTAssertEqual(after.map(\.id), Array(before.prefix(100)).map(\.id))
    }

    private func makeParsed(text: String) -> ParsedPasteboardItem {
        let type = ClipboardTypeIdentifiers.utf8PlainText
        let data = Data(text.utf8)
        return ParsedPasteboardItem(
            representations: [ParsedRepresentation(itemIndex: 0, typeIdentifier: type, data: data)],
            primaryKind: .plainText,
            previewText: text,
            searchText: text,
            fingerprint: Fingerprinter.fingerprint(typeIdentifier: type, data: data)
        )
    }
}

/// Payload store that records entry-directory removals without touching disk.
private final class RecordingPayloadStore: PayloadStoring, @unchecked Sendable {
    let rootDirectory = URL(fileURLWithPath: "/dev/null")
    private(set) var removedEntryIDs: Set<UUID> = []
    private let lock = NSLock()

    func store(entryID: UUID, representation: ParsedRepresentation) throws -> PayloadReference {
        PayloadReference(
            itemIndex: representation.itemIndex,
            typeIdentifier: representation.typeIdentifier,
            relativePath: "\(entryID.uuidString)/0",
            byteCount: representation.data.count
        )
    }

    func storeAll(entryID: UUID, representations: [ParsedRepresentation]) throws -> [PayloadReference] {
        try representations.map { try store(entryID: entryID, representation: $0) }
    }

    func loadData(for reference: PayloadReference) throws -> Data { Data() }

    func removeAll(for entryID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        removedEntryIDs.insert(entryID)
    }

    func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        removedEntryIDs.removeAll()
    }

    func storedEntryIDs() throws -> [UUID] { [] }

    func totalByteCount() throws -> Int { 0 }

    func entryDirectoryExists(entryID: UUID) -> Bool { false }

    func removeOrphansAndStaging(validEntryIDs: Set<UUID>) throws -> Int { 0 }
}
