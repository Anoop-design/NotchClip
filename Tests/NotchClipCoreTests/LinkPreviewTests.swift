import XCTest
@testable import NotchClipCore
import Foundation

final class LinkPreviewURLPolicyTests: XCTestCase {
    func testAcceptsHTTPAndHTTPS() {
        XCTAssertNotNil(LinkPreviewURLPolicy.canonicalHTTPURL(from: "https://Example.com/Path"))
        XCTAssertEqual(
            LinkPreviewURLPolicy.canonicalHTTPURL(from: "https://Example.com/Path")?.host,
            "example.com"
        )
        XCTAssertNotNil(LinkPreviewURLPolicy.canonicalHTTPURL(from: "http://foo.test/a"))
    }

    func testRejectsUnsafeSchemes() {
        XCTAssertNil(LinkPreviewURLPolicy.canonicalHTTPURL(from: "file:///tmp/x"))
        XCTAssertNil(LinkPreviewURLPolicy.canonicalHTTPURL(from: "javascript:alert(1)"))
        XCTAssertNil(LinkPreviewURLPolicy.canonicalHTTPURL(from: "data:text/html,hi"))
        XCTAssertNil(LinkPreviewURLPolicy.canonicalHTTPURL(from: "not a url"))
        XCTAssertNil(LinkPreviewURLPolicy.canonicalHTTPURL(from: "ftp://example.com"))
    }

    func testCacheKeyIsLowercaseSHA256Hex() {
        let u = LinkPreviewURLPolicy.canonicalHTTPURL(from: "https://a.example/x")!
        let key = LinkPreviewURLPolicy.cacheKey(for: u)
        XCTAssertTrue(LinkPreviewURLPolicy.isValidCacheKey(key))
        XCTAssertEqual(key, key.lowercased())
        XCTAssertEqual(key.count, 64)
        XCTAssertFalse(LinkPreviewURLPolicy.isValidCacheKey("ABC"))
        XCTAssertFalse(LinkPreviewURLPolicy.isValidCacheKey(String(repeating: "g", count: 64)))
    }

    func testSafeImagePath() {
        let key = String(repeating: "a", count: 64)
        XCTAssertEqual(LinkPreviewURLPolicy.imageRelativePath(forKey: key), "images/\(key).png")
        XCTAssertTrue(LinkPreviewURLPolicy.isSafeImageRelativePath("images/\(key).png", forKey: key))
        XCTAssertFalse(LinkPreviewURLPolicy.isSafeImageRelativePath("../etc/passwd", forKey: key))
        XCTAssertFalse(LinkPreviewURLPolicy.isSafeImageRelativePath("images/other.png", forKey: key))
    }
}

