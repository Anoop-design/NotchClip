import AppKit
import QuickLookUI
import NotchClipCore

/// Dedicated one-item Quick Look presenter backed by `QLPreviewView` (not shared `QLPreviewPanel`).
/// Retained-image payload I/O runs off the main actor on a serial utility queue with monotonic generations.
@MainActor
final class QuickLookController: NSObject, NSWindowDelegate {
    private var previewWindow: NSPanel?
    private var previewView: QLPreviewView?
    private var currentTempURL: URL?
    private var ownedTempURLs: Set<URL> = []
    private let tempDirectory: URL
    private let stagingQueue = DispatchQueue(label: "com.notchclip.quicklook.staging", qos: .utility)

    /// Monotonic request generation. Bumped on each present, cancel, close, and shutdown.
    private(set) var requestGeneration: UInt64 = 0
    /// True while a retained-image materialization is in flight (or a window is visible).
    private(set) var isStaging: Bool = false
    private(set) var isActive: Bool = false

    /// True for either an open preview window or in-flight staging (parent treats both as QL active).
    var isActiveOrStaging: Bool { isActive || isStaging }

    var onWillShow: (() -> Void)?
    /// Invoked exactly once per active/staging presentation when it fully closes or is cancelled.
    var onDidClose: (() -> Void)?

    /// Tracks whether the current generation has already notified close (exactly-once).
    private var closeNotifiedForGeneration: UInt64 = 0
    /// Generation that currently owns an open presentation or staging; 0 when idle.
    private var presentationGeneration: UInt64 = 0
    /// Exactly-once will-show for the current presentation generation.
    private var didNotifyWillShow = false

    override init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        tempDirectory = base.appendingPathComponent("NotchClip/QuickLook", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        deleteAllTempFilesInDirectory()
    }

    func shutdown() {
        close(notify: true)
        deleteAllTempFilesInDirectory()
    }

