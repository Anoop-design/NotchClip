import Foundation
import AppKit

/// Provides source app metadata for a capture. Default excludes NotchClip itself.
public typealias SourceMetadataProvider = @Sendable () -> SourceMetadata

/// Default source: frontmost external application (never reports NotchClip as source).
public enum ClipboardSourceProvider {
    public static func frontmostExternalApplication(
        excludingBundleIDs: Set<String> = []
    ) -> SourceMetadata {
        var excluded = excludingBundleIDs
        if let own = Bundle.main.bundleIdentifier {
            excluded.insert(own)
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return SourceMetadata()
        }
        if let bid = app.bundleIdentifier, excluded.contains(bid) {
            return SourceMetadata()
        }
        return SourceMetadata(
            bundleIdentifier: app.bundleIdentifier,
            applicationName: app.localizedName
        )
    }
}

/// Pure grouping of payload refs / parsed reps for pasteboard write-back and drag.
/// Groups by ascending `itemIndex` while preserving first-seen representation order within each item.
public enum PasteboardItemGrouping {
    /// Stable groups: ascending item index; within each item, input array order (not UTI-sorted).
    public static func groupPayloadRefs(_ refs: [PayloadReference]) -> [(itemIndex: Int, refs: [PayloadReference])] {
        let loadable = refs.filter { !$0.relativePath.isEmpty }
        guard !loadable.isEmpty else { return [] }

        var byIndex: [Int: [PayloadReference]] = [:]
        var firstSeenOrder: [Int] = []
        var seenIndex = Set<Int>()
        for ref in loadable {
            if !seenIndex.contains(ref.itemIndex) {
                seenIndex.insert(ref.itemIndex)
                firstSeenOrder.append(ref.itemIndex)
            }
            byIndex[ref.itemIndex, default: []].append(ref)
        }
        // Ascending itemIndex for multi-item topology; preserve array order within each group.
        let indices = firstSeenOrder.sorted()
        return indices.map { (itemIndex: $0, refs: byIndex[$0] ?? []) }
    }

    public static func groupRepresentations(
        _ representations: [ParsedRepresentation]
    ) -> [(itemIndex: Int, reps: [ParsedRepresentation])] {
        guard !representations.isEmpty else { return [] }
        var byIndex: [Int: [ParsedRepresentation]] = [:]
        var firstSeenOrder: [Int] = []
        var seenIndex = Set<Int>()
        for rep in representations {
            if !seenIndex.contains(rep.itemIndex) {
                seenIndex.insert(rep.itemIndex)
                firstSeenOrder.append(rep.itemIndex)
            }
            byIndex[rep.itemIndex, default: []].append(rep)
        }
        let indices = firstSeenOrder.sorted()
        return indices.map { (itemIndex: $0, reps: byIndex[$0] ?? []) }
    }
}

/// Writes retained representations back onto the pasteboard, preserving item topology.
public struct PasteboardWriter: Sendable {
    public init() {}

    /// Build pasteboard items from stored payloads without clearing any pasteboard.
    /// Groups by ascending `itemIndex` and preserves representation array order within each item.
    /// Throws if a loadable ref fails.
    public func makePasteboardItems(
        entry: ClipboardEntry,
        payloadStore: any PayloadStoring
    ) throws -> [NSPasteboardItem] {
        let grouped = PasteboardItemGrouping.groupPayloadRefs(entry.payloadRefs)
        guard !grouped.isEmpty else { return [] }

        var items: [NSPasteboardItem] = []
        for (_, itemRefs) in grouped {
            let pbItem = NSPasteboardItem()
            var any = false
            for ref in itemRefs {
                let data = try payloadStore.loadData(for: ref)
                if pbItem.setData(data, forType: NSPasteboard.PasteboardType(ref.typeIdentifier)) {
                    any = true
                }
            }
            if any {
                items.append(pbItem)
            }
        }
        return items
    }

    /// Build lazy pasteboard items that load payload bytes only when a type is requested.
    /// Does not read payload Data; does not touch the general pasteboard.
    public func makeLazyPasteboardItems(
        entry: ClipboardEntry,
        engine: ClipboardEngine
    ) -> (items: [NSPasteboardItem], providers: [LazyDragPayloadProvider]) {
        let grouped = PasteboardItemGrouping.groupPayloadRefs(entry.payloadRefs)
        guard !grouped.isEmpty else { return ([], []) }

        var items: [NSPasteboardItem] = []
        var providers: [LazyDragPayloadProvider] = []
        for (_, itemRefs) in grouped {
            let types = itemRefs.map(\.typeIdentifier)
            guard !types.isEmpty else { continue }
            let provider = LazyDragPayloadProvider(engine: engine, refs: itemRefs)
            let pbItem = NSPasteboardItem()
            pbItem.setDataProvider(
                provider,
                forTypes: types.map { NSPasteboard.PasteboardType($0) }
            )
            items.append(pbItem)
            providers.append(provider)
        }
        return (items, providers)
    }