final class LinkPreviewCacheTests: XCTestCase {
    func testCacheHitAndCorruptionIsMiss() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root)
        let url = URL(string: "https://example.com/a")!
        let key = LinkPreviewURLPolicy.cacheKey(for: url)
        try cache.store(key: key, url: url, result: LinkMetadataResult(title: "Hello", imagePNGData: nil))
        XCTAssertEqual(cache.load(key: key)?.record.title, "Hello")

        // Corrupt disk while this instance may still hold memory — keep that instance as-is.
        let recURL = root.appendingPathComponent("\(key).json")
        try Data("{not-json".utf8).write(to: recURL)

        // First cache keeps memory hit; reopened instance must miss and clean up.
        XCTAssertEqual(cache.load(key: key)?.record.title, "Hello")
        let reopened = try LinkPreviewCache(rootDirectory: root)
        XCTAssertNil(reopened.load(key: key))
    }

    func testOversizeImageRejectedAtBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-over-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root)
        let url = URL(string: "https://example.com/big")!
        let key = LinkPreviewURLPolicy.cacheKey(for: url)
        let big = Data(repeating: 7, count: LinkPreviewURLPolicy.maxImageBytes + 1)
        try cache.store(
            key: key,
            url: url,
            result: LinkMetadataResult(title: "Big", imagePNGData: big)
        )
        let hit = cache.load(key: key)
        XCTAssertEqual(hit?.record.title, "Big")
        XCTAssertNil(hit?.imageData)
        XCTAssertNil(hit?.record.imageRelativePath)
    }

    func testUnsafeKeyRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-key-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root)
        XCTAssertNil(cache.load(key: "../evil"))
        XCTAssertNil(cache.load(key: "not-hex"))
    }

    func testClearRemovesRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root)
        let url = URL(string: "https://example.com/b")!
        let key = LinkPreviewURLPolicy.cacheKey(for: url)
        try cache.store(key: key, url: url, result: LinkMetadataResult(title: "B"))
        try cache.removeAll()
        XCTAssertEqual(cache.recordCountForTesting(), 0)
        XCTAssertNil(cache.load(key: key))
    }

    func testTTLEviction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root, ttlInterval: 0.05)
        let url = URL(string: "https://example.com/old")!
        let key = LinkPreviewURLPolicy.cacheKey(for: url)
        try cache.store(key: key, url: url, result: LinkMetadataResult(title: "Old"))
        // Warm memory so load hits the in-memory path (must still honor TTL).
        XCTAssertEqual(cache.load(key: key)?.record.title, "Old")
        XCTAssertGreaterThan(cache.memoryCountForTesting(), 0)
        // Expire without opening a fresh instance.
        let exp = expectation(description: "ttl")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertNil(cache.load(key: key))
        XCTAssertEqual(cache.memoryCountForTesting(), 0)
    }

    func testInMemoryTTLExpiryRemovesRecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-mem-ttl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root, ttlInterval: 0.04)
        let url = URL(string: "https://example.com/mem-ttl")!
        let key = LinkPreviewURLPolicy.cacheKey(for: url)
        try cache.store(key: key, url: url, result: LinkMetadataResult(title: "MemTTL"))
        // Warm memory, then corrupt disk so success cannot come from a disk re-read.
        XCTAssertEqual(cache.load(key: key)?.record.title, "MemTTL")
        XCTAssertEqual(cache.memoryCountForTesting(), 1)
        try Data("{not-json".utf8).write(to: root.appendingPathComponent("\(key).json"))
        let exp = expectation(description: "mem-ttl")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.07) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        // Same instance: expired memory hit must remove and return nil.
        XCTAssertNil(cache.load(key: key))
        XCTAssertEqual(cache.memoryCountForTesting(), 0)
    }

    func testCountEvictionWithTightLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-evict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root, maxRecordsLimit: 2)
        for i in 0..<3 {
            let url = URL(string: "https://example.com/e\(i)")!
            try cache.store(
                key: LinkPreviewURLPolicy.cacheKey(for: url),
                url: url,
                result: LinkMetadataResult(title: "E\(i)")
            )
        }
        XCTAssertLessThanOrEqual(cache.recordCountForTesting(), 2)
    }

    func testMemoryLRUBound() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-mem-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(
            rootDirectory: root,
            maxMemoryRecordsLimit: 2
        )
        for i in 0..<4 {
            let url = URL(string: "https://example.com/m\(i)")!
            try cache.store(
                key: LinkPreviewURLPolicy.cacheKey(for: url),
                url: url,
                result: LinkMetadataResult(title: "M\(i)")
            )
        }
        XCTAssertLessThanOrEqual(cache.memoryCountForTesting(), 2)
    }
}

/// Fake fetcher for unit tests — no network.
final class FakeLinkFetcher: LinkMetadataFetching, @unchecked Sendable {
    var results: [URL: LinkMetadataResult] = [:]
    var fetchCount: [URL: Int] = [:]
    var shouldThrow = false
    var gate: DispatchSemaphore?
    var released = DispatchSemaphore(value: 0)

    func fetch(url: URL) async throws -> LinkMetadataResult {
        fetchCount[url, default: 0] += 1
        if let gate {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    gate.wait()
                    cont.resume()
                }
            }
        }
        try Task.checkCancellation()
        if shouldThrow { throw URLError(.notConnectedToInternet) }
        return results[url] ?? LinkMetadataResult(title: "fake-\(url.host ?? "")")
    }
}