    /// Present Quick Look asynchronously. Completion runs on the main actor.
    /// - Parameter completion: `errorMessage` is non-nil when presentation failed or was rejected; nil on success.
    ///   Cancelled/toggled-away staging also completes with a nil error (clean cancel).
    func present(
        route: QuickLookRoute,
        entry: ClipboardEntry,
        engine: ClipboardEngine?,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        switch route {
        case .unsupported(let message), .missingFiles(let message):
            completion(message)
            return

        case .fileURLs(let paths):
            guard let path = QuickLookPolicy.firstExistingFilePath(
                from: paths,
                fileExists: { FileManager.default.fileExists(atPath: $0) }
            ) else {
                completion("One or more files are missing and cannot be previewed.")
                return
            }
            // Cancel any prior presentation/staging before opening.
            beginNewPresentation()
            let url = URL(fileURLWithPath: path)
            showPreview(itemURL: url, generatedTemp: nil)
            completion(nil)

        case .materializeRetainedImage:
            guard let engine else {
                completion("Clipboard storage is unavailable.")
                return
            }
            // Capture Sendable storage seam + value payload refs only (never engine across the queue).
            let store = engine.payloadStore
            let refs = entry.payloadRefs
            let preferred: [String] = [
                ClipboardTypeIdentifiers.png,
                ClipboardTypeIdentifiers.tiff
            ]
            let cacheDir = tempDirectory

            beginNewPresentation()
            let generation = requestGeneration
            isStaging = true
            notifyWillShowIfNeeded()

            stagingQueue.async { [weak self] in
                let result = Self.loadAndMaterializeImage(
                    payloadStore: store,
                    refs: refs,
                    preferredTypes: preferred,
                    tempDirectory: cacheDir
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        if case .success(let url) = result {
                            try? FileManager.default.removeItem(at: url)
                        }
                        return
                    }
                    self.handleStagingCompletion(
                        generation: generation,
                        result: result,
                        completion: completion
                    )
                }
            }
        }
    }

    private func notifyWillShowIfNeeded() {
        guard !didNotifyWillShow else { return }
        didNotifyWillShow = true
        onWillShow?()
    }

    /// Close / cancel current presentation or staging. Safe to call when idle.
    func close() {
        close(notify: true)
    }

    /// Space toggle: if active or staging, cancel/close; otherwise caller should present.
    @discardableResult
    func toggleCancelIfActive() -> Bool {
        if isActiveOrStaging {
            close(notify: true)
            return true
        }
        return false
    }

    // MARK: - Staging

    private func beginNewPresentation() {
        // Cancel prior without double-notify if we're replacing.
        if isActiveOrStaging {
            close(notify: true)
        }
        requestGeneration &+= 1
        presentationGeneration = requestGeneration
        closeNotifiedForGeneration = 0
        didNotifyWillShow = false
    }

    private enum MaterializeResult {
        case success(URL)
        case failure(String)
    }

    private nonisolated static func loadAndMaterializeImage(
        payloadStore: any PayloadStoring,
        refs: [PayloadReference],
        preferredTypes: [String],
        tempDirectory: URL
    ) -> MaterializeResult {
        do {
            var loaded: (type: String, data: Data)?
            for type in preferredTypes {
                if let ref = refs.first(where: { $0.typeIdentifier == type && !$0.relativePath.isEmpty }) {
                    let data = try payloadStore.loadData(for: ref)
                    loaded = (type, data)
                    break
                }
            }
            if loaded == nil, let ref = refs.first(where: { !$0.relativePath.isEmpty }) {
                let data = try payloadStore.loadData(for: ref)
                loaded = (ref.typeIdentifier, data)
            }
            guard let loaded else {
                return .failure("No retained image data is available for Quick Look.")
            }
            let ext = QuickLookPolicy.imageFileExtension(forType: loaded.type)
            let name = "ql-\(UUID().uuidString).\(ext)"
            let url = tempDirectory.appendingPathComponent(name)
            // Containment: only write under the given cache directory.
            let resolvedDir = tempDirectory.standardizedFileURL.path
            let resolvedFile = url.standardizedFileURL.path
            guard resolvedFile.hasPrefix(resolvedDir + "/") || resolvedFile == resolvedDir else {
                return .failure("Invalid Quick Look cache path.")
            }
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            try loaded.data.write(to: url, options: .atomic)
            return .success(url)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func handleStagingCompletion(
        generation: UInt64,
        result: MaterializeResult,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        // Stale or cancelled: never present; delete any temp produced.
        guard QuickLookLifecyclePolicy.shouldApplyStagingCompletion(
            requestGeneration: generation,
            currentGeneration: requestGeneration
        ), presentationGeneration == generation else {
            if case .success(let url) = result {
                try? FileManager.default.removeItem(at: url)
            }
            // Cancel already notified via close(); still surface clean completion.
            completion(nil)
            return
        }

        isStaging = false

        switch result {
        case .failure(let message):
            notifyDidCloseIfNeeded(for: generation)
            isActive = false
            presentationGeneration = 0
            completion(message)
        case .success(let url):
            ownedTempURLs.insert(url)
            currentTempURL = url
            showPreview(itemURL: url, generatedTemp: url)
            completion(nil)
        }
    }

    // MARK: - Window

    private func showPreview(itemURL: URL, generatedTemp: URL?) {
        buildWindowIfNeeded()
        guard let previewWindow, let previewView else {
            if let generatedTemp {
                deleteTemp(generatedTemp)
            }
            notifyDidCloseIfNeeded(for: presentationGeneration)
            isActive = false
            isStaging = false
            presentationGeneration = 0
            return
        }

        if let generatedTemp {
            ownedTempURLs.insert(generatedTemp)
            currentTempURL = generatedTemp
        } else {
            currentTempURL = nil
        }

        notifyWillShowIfNeeded()

        previewView.shouldCloseWithWindow = true
        previewView.autostarts = true
        previewView.previewItem = itemURL as NSURL

        isActive = true
        isStaging = false
        previewWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindowIfNeeded() {
        if previewWindow != nil { return }

        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        let panel = QuickLookKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.title = "Quick Look"
        panel.delegate = self
        panel.onRequestClose = { [weak self] in
            self?.close(notify: true)
        }

        let qlView = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 720, height: 520), style: .normal)
        qlView?.autoresizingMask = [.width, .height]
        qlView?.shouldCloseWithWindow = true
        qlView?.autostarts = true
        if let qlView {
            panel.contentView = qlView
        }
        self.previewView = qlView
        self.previewWindow = panel
    }

    private var previewKeyMonitor: Any?

    private func installPreviewKeyMonitor() {
        removePreviewKeyMonitor()
        previewKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let window = self.previewWindow, window.isKeyWindow else { return event }
            // Escape (53) or Space (49) — close and consume so keystroke never leaks.
            if event.keyCode == 53 || event.keyCode == 49 {
                self.close(notify: true)
                return nil
            }
            return event
        }
    }

    private func removePreviewKeyMonitor() {
        if let previewKeyMonitor {
            NSEvent.removeMonitor(previewKeyMonitor)
            self.previewKeyMonitor = nil
        }
    }

    private func close(notify: Bool) {
        let gen = presentationGeneration
        // Invalidate in-flight staging / stale completions.
        requestGeneration &+= 1
        isStaging = false

        clearPreviewItem()
        orderOutWindow()
        deleteOwnedTemps()

        let wasPresenting = isActive || gen != 0
        isActive = false
        presentationGeneration = 0

        if notify, wasPresenting {
            notifyDidCloseIfNeeded(for: gen)
        }
    }

    private func notifyDidCloseIfNeeded(for generation: UInt64) {
        guard generation != 0, closeNotifiedForGeneration != generation else { return }
        closeNotifiedForGeneration = generation
        onDidClose?()
    }

    private func clearPreviewItem() {
        previewView?.previewItem = nil
    }

    private func orderOutWindow() {
        removePreviewKeyMonitor()
        previewWindow?.orderOut(nil)
    }

    private func deleteOwnedTemps() {
        for url in ownedTempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        ownedTempURLs.removeAll()
        currentTempURL = nil
    }

    private func deleteTemp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        ownedTempURLs.remove(url)
        if currentTempURL == url {
            currentTempURL = nil
        }
    }

    private func deleteAllTempFilesInDirectory() {
        deleteOwnedTemps()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close(notify: true)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // If the window closes through another path, still clean up once.
        if isActive || isStaging {
            close(notify: true)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === previewWindow else { return }
        installPreviewKeyMonitor()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === previewWindow else { return }
        // Keep monitor while active so Space/Escape still work if we re-key; remove when ordered out.
        if !(previewWindow?.isVisible ?? false) {
            removePreviewKeyMonitor()
        }
    }
}

/// Floating preview panel that routes cancel/Escape to close without leaking to other apps.
private final class QuickLookKeyPanel: NSPanel {
    var onRequestClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onRequestClose?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Consume Escape / Space at the window so they never fall through.
        if event.type == .keyDown, event.keyCode == 53 || event.keyCode == 49 {
            onRequestClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
