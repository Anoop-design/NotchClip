import Foundation
import AppKit
import NotchClipCore

/// Main-actor history snapshot for the panel and menu.
@MainActor
@Observable
final class HistoryModel {
    private(set) var entries: [ClipboardEntry] = [] {
        didSet {
            entriesRevision &+= 1
            rebuildProjection()
        }
    }
    /// Monotonic identity for the current history snapshot. Views can invalidate
    /// cached projections without equality-scanning an indefinitely large archive.
    private(set) var entriesRevision: UInt64 = 0
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            rebuildProjection()
        }
    }
    /// Active content filter (⌥1–⌥6 in the panel).
    var scope: ClipScope = .all {
        didSet {
            guard scope != oldValue else { return }
            rebuildProjection()
        }
    }
    /// The filtered, sorted, sectioned view of history for the current inputs.
    /// Rebuilt only when entries, query, or scope change — never on selection or hover.
    private(set) var projection: ClipProjection = .empty
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

    /// Full decoded text for entries the preview pane has shown, keyed by entry id.
    ///
    /// `previewText` is whitespace-collapsed and capped at 200 characters for row
    /// summaries, so it cannot be used to display a clip's real contents. The
    /// complete bytes are always on disk; this loads them for the *selected*
    /// entry only, off the main actor, and keeps a bounded cache.
    private(set) var fullTextCache: [UUID: String] = [:]
    private var fullTextRequestsInFlight: Set<UUID> = []
    /// Insertion order for the bounded full-text cache (oldest first).
    private var fullTextOrder: [UUID] = []
    private let fullTextCacheLimit = 24
    /// Hard ceiling on decoded characters kept for one entry.
    /// `nonisolated` so the off-main loader can read it.
    nonisolated static let fullTextDisplayLimit = 100_000

    /// Link preview coordinator (optional until attached).
    private(set) var linkPreviews: LinkPreviewService?

    /// True while the notch panel is ordered in / presenting (not merely row-visible).
    private(set) var isPanelVisible: Bool = false

    private var isPreviewSurfaceVisible: Bool { isPanelVisible }

    /// True while a user-initiated paste is running (single-flight gate).
    private(set) var isPasteInFlight: Bool = false

    /// URL entries currently visible in the panel (for re-request when previews re-enabled).
    private var visibleLinkEntries: [UUID: ClipboardEntry] = [:]

    /// Bumped on panel hide / preference-off so stale resolve completions drop.
    private var linkResolveGeneration: UInt64 = 0

    /// Dedicated utility queue for retained `public.url` resolution (never main / never preview queue).
    private let linkURLQueue = DispatchQueue(label: "com.anoop.notchclip.link-url", qos: .utility)

    /// Entries currently shown, in display order.
    var visibleEntries: [ClipboardEntry] { projection.visibleEntries }
    /// True when the panel has nothing to show for the current query and scope.
    var isEmpty: Bool { projection.visibleEntries.isEmpty }
    /// True when there is no history at all, regardless of filtering.
    var hasNoHistory: Bool { entries.isEmpty }

    var rowModels: [EntryRowModel] {
        projection.visibleEntries.map { entry in
            let link = linkPreviews?.results[entry.id]
            return EntryRowModel(entry: entry, linkTitle: link?.title)
        }
    }

    func attach(engine: ClipboardEngine?, supportRoot: URL?) {
        self.engine = engine
        self.supportRootPath = supportRoot?.path ?? ""
        engine?.setHistoryLimit(preferences.historyLimit)
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
            prepareSelection()
        }
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

    func setShowCapturePulse(_ enabled: Bool) {
        preferences.showCapturePulse = enabled
        preferences.save()
    }

    /// Lowering the limit prunes immediately; raising it only changes future captures.
    func setHistoryLimit(_ limit: Int) {
        preferences.historyLimit = limit
        preferences.save()
        guard let engine else { return }
        engine.setHistoryLimit(limit)
        runMutation {
            try engine.enforceRetentionLimit()
        }
    }

    func setAlwaysPastePlainText(_ enabled: Bool) {
        preferences.alwaysPastePlainText = enabled
        preferences.save()
    }

    /// Only called once a shortcut has actually registered, so a rejected
    /// binding never survives a relaunch.
    func setHotKey(_ binding: NotchClipHotKeyBinding) {
        preferences.hotKey = binding
        preferences.save()
    }

    /// Whether a paste performed with `shiftHeld` should strip formatting.
    func usesPlainText(shiftHeld: Bool) -> Bool {
        PlainTextPastePolicy.usesPlainText(
            alwaysPlainText: preferences.alwaysPastePlainText,
            shiftHeld: shiftHeld
        )
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
        } catch {
            captureError = error.localizedDescription
        }
    }

    func selectNext() {
        selectedID = projection.moveSelection(from: selectedID, delta: 1)
        requestFullTextForSelection()
    }

    func selectPrevious() {
        selectedID = projection.moveSelection(from: selectedID, delta: -1)
        requestFullTextForSelection()
    }

    /// Jump to the first or last visible entry (Home / End, ⌘↑ / ⌘↓).
    func selectFirst() {
        selectedID = projection.visibleEntries.first?.id
        requestFullTextForSelection()
    }

    func selectLast() {
        selectedID = projection.visibleEntries.last?.id
        requestFullTextForSelection()
    }

    /// Move by a page of rows, for Page Up / Page Down.
    func selectByPage(_ direction: Int, pageSize: Int = 8) {
        selectedID = projection.moveSelection(from: selectedID, delta: direction * pageSize)
        requestFullTextForSelection()
    }

    /// Ensure the current selection still exists and preload its full text.
    func prepareSelection() {
        rebuildProjection()
    }

    func requestFullTextForSelection() {
        guard let selectedID,
              let entry = projection.entry(id: selectedID) else { return }
        requestFullText(for: entry)
    }

    func selectedEntry() -> ClipboardEntry? {
        guard let selectedID else { return nil }
        return projection.entry(id: selectedID)
    }

    /// Async selection copy on the dedicated paste queue. Completion is always on `@MainActor`.
    /// Returns whether a paste was actually started. Single-flight: duplicate starts are ignored
    /// while one paste is in flight. Gate clears on success or error.
    /// `written > 0` is required for success; zero-write/errors do not dismiss.
    @discardableResult
    func pasteSelected(
        plainText: Bool = false,
        completion: @escaping (Int, Error?) -> Void
    ) -> Bool {
        guard let entry = selectedEntry() else {
            completion(0, nil)
            return false
        }
        return paste(entryID: entry.id, plainText: plainText, completion: completion)
    }

    /// Copy a specific archive entry without coupling the caller to the panel's
    /// query or selection projection. Used by the full-history library.
    ///
    /// `plainText` writes only the clip's plain string; kinds with no plain-text
    /// form fall back to the full representation set inside the engine.
    @discardableResult
    func paste(
        entryID: UUID,
        plainText: Bool = false,
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
                let written = plainText
                    ? try engine.pastePlainText(entry: entry)
                    : try engine.paste(entry: entry)
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
        fullTextCache.removeValue(forKey: id)
        fullTextOrder.removeAll { $0 == id }
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
                    self.fullTextCache.removeAll()
                    self.fullTextOrder.removeAll()
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

    /// Load the complete decoded text for one entry (preview pane only).
    ///
    /// Safe to call repeatedly: cached and in-flight entries are ignored. Only
    /// textual kinds are loaded; images and file lists have their own surfaces.
    func requestFullText(for entry: ClipboardEntry) {
        guard let engine else { return }
        switch entry.primaryKind {
        case .plainText, .rtf, .html, .url, .mixed, .other:
            break
        case .image, .fileList:
            return
        }
        guard fullTextCache[entry.id] == nil else { return }
        guard !fullTextRequestsInFlight.contains(entry.id) else { return }

        let id = entry.id
        let fingerprint = entry.fingerprint
        fullTextRequestsInFlight.insert(id)
        previewQueue.addOperation { [weak self] in
            let text = FullTextLoader.load(entry: entry, engine: engine)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fullTextRequestsInFlight.remove(id)
                guard let text else { return }
                // Drop stale work if the entry was deleted or recycled meanwhile.
                guard self.entries.contains(where: { $0.id == id && $0.fingerprint == fingerprint }) else { return }
                self.storeFullText(text, for: id)
            }
        }
    }

    private func storeFullText(_ text: String, for id: UUID) {
        if fullTextCache[id] == nil {
            fullTextOrder.append(id)
        }
        fullTextCache[id] = text
        while fullTextOrder.count > fullTextCacheLimit {
            let oldest = fullTextOrder.removeFirst()
            fullTextCache.removeValue(forKey: oldest)
        }
    }

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

    /// Recompute the filtered projection, then keep the selection valid.
    ///
    /// Selection is reconciled here rather than in the view so that a refresh,
    /// a scope change, and a keystroke can never leave a selected id that is
    /// not in the visible list.
    private func rebuildProjection() {
        projection = ClipProjection.make(entries: entries, query: query, scope: scope)
        let items = projection.visibleEntries
        guard !items.isEmpty else {
            selectedID = nil
            return
        }
        if let selectedID, projection.contains(id: selectedID) {
            return
        }
        selectedID = items.first?.id
        requestFullTextForSelection()
    }
}