final class LinkPreviewServicePolicyTests: XCTestCase {
    @MainActor
    func testPreferenceOffDoesNotFetch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-svc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root)
        let fake = FakeLinkFetcher()
        let url = URL(string: "https://example.com/x")!
        fake.results[url] = LinkMetadataResult(title: "X")
        let service = LinkPreviewService(cache: cache, fetcher: fake)
        service.setEnabled(false)
        let entry = ClipboardEntry(
            primaryKind: .url,
            previewText: "https://example.com/x",
            searchText: "https://example.com/x",
            fingerprint: "u1"
        )
        service.requestVisible(entry: entry)
        XCTAssertEqual(fake.fetchCount[url] ?? 0, 0)
        XCTAssertEqual(service.visibleCount, 1)
    }

    @MainActor
    func testEnableOnlyRequestsCurrentlyVisible() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-vis-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root)
        let fake = FakeLinkFetcher()
        let service = LinkPreviewService(cache: cache, fetcher: fake)
        let visible = ClipboardEntry(
            primaryKind: .url,
            previewText: "https://example.com/visible",
            searchText: "https://example.com/visible",
            fingerprint: "v"
        )
        let hidden = ClipboardEntry(
            primaryKind: .url,
            previewText: "https://example.com/hidden",
            searchText: "https://example.com/hidden",
            fingerprint: "h"
        )
        service.setEnabled(false)
        service.requestVisible(entry: visible)
        service.requestVisible(entry: hidden)
        service.cancel(entryID: hidden.id)
        XCTAssertEqual(service.visibleCount, 1)

        let exp = expectation(description: "visible fetch")
        service.onUpdate = { id, _ in
            if id == visible.id { exp.fulfill() }
        }
        service.setEnabled(true)
        // Re-request only tracked visible rows after re-enable (service does not auto-fetch).
        service.requestVisible(entry: visible)
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(fake.fetchCount[URL(string: "https://example.com/visible")!] ?? 0, 1)
        XCTAssertEqual(fake.fetchCount[URL(string: "https://example.com/hidden")!] ?? 0, 0)
    }

    @MainActor
    func testPanelVisibilityGateBlocksAndResumesFetch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-panel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root)
        let fake = FakeLinkFetcher()
        let url = URL(string: "https://example.com/panel")!
        fake.results[url] = LinkMetadataResult(title: "Panel")
        let service = LinkPreviewService(cache: cache, fetcher: fake)
        let entry = ClipboardEntry(
            primaryKind: .url,
            previewText: "https://example.com/panel",
            searchText: "https://example.com/panel",
            fingerprint: "panel"
        )

        service.setPanelVisible(false)
        service.requestVisible(entry: entry)
        XCTAssertEqual(fake.fetchCount[url] ?? 0, 0)
        XCTAssertEqual(service.visibleCount, 1)
        XCTAssertFalse(service.isPanelVisible)

        let exp = expectation(description: "panel visible fetch")
        service.onUpdate = { id, result in
            XCTAssertEqual(id, entry.id)
            XCTAssertEqual(result.title, "Panel")
            exp.fulfill()
        }
        service.setPanelVisible(true)
        service.requestVisible(entry: entry, url: url)
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(fake.fetchCount[url] ?? 0, 1)
    }

    @MainActor
    func testRequestWithResolvedURLDoesNotUsePreviewText() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-exact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root)
        let fake = FakeLinkFetcher()
        let exact = URL(string: "https://example.com/full/path/that/is/not/in/preview")!
        fake.results[exact] = LinkMetadataResult(title: "Exact")
        let service = LinkPreviewService(cache: cache, fetcher: fake)
        // Truncated / different preview must not be used when exact URL is supplied.
        let entry = ClipboardEntry(
            primaryKind: .url,
            previewText: "https://example.com/trunc",
            searchText: "https://example.com/trunc",
            fingerprint: "exact"
        )
        let exp = expectation(description: "exact url fetch")
        service.onUpdate = { _, result in
            XCTAssertEqual(result.title, "Exact")
            exp.fulfill()
        }
        service.requestVisible(entry: entry, url: exact)
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(fake.fetchCount[exact] ?? 0, 1)
        XCTAssertEqual(fake.fetchCount[URL(string: "https://example.com/trunc")!] ?? 0, 0)
    }

    @MainActor
    func testSameURLDedupeFanoutAndCancelOneWaiter() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-dedupe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root)
        let fake = FakeLinkFetcher()
        let gate = DispatchSemaphore(value: 0)
        fake.gate = gate
        let url = URL(string: "https://example.com/shared")!
        fake.results[url] = LinkMetadataResult(title: "Shared")
        let service = LinkPreviewService(cache: cache, fetcher: fake)

        let a = ClipboardEntry(
            id: UUID(),
            primaryKind: .url,
            previewText: "https://example.com/shared",
            searchText: "https://example.com/shared",
            fingerprint: "a"
        )
        let b = ClipboardEntry(
            id: UUID(),
            primaryKind: .url,
            previewText: "https://example.com/shared",
            searchText: "https://example.com/shared",
            fingerprint: "b"
        )

        var got: Set<UUID> = []
        let exp = expectation(description: "fanout")
        exp.expectedFulfillmentCount = 1
        service.onUpdate = { id, result in
            XCTAssertEqual(result.title, "Shared")
            got.insert(id)
            if got.contains(b.id) { exp.fulfill() }
        }

        service.requestVisible(entry: a)
        service.requestVisible(entry: b)
        XCTAssertEqual(service.activeRequestCount, 1)
        // Cancel only A — shared fetch should continue for B.
        service.cancel(entryID: a.id)
        gate.signal()
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(fake.fetchCount[url] ?? 0, 1)
        XCTAssertNil(service.results[a.id])
        XCTAssertEqual(service.results[b.id]?.title, "Shared")
    }

    @MainActor
    func testCacheHitAvoidsSecondFetch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-svc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root)
        let fake = FakeLinkFetcher()
        let url = URL(string: "https://example.com/y")!
        fake.results[url] = LinkMetadataResult(title: "Y Title")
        let service = LinkPreviewService(cache: cache, fetcher: fake)
        let entry = ClipboardEntry(
            primaryKind: .url,
            previewText: "https://example.com/y",
            searchText: "https://example.com/y",
            fingerprint: "u2"
        )
        let exp = expectation(description: "first")
        service.onUpdate = { _, _ in exp.fulfill() }
        service.requestVisible(entry: entry)
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(fake.fetchCount[url] ?? 0, 1)

        let service2 = LinkPreviewService(cache: cache, fetcher: fake)
        let exp2 = expectation(description: "cache")
        service2.onUpdate = { _, result in
            XCTAssertEqual(result.title, "Y Title")
            exp2.fulfill()
        }
        service2.requestVisible(entry: entry)
        await fulfillment(of: [exp2], timeout: 2)
        XCTAssertEqual(fake.fetchCount[url] ?? 0, 1)
    }

    func testRowPresentationUsesLinkTitle() {
        let entry = ClipboardEntry(
            primaryKind: .url,
            previewText: "https://example.com/page",
            searchText: "https://example.com/page",
            fingerprint: "p"
        )
        XCTAssertEqual(EntryRowModel(entry: entry).primaryText, "example.com")
        XCTAssertEqual(EntryRowModel(entry: entry, linkTitle: "Example Page").primaryText, "Example Page")
    }

    @MainActor
    func testAsyncClearCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-svc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root)
        let fake = FakeLinkFetcher()
        let url = URL(string: "https://example.com/clear")!
        fake.results[url] = LinkMetadataResult(title: "ClearMe")
        let service = LinkPreviewService(cache: cache, fetcher: fake)
        let entry = ClipboardEntry(
            primaryKind: .url,
            previewText: "https://example.com/clear",
            searchText: "https://example.com/clear",
            fingerprint: "clr"
        )
        let exp = expectation(description: "loaded")
        service.onUpdate = { _, _ in exp.fulfill() }
        service.requestVisible(entry: entry)
        await fulfillment(of: [exp], timeout: 2)
        try await service.clearCache()
        XCTAssertTrue(service.results.isEmpty)
        XCTAssertEqual(cache.recordCountForTesting(), 0)
    }

    @MainActor
    func testPanelVisibilityGateCancelsInFlightAndBlocksPublish() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lp-panel-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try LinkPreviewCache(rootDirectory: root)
        let fake = FakeLinkFetcher()
        let gate = DispatchSemaphore(value: 0)
        fake.gate = gate
        let url = URL(string: "https://example.com/panel-cancel")!
        fake.results[url] = LinkMetadataResult(title: "CancelMe")
        let service = LinkPreviewService(cache: cache, fetcher: fake)
        let entry = ClipboardEntry(
            primaryKind: .url,
            previewText: "https://example.com/panel-cancel",
            searchText: "https://example.com/panel-cancel",
            fingerprint: "pc"
        )

        service.setPanelVisible(true)
        service.requestVisible(entry: entry, url: url)
        XCTAssertEqual(service.activeRequestCount, 1)

        var published = false
        service.onUpdate = { _, _ in published = true }
        service.setPanelVisible(false)
        gate.signal()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(published)
        XCTAssertNil(service.results[entry.id])
        XCTAssertEqual(service.activeRequestCount, 0)
    }
}

