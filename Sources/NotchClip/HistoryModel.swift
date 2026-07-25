import Foundation
import AppKit
import NotchClipCore

/// Main-actor history snapshot for the panel and menu.
@MainActor
@Observable
final class HistoryModel {
    private(set) var entries: [ClipboardEntry] = [] {
        didSet { entriesRevision &+= 1 }
    }
    /// Monotonic identity for the current history snapshot. Views can invalidate
    /// cached projections without equality-scanning an indefinitely large archive.
    private(set) var entriesRevision: UInt64 = 0
    var query: String = "" {
        didSet { recomputeSelectionIfNeeded() }
    }
    var selectedID: UUID?
    private(set) var storageError: String?
    private(set) var captureError: String?
    private(set) var isPaused: Bool = false
    private(set) var lastCaptureResult: CaptureResult?
    private(set) var storageStats: StorageStats?
    private(set) var preferences: AppPreferences = .load()

    private weak var engine: ClipboardEngine?
    private var supportRootPath: String = ""
    /// Serial repository / history mutations (refresh, pin, delete, clear). Never paste.
    private let repositoryQueue = DispatchQueue(label: "com.anoop.notchclip.history.repository")
    /// Dedicated serial queue for user-initiated selection paste (must not wait on thumbnails).
    private let pasteQueue = DispatchQueue(label: "com.anoop.notchclip.history.paste", qos: .userInitiated)
    /// Bounded utility work for thumbnails / file icons (max 2 concurrent).
    private let previewQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.anoop.notchclip.history.preview"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()
    private var refreshGeneration: UInt64 = 0

    /// Cached previews keyed by entry id (thumbnails / resolved icons). Not read in body construction beyond lookup.
    private(set) var previewCache: [UUID: EntryPreview] = [:]
    private var previewRequestsInFlight: Set<UUID> = []

    /// Link preview coordinator (optional until attached).
    private(set) var linkPreviews: LinkPreviewService?

    /// True while the notch panel is ordered in / presenting (not merely row-visible).
    private(set) var isPanelVisible: Bool = false
    /// True while the searchable history library is ordered in.
    private(set) var isLibraryVisible: Bool = false

    private var isPreviewSurfaceVisible: Bool {
        isPanelVisible || isLibraryVisible
    }

    /// True while a user-initiated paste is running (single-flight gate).
    private(set) var isPasteInFlight: Bool = false

    /// URL entries currently visible in the panel (for re-request when previews re-enabled).
    private var visibleLinkEntries: [UUID: ClipboardEntry] = [:]

    /// Bumped on panel hide / preference-off so stale resolve completions drop.
    private var linkResolveGeneration: UInt64 = 0

    /// Dedicated utility queue for retained `public.url` resolution (never main / never preview queue).
    private let linkURLQueue = DispatchQueue(label: "com.anoop.notchclip.link-url", qos: .utility)

    var sections: HistorySections {
        HistoryQuery.sections(from: entries, query: query)
    }

    var pinned: [ClipboardEntry] { sections.pinned }
    var recent: [ClipboardEntry] { sections.recent }
    var isEmpty: Bool { sections.isEmpty }

    /// The bounded working set shown by the notch. The complete archive remains
    /// available to the library window.
    var quickShelf: [ClipboardEntry] {
        QuickShelfPolicy.entries(from: entries)
    }

    var rowModels: [EntryRowModel] {
        sections.allInDisplayOrder.map { entry in
            let link = linkPreviews?.results[entry.id]
            return EntryRowModel(entry: entry, linkTitle: link?.title)
        }
    }

    func attach(engine: ClipboardEngine?, supportRoot: URL?) {
        self.engine = engine
        self.supportRootPath = supportRoot?.path ?? ""
        if linkPreviews == nil {
            if let root = try? LinkPreviewCache.defaultRoot(),
               let cache = try? LinkPreviewCache(rootDirectory: root) {
                let service = LinkPreviewService(cache: cache, fetcher: LPMetadataFetcher())
                service.setPanelVisible(isPreviewSurfaceVisible)
                service.setEnabled(preferences.fetchLinkPreviews)
                service.onUpdate = { [weak self] id, result in
                    self?.applyLinkPreview(entryID: id, result: result)
                }
                linkPreviews = service
            }
        }
    }

    /// Test seam: inject link preview service.
    func attachLinkPreviews(_ service: LinkPreviewService) {
        service.onUpdate = { [weak self] id, result in
            self?.applyLinkPreview(entryID: id, result: result)
        }
        service.setPanelVisible(isPreviewSurfaceVisible)
        service.setEnabled(preferences.fetchLinkPreviews)
        linkPreviews = service
    }

