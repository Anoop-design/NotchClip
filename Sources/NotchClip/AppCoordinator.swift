import AppKit
import SwiftUI
import NotchClipCore

/// Long-lived `@MainActor` coordinator retained via `NSApplicationDelegateAdaptor`.
@MainActor
@Observable
final class AppCoordinator: NSObject {
    let history = HistoryModel()
    let accessibility: AccessibilityPermissionState
    private(set) var engine: ClipboardEngine?
    private(set) var monitor: ClipboardMonitor?
    private(set) var panelController: NotchPanelController?
    private(set) var libraryController: ClipboardLibraryController?
    private(set) var hotKey: any HotKeyRegistering
    private let pasteDispatcher: PasteCommandDispatcher
    private let libraryQuickLook = QuickLookController()
    private let accessibilityOnboarding: AccessibilityPermissionOnboardingController
    private(set) var storageError: String?
    private(set) var hotKeyError: String?
    private(set) var isPaused: Bool = false
    private(set) var settingsOpen: Bool = false

    /// Last frontmost app that is not NotchClip (for restore-on-dismiss).
    private(set) var lastExternalApp: NSRunningApplication?
    /// App to restore for the active presentation; cleared after one restore attempt.
    private var presentationRestoreApp: NSRunningApplication?
    private var didRestoreForPresentation: Bool = false
    /// App that was active before opening the durable history library.
    private var libraryRestoreApp: NSRunningApplication?
    private var isLibraryPasteInFlight = false
    private var suppressLibraryDismissRestore = false
    private var permissionPasteErrorMessage: String?
    private var workspaceObserver: NSObjectProtocol?

    var menuBarSymbol: String {
        storageError == nil ? "clipboard" : "exclamationmark.triangle"
    }

    init(hotKey: (any HotKeyRegistering)? = nil) {
        let accessibility = AccessibilityPermissionState()
        self.accessibility = accessibility
        self.pasteDispatcher = PasteCommandDispatcher(accessibility: accessibility)
        self.accessibilityOnboarding = AccessibilityPermissionOnboardingController(
            state: accessibility
        )
        self.hotKey = hotKey ?? CarbonHotKeyRegistrar()
        super.init()
        accessibilityOnboarding.onPermissionGranted = { [weak self] in
            self?.clearPermissionPasteErrorIfNeeded()
        }
    }

    func start() {
        refreshAccessibilityStatus()
        bootstrapStorage()
        configureHotKey()
        configureFocusTracking()
        if panelController == nil {
            let panel = NotchPanelController(history: history)
            panel.onDismiss = { [weak self] reason in
                self?.handlePanelDismiss(reason)
            }
            panel.attach(engine: engine)
            panelController = panel
        } else {
            panelController?.attach(engine: engine)
        }

        if libraryController == nil {
            let library = ClipboardLibraryController(history: history)
            library.attach(engine: engine)
            library.onPaste = { [weak self] entry in
                self?.handleLibraryPaste(entry)
            }
            library.onDismiss = { [weak self] in
                self?.handleLibraryDismiss()
            }
            library.onQuickLook = { [weak self] entry in
                self?.handleLibraryQuickLook(entry)
            }
            libraryQuickLook.onDidClose = { [weak library] in
                library?.refocusAfterQuickLook()
            }
            libraryController = library
        } else {
            libraryController?.attach(engine: engine)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let forceOnboarding = ProcessInfo.processInfo.arguments.contains(
                "--show-accessibility-onboarding"
            )
            _ = self.accessibilityOnboarding.presentIfNeeded(force: forceOnboarding)
        }
    }