final class RetainedWebURLTests: XCTestCase {
    func testExactLongMixedCasePublicURLRoundTrip() throws {
        let engine = ClipboardEngine(
            repository: InMemoryClipboardRepository(),
            payloadStore: InMemoryPayloadStore()
        )
        // >200 chars, mixed case path/query — must not use truncated previewText.
        let longPath = String(repeating: "Ab", count: 120) // 240 chars
        let original =
            "https://Example.COM/MixedCase/\(longPath)?Q=Value&x=\(String(repeating: "Zz", count: 20))"
        XCTAssertGreaterThan(original.count, 200)
        let data = Data(original.utf8)
        let reps = [
            ParsedRepresentation(
                itemIndex: 0,
                typeIdentifier: ClipboardTypeIdentifiers.url,
                data: data
            )
        ]
        let preview = String(original.prefix(200))
        XCTAssertEqual(preview.count, 200)
        XCTAssertNotEqual(preview, original)
        let parsed = ParsedPasteboardItem(
            representations: reps,
            primaryKind: .url,
            previewText: preview,
            searchText: original.lowercased(),
            fingerprint: Fingerprinter.fingerprint(representations: reps)
        )
        guard case .inserted(let entry) = engine.ingest(parsed: parsed) else {
            return XCTFail("insert")
        }
        // previewText is truncated; retainedWebURL must recover full original.
        XCTAssertEqual(entry.previewText.count, 200)
        let resolved = engine.retainedWebURL(for: entry)
        XCTAssertNotNil(resolved)
        let expected = LinkPreviewURLPolicy.canonicalHTTPURL(from: original)
        XCTAssertEqual(resolved, expected)
        XCTAssertEqual(resolved?.host, "example.com")
        // Must not equal a key derived from the truncated preview alone when path differs.
        let truncatedCanonical = LinkPreviewURLPolicy.canonicalHTTPURL(from: entry.previewText)
        XCTAssertNotEqual(resolved?.absoluteString, truncatedCanonical?.absoluteString)
    }