/// Off-main loaded preview payload for a row.
struct EntryPreview: Equatable {
    var thumbnail: NSImage?
    var fileIcon: NSImage?
    var linkTitle: String?
}

/// Decodes a clip's complete retained text off the main actor.
///
/// Prefers real plain text so line structure survives; falls back to RTF and
/// finally to a tag-stripped HTML rendering. Never reads the live pasteboard.
enum FullTextLoader {
    static func load(entry: ClipboardEntry, engine: ClipboardEngine) -> String? {
        let ordered = [
            ClipboardTypeIdentifiers.utf8PlainText,
            ClipboardTypeIdentifiers.plainText,
            ClipboardTypeIdentifiers.utf16External,
            ClipboardTypeIdentifiers.url,
            ClipboardTypeIdentifiers.rtf,
            ClipboardTypeIdentifiers.html
        ]
        for type in ordered {
            guard let ref = entry.payloadRefs.first(where: {
                $0.typeIdentifier == type && !$0.relativePath.isEmpty
            }) else { continue }
            guard let data = try? engine.loadPayloadData(for: ref), !data.isEmpty else { continue }
            guard let decoded = decode(data: data, type: type) else { continue }
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            return String(trimmed.prefix(HistoryModel.fullTextDisplayLimit))
        }
        return nil
    }

    private static func decode(data: Data, type: String) -> String? {
        if type == ClipboardTypeIdentifiers.rtf {
            // Safe off-main: RTF import does not go through WebKit.
            return NSAttributedString(rtf: data, documentAttributes: nil)?.string
        }
        if type == ClipboardTypeIdentifiers.html {
            // Never NSAttributedString(html:) off-main — Apple requires the main thread.
            return PasteboardParser.plainTextFromHTML(data)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }
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