    func shutdown() {
        accessibilityOnboarding.shutdown()
        pasteDispatcher.cancelPending()
        monitor?.stop()
        hotKey.unregister()
        panelController?.shutdown()
        libraryController?.shutdown()
        libraryQuickLook.shutdown()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    // MARK: - Menu / hotkey shared path

    func toggleClipboardPanel() {
        refreshAccessibilityStatus()
        rememberFrontmostIfNeeded()

        // The global shortcut always means the fast shelf. Hand off cleanly
        // from the durable library if it happens to be open.
        if libraryController?.isVisible == true {
            let target = libraryRestoreApp ?? lastExternalApp
            suppressLibraryDismissRestore = true
            libraryController?.close()
            libraryRestoreApp = nil
            presentationRestoreApp = target
            didRestoreForPresentation = false
            panelController?.show(restoreApp: target)
            return
        }

        let panel = panelController
        let action = PanelPhasePolicy.toggleAction(for: panel?.phase ?? .hidden)
        switch action {
        case .show, .reopen:
            pasteDispatcher.cancelPending()
            presentationRestoreApp = lastExternalApp
            didRestoreForPresentation = false
            panel?.toggle(restoreApp: presentationRestoreApp)
        case .dismiss:
            panel?.toggle(restoreApp: presentationRestoreApp)
        }
    }

    func showClipboardPanel() {
        refreshAccessibilityStatus()
        if panelController?.phase == .expanded || panelController?.phase == .expanding {
            return
        }
        toggleClipboardPanel()
    }

    func openClipboardLibrary() {
        refreshAccessibilityStatus()
        rememberFrontmostIfNeeded()
        pasteDispatcher.cancelPending()

        if libraryController?.isVisible == true {
            libraryController?.present()
            return
        }

        if let panel = panelController, panel.phase != .hidden {
            // The panel's dismissal completion performs the handoff after the
            // island has finished collapsing, avoiding overlapping windows.
            panel.dismiss(reason: .openLibrary)
            return
        }

        libraryRestoreApp = lastExternalApp
        libraryController?.present()
    }

    func togglePause() {
        guard let monitor else { return }
        monitor.togglePause()
        isPaused = monitor.isPaused
        history.setPaused(isPaused)
    }

    func openSettings() {
        refreshAccessibilityStatus()
        settingsOpen = true
        NSApp.activate()
    }

    func presentAccessibilitySetup() {
        refreshAccessibilityStatus()
        accessibilityOnboarding.presentPermissionSetup()
    }

    // MARK: - Bootstrap

    private func bootstrapStorage() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let support else {
            storageError = "Application Support directory is unavailable."
            history.setStorageError(storageError)
            return
        }
        let root = support.appendingPathComponent("NotchClip", isDirectory: true)
        let metaDir = root.appendingPathComponent("metadata", isDirectory: true)
        let payloadDir = root.appendingPathComponent("payloads", isDirectory: true)
        do {
            let repository = try PersistentClipboardRepository(directory: metaDir)
            let payloadStore = try PayloadStore(rootDirectory: payloadDir)
            let engine = ClipboardEngine(repository: repository, payloadStore: payloadStore)
            // Best-effort startup cleanup of payload dirs with no metadata row.
            _ = try? engine.removeOrphanedPayloads()
            self.engine = engine
            history.attach(engine: engine, supportRoot: root)
            history.setStorageError(nil)
            history.refresh()

            let monitor = ClipboardMonitor(engine: engine)
            monitor.onCapture = { [weak self] result in
                self?.history.applyCaptureResult(result)
            }
            self.monitor = monitor
            monitor.start()
        } catch {
            storageError = error.localizedDescription
            history.setStorageError(storageError)
            engine = nil
            monitor = nil
        }
    }

    private func configureHotKey() {
        hotKey.onToggle = { [weak self] in
            self?.toggleClipboardPanel()
        }
        if !hotKey.register() {
            hotKeyError = hotKey.registrationError ?? "Failed to register \(NotchClipHotKey.humanReadableName)."
        } else {
            hotKeyError = nil
        }
    }