    func testRetainedWebURLRejectsUnsafeScheme() throws {
        let engine = ClipboardEngine(
            repository: InMemoryClipboardRepository(),
            payloadStore: InMemoryPayloadStore()
        )
        let cases = [
            "file:///tmp/secret",
            "javascript:alert(1)",
            "data:text/html,hi",
            "ftp://example.com/a"
        ]
        for raw in cases {
            let data = Data(raw.utf8)
            let reps = [
                ParsedRepresentation(
                    itemIndex: 0,
                    typeIdentifier: ClipboardTypeIdentifiers.url,
                    data: data
                )
            ]
            let parsed = ParsedPasteboardItem(
                representations: reps,
                primaryKind: .url,
                previewText: String(raw.prefix(200)),
                searchText: raw.lowercased(),
                fingerprint: Fingerprinter.fingerprint(representations: reps)
            )
            guard case .inserted(let entry) = engine.ingest(parsed: parsed) else {
                return XCTFail("insert \(raw)")
            }
            XCTAssertNil(engine.retainedWebURL(for: entry), raw)
        }
    }

    func testRetainedWebURLIgnoresNonURLPayloadFallback() throws {
        let engine = ClipboardEngine(
            repository: InMemoryClipboardRepository(),
            payloadStore: InMemoryPayloadStore()
        )
        // Only plain text — must not fall back via loadPayloadData.
        let reps = [
            ParsedRepresentation(
                itemIndex: 0,
                typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText,
                data: Data("https://example.com/from-text".utf8)
            )
        ]
        let parsed = ParsedPasteboardItem(
            representations: reps,
            primaryKind: .url,
            previewText: "https://example.com/from-text",
            searchText: "https://example.com/from-text",
            fingerprint: Fingerprinter.fingerprint(representations: reps)
        )
        guard case .inserted(let entry) = engine.ingest(parsed: parsed) else {
            return XCTFail("insert")
        }
        XCTAssertNil(engine.retainedWebURL(for: entry))
    }
}