    @discardableResult
    public func write(
        entry: ClipboardEntry,
        payloadStore: any PayloadStoring,
        pasteboard: NSPasteboard = .general
    ) throws -> Int {
        let items = try makePasteboardItems(entry: entry, payloadStore: payloadStore)
        guard !items.isEmpty else { return 0 }
        pasteboard.clearContents()
        let ok = pasteboard.writeObjects(items)
        return ok ? items.count : 0
    }

    @discardableResult
    public func write(
        representations: [ParsedRepresentation],
        pasteboard: NSPasteboard = .general
    ) -> Int {
        let grouped = PasteboardItemGrouping.groupRepresentations(representations)
        var items: [NSPasteboardItem] = []
        for (_, reps) in grouped {
            let pbItem = NSPasteboardItem()
            var any = false
            for rep in reps {
                if pbItem.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.typeIdentifier)) {
                    any = true
                }
            }
            if any { items.append(pbItem) }
        }
        guard !items.isEmpty else { return 0 }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items) ? items.count : 0
    }
}

/// AppKit lazy pasteboard provider: maps requested UTI → exact `PayloadReference`, loads on demand.
/// Never touches or clears the general pasteboard. Load failures omit that flavor only.
public final class LazyDragPayloadProvider: NSObject, NSPasteboardItemDataProvider {
    private let engine: ClipboardEngine
    /// typeIdentifier → exact ref for this item.
    private let refsByType: [String: PayloadReference]

    public init(engine: ClipboardEngine, refs: [PayloadReference]) {
        self.engine = engine
        var map: [String: PayloadReference] = [:]
        for ref in refs {
            // First-seen wins (preserves source order; no overwrite of earlier identical UTI).
            if map[ref.typeIdentifier] == nil {
                map[ref.typeIdentifier] = ref
            }
        }
        self.refsByType = map
        super.init()
    }

    public var declaredTypes: [String] { Array(refsByType.keys) }

    public func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        let typeID = type.rawValue
        guard let ref = refsByType[typeID] else { return }
        guard let data = try? engine.loadPayloadData(for: ref) else { return }
        item.setData(data, forType: type)
    }
}

/// Pure coalescing decisions for the background capture monitor (unit-testable).
public enum CaptureCoalescing {
    /// Whether a new `changeCount` should start a capture job.
    public static func shouldStartCapture(
        changeCount: Int,
        lastProcessed: Int,
        isPaused: Bool,
        isInFlight: Bool
    ) -> Bool {
        guard !isPaused else { return false }
        guard !isInFlight else { return false }
        return changeCount != lastProcessed
    }

    /// While a job is in flight, mark pending if the board advanced again.
    public static func pendingAfterObservation(
        changeCount: Int,
        inFlightTarget: Int?,
        isInFlight: Bool
    ) -> Int? {
        guard isInFlight, let target = inFlightTarget, changeCount != target else { return nil }
        return changeCount
    }

    /// After a job completes for `completedTarget`, whether to immediately start another for `pending`.
    public static func shouldRecapture(pending: Int?, completedTarget: Int) -> Bool {
        guard let pending else { return false }
        return pending != completedTarget
    }
}

/// Polls pasteboard change count on the main run loop.
/// Snapshots types/bytes + source metadata on main, then parse/persist on a private serial queue.
@MainActor
@Observable
public final class ClipboardMonitor {
    public private(set) var isPaused: Bool = false
    /// Last change count fully processed (or intentionally skipped while paused).
    public private(set) var lastChangeCount: Int
    public private(set) var lastCaptureResult: CaptureResult?
    public private(set) var isCaptureInFlight: Bool = false
    /// When non-nil, a newer change arrived during an in-flight capture.
    public private(set) var pendingChangeCount: Int?

    /// Invoked on the main actor after each capture result so UI models can refresh.
    public var onCapture: ((CaptureResult) -> Void)?

    public let engine: ClipboardEngine
    private var timer: Timer?
    private let pasteboard: NSPasteboard
    private let pollInterval: TimeInterval
    /// Private serial executor for parse + engine persistence (never mutate UI here).
    private let captureQueue = DispatchQueue(label: "com.anoop.notchclip.capture")
    private var inFlightTarget: Int?