    private func configureFocusTracking() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleActivation(note)
            }
        }
        rememberFrontmostIfNeeded()
    }

    private func handleActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        if isSelf(app) {
            accessibility.didReturnToApp()
            if accessibility.isGranted {
                clearPermissionPasteErrorIfNeeded()
            }
            return
        }
        refreshAccessibilityStatus()
        // Opening the system-owned Accessibility pane is part of setup, not a
        // new paste destination. Preserve the app the user was working in
        // before onboarding so the next successful selection returns there.
        if accessibilityOnboarding.isVisible {
            return
        }
        lastExternalApp = app
    }

    private func rememberFrontmostIfNeeded() {
        if let front = NSWorkspace.shared.frontmostApplication, !isSelf(front) {
            lastExternalApp = front
        }
    }

    private func isSelf(_ app: NSRunningApplication) -> Bool {
        if let own = Bundle.main.bundleIdentifier, app.bundleIdentifier == own {
            return true
        }
        return app.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// Single restoration path for selection / Escape / hotkey-close.
    private func handlePanelDismiss(_ reason: DismissReason) {
        let target = presentationRestoreApp

        if reason == .openLibrary {
            refreshAccessibilityStatus()
            libraryRestoreApp = target ?? lastExternalApp
            presentationRestoreApp = nil
            didRestoreForPresentation = false
            libraryController?.present()
            return
        }

        let shouldRestore = DismissPolicy.shouldPerformRestore(
            reason: reason,
            alreadyRestored: didRestoreForPresentation
        )
        let shouldPaste = PasteDeliveryPolicy.shouldStart(
            reason: reason,
            hasTarget: target != nil,
            alreadyRestored: didRestoreForPresentation
        )

        if shouldPaste, let target {
            didRestoreForPresentation = true
            dispatchAutomaticPaste(to: target)
        } else if shouldRestore {
            target?.activate(options: [])
            didRestoreForPresentation = true
            if reason == .selection, target == nil {
                history.setCaptureError(
                    "Copied to the clipboard, but there is no previous app to paste into. Press Command-V to paste manually."
                )
            }
        }
        if panelController?.phase == .hidden {
            presentationRestoreApp = nil
            didRestoreForPresentation = false
        }
    }

    private func handleLibraryPaste(_ entry: ClipboardEntry) {
        guard !isLibraryPasteInFlight else { return }
        isLibraryPasteInFlight = true
        let target = libraryRestoreApp

        let started = history.paste(entryID: entry.id) { [weak self] written, error in
            guard let self else { return }
            self.isLibraryPasteInFlight = false

            guard SelectionCopyPolicy.shouldDismiss(written: written, error: error) else {
                if let error {
                    self.history.setCaptureError(error.localizedDescription)
                } else if written == 0 {
                    self.history.setCaptureError("Could not copy this item to the clipboard.")
                }
                return
            }

            self.suppressLibraryDismissRestore = true
            self.libraryController?.close()
            self.libraryRestoreApp = nil

            if let target {
                self.dispatchAutomaticPaste(to: target)
            } else {
                self.history.setCaptureError(
                    "Copied to the clipboard, but there is no previous app to paste into. Press Command-V to paste manually."
                )
            }
        }

        if !started {
            isLibraryPasteInFlight = false
        }
    }

    private func handleLibraryDismiss() {
        libraryQuickLook.close()
        if suppressLibraryDismissRestore {
            suppressLibraryDismissRestore = false
            return
        }

        let target = libraryRestoreApp
        libraryRestoreApp = nil
        _ = target?.activate(options: [])
    }

    private func handleLibraryQuickLook(_ entry: ClipboardEntry) {
        if libraryQuickLook.toggleCancelIfActive() { return }

        let route = QuickLookPolicy.route(for: entry)
        switch route {
        case .unsupported(let message), .missingFiles(let message):
            history.setCaptureError(message)
            return
        case .fileURLs, .materializeRetainedImage:
            break
        }

        libraryQuickLook.present(route: route, entry: entry, engine: engine) { [weak self] message in
            if let message {
                self?.history.setCaptureError(message)
            }
        }
    }

    private func dispatchAutomaticPaste(to target: NSRunningApplication) {
        pasteDispatcher.dispatch(to: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.clearPermissionPasteErrorIfNeeded()
            case .failure(let error):
                let message = error.localizedDescription
                if let failure = error as? PasteCommandDispatcher.DispatchFailure,
                   case .accessibilityPermissionRequired = failure {
                    // If permission was deferred or revoked, preserve a useful
                    // manual Command-V fallback in the intended destination,
                    // then surface the actionable permission step immediately.
                    self.permissionPasteErrorMessage = message
                    self.history.setCaptureError(message)
                    _ = target.activate(options: [])
                    self.accessibilityOnboarding.presentPermissionSetup()
                    return
                }
                self.permissionPasteErrorMessage = nil
                self.history.setCaptureError(message)
            }
        }
    }

    private func refreshAccessibilityStatus() {
        accessibility.refresh()
        if accessibility.isGranted {
            clearPermissionPasteErrorIfNeeded()
        }
    }

    private func clearPermissionPasteErrorIfNeeded() {
        guard let message = permissionPasteErrorMessage else { return }
        if history.captureError == message {
            history.clearCaptureError()
        }
        permissionPasteErrorMessage = nil
    }
}

/// Application delegate that owns the coordinator for the process lifetime.
@MainActor
final class NotchClipAppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--show-library") {
            DispatchQueue.main.async { [coordinator] in
                coordinator.openClipboardLibrary()
            }
            return
        }
#endif
        if ProcessInfo.processInfo.arguments.contains("--show-panel") {
            DispatchQueue.main.async { [coordinator] in
                coordinator.showClipboardPanel()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }
}