    private func applyLinkPreview(entryID: UUID, result: LinkMetadataResult) {
        guard isPreviewSurfaceVisible else { return }
        guard visibleLinkEntries[entryID] != nil else { return }
        var preview = previewCache[entryID] ?? EntryPreview()
        if let title = result.title, !title.isEmpty {
            preview.linkTitle = title
        }
        if let data = result.imagePNGData, let image = NSImage(data: data) {
            preview.thumbnail = image
        }
        previewCache[entryID] = preview
    }

    func rowBecameVisible(_ entry: ClipboardEntry) {
        requestPreview(for: entry)
        if entry.primaryKind == .url {
            visibleLinkEntries[entry.id] = entry
        }
        resolveAndRequestLinkPreview(entry)
    }

    func rowDidDisappear(_ entryID: UUID) {
        visibleLinkEntries.removeValue(forKey: entryID)
        linkPreviews?.cancel(entryID: entryID)
    }

    /// Panel ordered-in/out gate. Hosting view keeps rows mounted, so row onDisappear
    /// alone cannot stop fetches when the notch orders out.
    func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
        if visible {
            // The notch may be opened after the library left selection on an
            // archive row that is not part of the bounded shelf.
            prepareQuickShelfSelection()
        }
        updatePreviewSurfaceVisibility()
    }

    func setLibraryVisible(_ visible: Bool) {
        isLibraryVisible = visible
        updatePreviewSurfaceVisibility()
    }

    private func updatePreviewSurfaceVisibility() {
        let visible = isPreviewSurfaceVisible
        linkResolveGeneration &+= 1
        linkPreviews?.setPanelVisible(visible)
        if !visible {
            linkPreviews?.cancelAll()
            return
        }
        guard preferences.fetchLinkPreviews else { return }
        for entry in visibleLinkEntries.values {
            resolveAndRequestLinkPreview(entry)
        }
    }

    func setCaptureError(_ message: String?) {
        captureError = message
    }

    func clearCaptureError() {
        captureError = nil
    }

    func setStorageError(_ message: String?) {
        storageError = message
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    func setFetchLinkPreviews(_ enabled: Bool) {
        preferences.fetchLinkPreviews = enabled
        preferences.save()
        if !enabled {
            linkResolveGeneration &+= 1
            linkPreviews?.setEnabled(false)
            stripNetworkDerivedURLPreviews()
        } else {
            linkPreviews?.setEnabled(true)
            // Preference re-enable requests only if panel is visible, and only tracked rows.
            guard isPreviewSurfaceVisible else { return }
            for entry in visibleLinkEntries.values {
                resolveAndRequestLinkPreview(entry)
            }
        }
    }

    /// Resolve exact retained `public.url` off main, then request with that URL only.
    private func resolveAndRequestLinkPreview(_ entry: ClipboardEntry) {
        guard isPreviewSurfaceVisible, preferences.fetchLinkPreviews else { return }
        guard entry.primaryKind == .url else { return }
        guard let engine else { return }
        let generation = linkResolveGeneration
        let entryID = entry.id
        let fingerprint = entry.fingerprint
        linkURLQueue.async { [weak self] in
            let url = engine.retainedWebURL(for: entry)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isPreviewSurfaceVisible else { return }
                guard self.preferences.fetchLinkPreviews else { return }
                guard self.linkResolveGeneration == generation else { return }
                guard self.visibleLinkEntries[entryID] != nil else { return }
                guard self.entries.contains(where: { $0.id == entryID && $0.fingerprint == fingerprint })
                        || self.visibleLinkEntries[entryID]?.fingerprint == fingerprint else { return }
                guard let url else { return }
                self.linkPreviews?.requestVisible(entry: entry, url: url)
            }
        }
    }

    private func stripNetworkDerivedURLPreviews() {
        for (id, var preview) in previewCache {
            if entries.first(where: { $0.id == id })?.primaryKind == .url {
                preview.linkTitle = nil
                if preview.fileIcon == nil {
                    preview.thumbnail = nil
                }
                previewCache[id] = preview
            }
        }
    }

    /// Async clear; disk I/O off MainActor. Surfaces errors via captureError banner.
    func clearLinkPreviewCache() {
        Task { @MainActor in
            do {
                try await linkPreviews?.clearCache()
                stripNetworkDerivedURLPreviews()
            } catch {
                captureError = error.localizedDescription
            }
        }
    }

    func applyCaptureResult(_ result: CaptureResult) {
        lastCaptureResult = result
        switch result {
        case .failed(let failure):
            captureError = failure.message
        case .inserted, .updatedExisting:
            captureError = nil
            refresh()
        case .ignoredEmpty, .ignoredSelfWrite, .ignoredTransient:
            break
        }
    }

    func refresh() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard let engine else {
            entries = []
            return
        }
        let path = supportRootPath
        repositoryQueue.async { [weak self] in
            do {
                let sorted = try engine.sortedEntries()
                let stats = try engine.storageStats(applicationSupportPath: path)
                DispatchQueue.main.async {
                    guard let self, generation == self.refreshGeneration else { return }
                    self.entries = sorted
                    self.storageStats = stats
                    self.recomputeSelectionIfNeeded()
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    guard let self, generation == self.refreshGeneration else { return }
                    self.captureError = message
                }
            }
        }
    }

    func refreshSynchronouslyForTesting() {
        guard let engine else {
            entries = []
            return
        }
        do {
            entries = try engine.sortedEntries()
            storageStats = try engine.storageStats(applicationSupportPath: supportRootPath)
            recomputeSelectionIfNeeded()
        } catch {
            captureError = error.localizedDescription
        }
    }

    func selectNext() {
        selectedID = HistoryQuery.moveSelection(currentID: selectedID, delta: 1, sections: sections)
    }

    func selectPrevious() {
        selectedID = HistoryQuery.moveSelection(currentID: selectedID, delta: -1, sections: sections)
    }

    func selectNextOnQuickShelf() {
        selectedID = QuickShelfPolicy.moveSelection(
            currentID: selectedID,
            delta: 1,
            entries: quickShelf
        )
    }

    func selectPreviousOnQuickShelf() {
        selectedID = QuickShelfPolicy.moveSelection(
            currentID: selectedID,
            delta: -1,
            entries: quickShelf
        )
    }

    func prepareQuickShelfSelection() {
        let shelf = quickShelf
        guard !shelf.isEmpty else {
            selectedID = nil
            return
        }
        if !shelf.contains(where: { $0.id == selectedID }) {
            selectedID = shelf.first?.id
        }
    }

    func selectedEntry() -> ClipboardEntry? {
        guard let selectedID else { return nil }
        return sections.allInDisplayOrder.first { $0.id == selectedID }
    }

    /// Async selection copy on the dedicated paste queue. Completion is always on `@MainActor`.
    /// Returns whether a paste was actually started. Single-flight: duplicate starts are ignored
    /// while one paste is in flight. Gate clears on success or error.
    /// `written > 0` is required for success; zero-write/errors do not dismiss.
    @discardableResult
    func pasteSelected(completion: @escaping (Int, Error?) -> Void) -> Bool {
        guard let entry = selectedEntry() else {
            completion(0, nil)
            return false
        }
        return paste(entryID: entry.id, completion: completion)
    }

    /// Copy a specific archive entry without coupling the caller to the panel's
    /// query or selection projection. Used by the full-history library.
    @discardableResult
    func paste(
        entryID: UUID,
        completion: @escaping (Int, Error?) -> Void
    ) -> Bool {
        guard SelectionCopyCompletionPolicy.shouldStartPaste(isPasteInFlight: isPasteInFlight) else {
            return false
        }
        guard let engine else {
            completion(0, ClipboardRepositoryError.notFound)
            return false
        }
        guard let entry = entries.first(where: { $0.id == entryID }) else {
            completion(0, nil)
            return false
        }
        isPasteInFlight = true
        pasteQueue.async { [weak self] in
            do {
                let written = try engine.paste(entry: entry)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isPasteInFlight = false
                    completion(written, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isPasteInFlight = false
                    completion(0, error)
                }
            }
        }
        return true
    }

    /// Test helper: synchronous paste.
    @discardableResult
    func pasteSelectedSynchronouslyForTesting() throws -> Int {
        guard let engine, let entry = selectedEntry() else { return 0 }
        return try engine.paste(entry: entry)
    }

    func togglePin(id: UUID) {
        guard let engine else { return }
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let pin = !entry.isPinned
        runMutation {
            try engine.setPinned(id: id, isPinned: pin)
        }
    }

    func delete(id: UUID) {
        guard let engine else { return }
        visibleLinkEntries.removeValue(forKey: id)
        linkPreviews?.cancel(entryID: id)
        runMutation {
            try engine.delete(id: id)
        }
        if selectedID == id { selectedID = nil }
    }

    func clearUnpinned() {
        guard let engine else { return }
        runMutation {
            try engine.clearUnpinned()
        }
    }

    func clearAll() {
        guard let engine else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let path = supportRootPath
        repositoryQueue.async { [weak self] in
            do {
                try engine.clearAll()
                let sorted = try engine.sortedEntries()
                let stats = try engine.storageStats(applicationSupportPath: path)
                DispatchQueue.main.async {
                    guard let self, generation == self.refreshGeneration else { return }
                    // Always apply cleared history UI first.
                    self.entries = sorted
                    self.storageStats = stats
                    self.previewCache.removeAll()
                    self.recomputeSelectionIfNeeded()
                    self.captureError = nil
                    // Then clear link preview cache off-main; surface failure without restoring rows.
                    Task { @MainActor in
                        do {
                            try await self.linkPreviews?.clearCache()
                        } catch {
                            self.captureError = error.localizedDescription
                        }
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    guard let self, generation == self.refreshGeneration else { return }
                    self.captureError = message
                }
            }
        }
    }

    func refreshStorageStats() {
        guard let engine else { return }
        let path = supportRootPath
        repositoryQueue.async { [weak self] in
            do {
                let stats = try engine.storageStats(applicationSupportPath: path)
                DispatchQueue.main.async {
                    self?.storageStats = stats
                }
            } catch {
                DispatchQueue.main.async {
                    self?.captureError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Previews

    private func requestPreview(for entry: ClipboardEntry) {
        guard let engine else { return }
        guard previewCache[entry.id] == nil else { return }
        guard !previewRequestsInFlight.contains(entry.id) else { return }

        let id = entry.id
        let fp = entry.fingerprint
        previewRequestsInFlight.insert(id)
        previewQueue.addOperation { [weak self] in
            let preview = PreviewLoader.load(entry: entry, engine: engine)
            DispatchQueue.main.async {
                guard let self else { return }
                self.previewRequestsInFlight.remove(id)
                // Drop stale work if the entry was deleted or recycled.
                if self.entries.contains(where: { $0.id == id && $0.fingerprint == fp }) {
                    self.previewCache[id] = preview
                }
            }
        }
    }

    private func runMutation(_ body: @escaping () throws -> Void) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard let engine else { return }
        let path = supportRootPath
        repositoryQueue.async { [weak self] in
            do {
                try body()
                let sorted = try engine.sortedEntries()
                let stats = try engine.storageStats(applicationSupportPath: path)
                DispatchQueue.main.async {
                    guard let self, generation == self.refreshGeneration else { return }
                    self.entries = sorted
                    self.storageStats = stats
                    self.captureError = nil
                    self.recomputeSelectionIfNeeded()
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    guard let self, generation == self.refreshGeneration else { return }
                    self.captureError = message
                }
            }
        }
    }

    private func recomputeSelectionIfNeeded() {
        let items = isPanelVisible ? quickShelf : sections.allInDisplayOrder
        if items.isEmpty {
            selectedID = nil
            return
        }
        if let selectedID, items.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = items.first?.id
    }
}

/// Off-main loaded preview payload for a row.
struct EntryPreview: Equatable {
    var thumbnail: NSImage?
    var fileIcon: NSImage?
    var linkTitle: String?
}

enum PreviewLoader {
    static func load(entry: ClipboardEntry, engine: ClipboardEngine) -> EntryPreview {
        switch entry.primaryKind {
        case .image:
            if let loaded = try? engine.loadPayloadData(
                for: entry,
                preferring: [ClipboardTypeIdentifiers.png, ClipboardTypeIdentifiers.tiff]
            ) {
                let thumb = downsampleImage(data: loaded.data, maxPixel: 128)
                return EntryPreview(thumbnail: thumb, fileIcon: nil)
            }
        case .fileList:
            if let path = entry.originalFilePaths.first {
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: 32, height: 32)
                return EntryPreview(thumbnail: nil, fileIcon: icon)
            }
        default:
            break
        }
        return EntryPreview(thumbnail: nil, fileIcon: nil)
    }

    static func downsampleImage(data: Data, maxPixel: CGFloat) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(1, maxPixel / max(size.width, size.height))
        if scale >= 0.999 { return image }
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let result = NSImage(size: newSize)
        result.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        result.unlockFocus()
        return result
    }
}