    public init(
        engine: ClipboardEngine,
        pasteboard: NSPasteboard = .general,
        pollInterval: TimeInterval = 0.35
    ) {
        self.engine = engine
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        self.lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        stopTimer()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        stopTimer()
    }

    public func pause() {
        isPaused = true
    }

    public func resume() {
        isPaused = false
        // Skip backlog generated while paused.
        lastChangeCount = pasteboard.changeCount
        pendingChangeCount = nil
    }

    public func togglePause() {
        if isPaused { resume() } else { pause() }
    }

    /// Observe changeCount on main; snapshot then schedule at most one background job.
    @discardableResult
    public func poll() -> CaptureResult? {
        let count = pasteboard.changeCount
        if isPaused {
            return nil
        }
        if isCaptureInFlight {
            if let pending = CaptureCoalescing.pendingAfterObservation(
                changeCount: count,
                inFlightTarget: inFlightTarget,
                isInFlight: true
            ) {
                pendingChangeCount = pending
            }
            return nil
        }
        guard CaptureCoalescing.shouldStartCapture(
            changeCount: count,
            lastProcessed: lastChangeCount,
            isPaused: false,
            isInFlight: false
        ) else {
            return nil
        }
        startCapture(targetCount: count)
        return nil
    }

    /// Synchronous capture for tests that need an immediate result on the calling queue.
    @discardableResult
    public func pollSynchronouslyForTesting() -> CaptureResult? {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return nil }
        lastChangeCount = count
        guard !isPaused else { return nil }
        let result = engine.capture(from: pasteboard)
        lastCaptureResult = result
        onCapture?(result)
        return result
    }

    private func startCapture(targetCount: Int) {
        // Main-actor snapshot: full item topology + source metadata.
        // Use the snapshot's own changeCount as the generation (board may have moved).
        let source = engine.sourceProvider()
        let snapshot = PasteboardSnapshotter.snapshot(
            pasteboard: pasteboard,
            source: source,
            maxRepresentationBytes: engine.parser.maxRepresentationBytes,
            maxTotalRetainedBytes: PasteboardSnapshotter.defaultTotalRetainedBytes
        )

        // Inconsistent snapshot: board moved mid-read — retry newest generation, do not ingest.
        if !snapshot.isConsistent {
            pendingChangeCount = pasteboard.changeCount
            DispatchQueue.main.async { [weak self] in
                self?.poll()
            }
            return
        }

        let generation = snapshot.changeCount
        let live = pasteboard.changeCount
        if live != generation {
            pendingChangeCount = live
        } else {
            pendingChangeCount = nil
        }

        isCaptureInFlight = true
        inFlightTarget = generation

        let engine = self.engine
        captureQueue.async { [weak self] in
            let result = engine.ingest(snapshot: snapshot)
            DispatchQueue.main.async {
                self?.finishCapture(result: result, completedTarget: generation)
            }
        }
        _ = targetCount
    }

    private func finishCapture(result: CaptureResult, completedTarget: Int) {
        isCaptureInFlight = false
        inFlightTarget = nil
        lastChangeCount = completedTarget
        lastCaptureResult = result
        onCapture?(result)

        let live = pasteboard.changeCount
        var pending = pendingChangeCount
        if live != completedTarget {
            pending = live
        }
        pendingChangeCount = nil
        if CaptureCoalescing.shouldRecapture(pending: pending, completedTarget: completedTarget),
           let pending,
           !isPaused {
            startCapture(targetCount: pending)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// Core capture, dedupe, search, and write-back orchestration.
///
/// Compound mutations (ingest / paste / delete / clear) are serialized with a private lock
/// so concurrent same-fingerprint ingests cannot insert duplicates. This is v1 mutual
/// exclusion, not a Swift 6 actor model.
public final class ClipboardEngine: @unchecked Sendable {
    public let repository: any ClipboardRepository
    public let payloadStore: any PayloadStoring
    public let parser: PasteboardParser
    public let writer: PasteboardWriter
    public var sourceProvider: SourceMetadataProvider

    private let operationLock = NSLock()
    /// One-shot self-write token: ignore this exact change count once, then clear.
    private var suppressedChangeCount: Int?

    public init(
        repository: any ClipboardRepository,
        payloadStore: any PayloadStoring,
        parser: PasteboardParser = PasteboardParser(),
        writer: PasteboardWriter = PasteboardWriter(),
        sourceProvider: @escaping SourceMetadataProvider = {
            ClipboardSourceProvider.frontmostExternalApplication()
        }
    ) {
        self.repository = repository
        self.payloadStore = payloadStore
        self.parser = parser
        self.writer = writer
        self.sourceProvider = sourceProvider
    }

    // MARK: - Capture

    /// Synchronous live-board capture for deterministic tests. Production monitor uses snapshots.
    @discardableResult
    public func capture(
        from pasteboard: NSPasteboard = .general,
        source: SourceMetadata? = nil
    ) -> CaptureResult {
        let resolvedSource = source ?? sourceProvider()
        let snapshot = PasteboardSnapshotter.snapshot(
            pasteboard: pasteboard,
            source: resolvedSource,
            maxRepresentationBytes: parser.maxRepresentationBytes
        )
        return ingest(snapshot: snapshot)
    }

    /// Ingest an immutable snapshot (production background path). Applies one-shot self-write suppression.
    /// Inconsistent snapshots (board mutated mid-read) must not be ingested by the caller.
    @discardableResult
    public func ingest(snapshot: PasteboardSnapshot) -> CaptureResult {
        guard snapshot.isConsistent else {
            return .ignoredEmpty
        }

        operationLock.lock()
        if let suppressed = suppressedChangeCount, suppressed == snapshot.changeCount {
            suppressedChangeCount = nil
            operationLock.unlock()
            return .ignoredSelfWrite
        }
        operationLock.unlock()

        if parser.shouldReject(types: snapshot.boardTypes) {
            return .ignoredTransient
        }
        for item in snapshot.items where parser.shouldReject(types: item.types) {
            return .ignoredTransient
        }

        guard let parsed = parser.parse(snapshot: snapshot) else {
            return .ignoredEmpty
        }
        return ingest(parsed: parsed)
    }

    /// Eager drag pasteboard items (loads all payload bytes). Prefer `makeLazyDraggingItems` for UI drags.
    public func makeDraggingItems(for entry: ClipboardEntry) throws -> [NSPasteboardItem] {
        try writer.makePasteboardItems(entry: entry, payloadStore: payloadStore)
    }

    /// Lazy drag pasteboard items: metadata/types only until AppKit requests a flavor.
    /// Does not load payload Data; does not touch the general pasteboard.
    public func makeLazyDraggingItems(
        for entry: ClipboardEntry
    ) -> (items: [NSPasteboardItem], providers: [LazyDragPayloadProvider]) {
        writer.makeLazyPasteboardItems(entry: entry, engine: self)
    }

    /// Load one exact retained payload reference (lazy drag provider path).
    public func loadPayloadData(for reference: PayloadReference) throws -> Data {
        try payloadStore.loadData(for: reference)
    }

    @discardableResult
    public func ingest(parsed: ParsedPasteboardItem) -> CaptureResult {
        operationLock.lock()
        defer { operationLock.unlock() }
        return ingestLocked(parsed: parsed)
    }

    private func ingestLocked(parsed: ParsedPasteboardItem) -> CaptureResult {
        do {
            let existing = try repository.allEntries().first { $0.fingerprint == parsed.fingerprint }
            if var match = existing {
                match.updatedAt = .now
                match.previewText = parsed.previewText
                match.searchText = parsed.searchText
                match.source = parsed.source
                do {
                    try repository.upsert(match)
                    return .updatedExisting(match)
                } catch {
                    return .failed(.repository(String(describing: error)))
                }
            }

            let id = UUID()
            let refs: [PayloadReference]
            do {
                refs = try payloadStore.storeAll(entryID: id, representations: parsed.representations)
            } catch {
                return .failed(.payload(String(describing: error)))
            }

            let entry = ClipboardEntry(
                id: id,
                createdAt: .now,
                updatedAt: .now,
                isPinned: false,
                source: parsed.source,
                primaryKind: parsed.primaryKind,
                previewText: parsed.previewText,
                searchText: parsed.searchText,
                fingerprint: parsed.fingerprint,
                payloadRefs: refs
            )
            do {
                try repository.upsert(entry)
                return .inserted(entry)
            } catch {
                // Metadata failed after payloads landed — remove payload directory.
                try? payloadStore.removeAll(for: id)
                return .failed(.repository(String(describing: error)))
            }
        } catch {
            return .failed(.unknown(String(describing: error)))
        }
    }

    // MARK: - Mutations

    public func setPinned(id: UUID, isPinned: Bool) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard var entry = try repository.entry(id: id) else {
            throw ClipboardRepositoryError.notFound
        }
        entry.isPinned = isPinned
        entry.updatedAt = .now
        try repository.upsert(entry)
    }

    /// Remove metadata first so a failed payload delete never leaves a live broken row.
    public func delete(id: UUID) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try repository.remove(id: id)
        try? payloadStore.removeAll(for: id)
    }

    /// Deletes all unpinned entries; pinned entries remain. Surfaces payload cleanup failures.
    public func clearUnpinned() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let entries = try repository.allEntries()
        var payloadError: Error?
        for entry in entries where !entry.isPinned {
            try repository.remove(id: entry.id)
            do {
                try payloadStore.removeAll(for: entry.id)
            } catch {
                payloadError = error
            }
        }
        if let payloadError { throw payloadError }
    }

    /// Deletes every history entry and cleans published + staging/orphan payload dirs.
    /// Does not touch original source files outside the payload store root.
    public func clearAll() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let entries = try repository.allEntries()
        let ids = entries.map(\.id)
        try repository.removeAll()
        var firstError: Error?
        for id in ids {
            do {
                try payloadStore.removeAll(for: id)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        // Always scrub orphans/staging under the store root.
        do {
            _ = try payloadStore.removeOrphansAndStaging(validEntryIDs: [])
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    public func sortedEntries() throws -> [ClipboardEntry] {
        try repository.sortedEntries()
    }

    public func search(query: String) throws -> [ClipboardEntry] {
        try repository.search(query: query)
    }

    public func entryCount() throws -> Int {
        try repository.allEntries().count
    }

    public func totalPayloadByteCount() throws -> Int {
        try payloadStore.totalByteCount()
    }

    public func storageStats(applicationSupportPath: String) throws -> StorageStats {
        try StorageStats(
            itemCount: entryCount(),
            payloadBytes: totalPayloadByteCount(),
            applicationSupportPath: applicationSupportPath
        )
    }

    /// Load retained representation data for previews (caller caches; never call from SwiftUI body).
    public func loadPayloadData(for entry: ClipboardEntry, preferring types: [String]) throws -> (type: String, data: Data)? {
        for type in types {
            if let ref = entry.payloadRefs.first(where: { $0.typeIdentifier == type && !$0.relativePath.isEmpty }) {
                let data = try payloadStore.loadData(for: ref)
                return (type, data)
            }
        }
        if let ref = entry.payloadRefs.first(where: { !$0.relativePath.isEmpty }) {
            let data = try payloadStore.loadData(for: ref)
            return (ref.typeIdentifier, data)
        }
        return nil
    }

    /// Exact retained `public.url` → canonical http/https URL for link previews.
    ///
    /// Loads **only** the `public.url` payload (no arbitrary type fallback). Decodes original
    /// URL data / UTF-8 bytes without case changes or truncation, then validates/canonicalizes
    /// via `LinkPreviewURLPolicy`. Background-safe (no main-thread or pasteboard access).
    public func retainedWebURL(for entry: ClipboardEntry) -> URL? {
        guard let ref = entry.payloadRefs.first(where: {
            $0.typeIdentifier == ClipboardTypeIdentifiers.url && !$0.relativePath.isEmpty
        }) else {
            return nil
        }
        let data: Data
        do {
            data = try payloadStore.loadData(for: ref)
        } catch {
            return nil
        }
        guard !data.isEmpty else { return nil }

        // Prefer full original string bytes (no truncation / case fold here).
        if let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16) {
            let cleaned = raw
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = LinkPreviewURLPolicy.canonicalHTTPURL(from: cleaned) {
                return url
            }
        }
        // Binary NSURL absolute-URL data representation.
        if let nsURL = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL? {
            return LinkPreviewURLPolicy.canonicalHTTPURL(from: nsURL.absoluteString)
        }
        return nil
    }

    /// Remove payload directories with no metadata + leftover staging dirs.
    @discardableResult
    public func removeOrphanedPayloads() throws -> Int {
        operationLock.lock()
        defer { operationLock.unlock() }
        let valid = Set(try repository.allEntries().map(\.id))
        return try payloadStore.removeOrphansAndStaging(validEntryIDs: valid)
    }

    /// Write entry back to pasteboard. On success, suppress the resulting change count once.
    @discardableResult
    public func paste(
        entry: ClipboardEntry,
        pasteboard: NSPasteboard = .general
    ) throws -> Int {
        operationLock.lock()
        defer { operationLock.unlock() }
        let written = try writer.write(entry: entry, payloadStore: payloadStore, pasteboard: pasteboard)
        if written > 0 {
            suppressedChangeCount = pasteboard.changeCount
        }
        return written
    }
}
