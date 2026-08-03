import AppKit
import SwiftUI
import NotchClipCore

/// Long-lived `@MainActor` coordinator retained via `NSApplicationDelegateAdaptor`.
@MainActor
@Observable
final class AppCoordinator: NSObject {
    let history = HistoryModel()
    let accessibility: AccessibilityPermissionState
    let launchAtLogin = LaunchAtLoginController()
    let updater = UpdaterController()
    private(set) var engine: ClipboardEngine?
    private(set) var monitor: ClipboardMonitor?
    private(set) var panelController: NotchPanelController?
    private(set) var hotKey: any HotKeyRegistering
    private let pasteDispatcher: PasteCommandDispatcher
    private let capturePulse = CapturePulseController()
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
    private var permissionPasteErrorMessage: String?
    private var workspaceObserver: NSObjectProtocol?
    private var accessibilityChangeObserver: NSObjectProtocol?

    var menuBarSymbol: String {
        storageError == nil ? "clipboard" : "exclamationmark.triangle"
    }

    /// The last shortcut that registered successfully; preferences are only
    /// written after registration, so this is always a working binding.
    var hotKeyBinding: NotchClipHotKeyBinding {
        history.preferences.hotKey
    }

    var hotKeyDescription: HotKeyDescription {
        HotKeyKeyLabels.description(for: hotKeyBinding)
    }

    init(hotKey: (any HotKeyRegistering)? = nil) {
        let accessibility = AccessibilityPermissionState(
            dispatchReadinessCheck: { AccessibilityAuthorization.ensureReadyToPostEvents() }
        )
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
        accessibilityOnboarding.hotKeyDescription = { [weak self] in
            self?.hotKeyDescription ?? .default
        }
    }

    func start() {
        refreshAccessibilityStatus()
        bootstrapStorage()
        configureHotKey()
        configureFocusTracking()
        updater.start()
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
        capturePulse.cancel()
        monitor?.stop()
        hotKey.unregister()
        panelController?.shutdown()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let accessibilityChangeObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityChangeObserver)
        }
    }

    // MARK: - Menu / hotkey shared path

    func toggleClipboardPanel() {
        refreshAccessibilityStatus()
        rememberFrontmostIfNeeded()
        // The panel supersedes any in-flight copy acknowledgment.
        capturePulse.cancel()

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

    /// Menu entry point. There is one surface now, so this simply presents it.
    func openClipboardLibrary() {
        showClipboardPanel()
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
                guard let self else { return }
                self.history.applyCaptureResult(result)
                // Opt-in acknowledgment at the notch while the panel is closed.
                guard self.history.preferences.showCapturePulse else { return }
                let phase = self.panelController?.phase ?? .hidden
                if CapturePulsePolicy.shouldShow(result: result, panelPhase: phase),
                   let entry = CapturePulsePolicy.entry(for: result) {
                    self.capturePulse.show(for: entry)
                }
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
        if !hotKey.register(history.preferences.hotKey) {
            hotKeyError = hotKey.registrationError ?? "Failed to register the shortcut."
        } else {
            hotKeyError = nil
        }
    }

    /// Swap the global shortcut. The previous binding stays registered unless
    /// the new one takes its place, and only a registered binding is persisted.
    @discardableResult
    func applyHotKeyBinding(_ binding: NotchClipHotKeyBinding) -> Bool {
        let previous = history.preferences.hotKey
        if let failure = NotchClipHotKeyValidation.failure(for: binding) {
            hotKeyError = NotchClipHotKeyValidation.message(for: failure)
            // Recording suspends the live registration, so a rejection here
            // must not leave the app with no shortcut at all.
            if !hotKey.isRegistered {
                _ = hotKey.register(previous)
            }
            return false
        }
        if hotKey.register(binding) {
            history.setHotKey(binding)
            hotKeyError = nil
            return true
        }
        let failureMessage = hotKey.registrationError ?? "That shortcut is in use by another app."
        _ = hotKey.register(previous)
        hotKeyError = failureMessage
        return false
    }

    @discardableResult
    func resetHotKeyToDefault() -> Bool {
        applyHotKeyBinding(NotchClipHotKey.defaultBinding)
    }

    /// An exclusive Carbon registration consumes its own combo before any local
    /// NSEvent monitor sees it, so the recorder could never capture the shortcut
    /// already in use. Stand the registration down for the duration.
    func beginHotKeyRecording() {
        hotKey.unregister()
    }

    func endHotKeyRecording() {
        guard !hotKey.isRegistered else { return }
        if hotKey.register(history.preferences.hotKey) {
            hotKeyError = nil
        } else {
            hotKeyError = hotKey.registrationError ?? "Failed to register the shortcut."
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
        // The system broadcasts this the moment the Accessibility list changes,
        // so the switch in Settings takes effect here without waiting for
        // NotchClip to be activated or for a setup-window poll to come around.
        accessibilityChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityStatus()
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
                    // Surface the permission step and nothing else. Activating
                    // the paste target here raced the setup window's own
                    // activation, so the window could open behind the target
                    // and the flow looked broken. The clip is already on the
                    // clipboard; the message explains manual Command-V.
                    self.permissionPasteErrorMessage = message
                    self.history.setCaptureError(message)
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
