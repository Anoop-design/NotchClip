import AppKit
import NotchClipCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AccessibilityPermissionState {
    private(set) var isGranted: Bool
    private(set) var hasRequestedPermission = false
    private(set) var isWaitingForPermission = false
    private(set) var setupErrorMessage: String?
    private(set) var permissionPageRequestID: UInt64 = 0
    private(set) var setupAttemptID: UInt64 = 0

    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var waitingResetTask: Task<Void, Never>?
    @ObservationIgnored private let authorizationCheck: @MainActor () -> Bool
    @ObservationIgnored private let authorizationRequest: @MainActor () -> Bool
    @ObservationIgnored private let settingsOpener: @MainActor () -> Bool
    /// Paste-path-only readiness probe; may perform a system request. Nil falls
    /// back to `authorizationCheck` so injected test states stay side-effect-free.
    @ObservationIgnored private let dispatchReadinessCheck: (@MainActor () -> Bool)?
    @ObservationIgnored private let pollingIntervalNanoseconds: UInt64
    @ObservationIgnored private let waitingTimeoutNanoseconds: UInt64
    @ObservationIgnored var onPermissionGranted: (() -> Void)?
    @ObservationIgnored var onPermissionRevoked: (() -> Void)?
    @ObservationIgnored var onPermissionRequestAttempted: (() -> Void)?

    init(
        authorizationCheck: @escaping @MainActor () -> Bool = {
            AccessibilityAuthorization.isGranted
        },
        authorizationRequest: @escaping @MainActor () -> Bool = {
            AccessibilityAuthorization.requestPermission()
        },
        settingsOpener: @escaping @MainActor () -> Bool = {
            AccessibilityAuthorization.openSystemSettings()
        },
        pollingIntervalNanoseconds: UInt64 = 500_000_000,
        waitingTimeoutNanoseconds: UInt64 = 2_500_000_000,
        dispatchReadinessCheck: (@MainActor () -> Bool)? = nil
    ) {
        self.authorizationCheck = authorizationCheck
        self.authorizationRequest = authorizationRequest
        self.settingsOpener = settingsOpener
        self.dispatchReadinessCheck = dispatchReadinessCheck
        self.pollingIntervalNanoseconds = pollingIntervalNanoseconds
        self.waitingTimeoutNanoseconds = waitingTimeoutNanoseconds
        self.isGranted = authorizationCheck()
    }

    var isMonitoring: Bool {
        pollingTask != nil
    }

    var statusTitle: String {
        if isGranted {
            return "Automatic Paste is ready"
        }
        if setupErrorMessage != nil {
            return "System Settings could not be opened"
        }
        if isWaitingForPermission {
            return "Waiting for Accessibility access"
        }
        return "Accessibility access is required"
    }

    var statusSymbol: String {
        if isGranted { return "checkmark.circle.fill" }
        if setupErrorMessage != nil { return "exclamationmark.triangle.fill" }
        return "hand.raised.fill"
    }

    func prepareForPresentation() {
        cancelWaitingReset()
        isWaitingForPermission = false
        setupErrorMessage = nil
        refresh()
        beginMonitoring()
    }

    /// Restores the durable fact that macOS has already been asked once. The
    /// one-time prompt is not a reliable retry surface, so later attempts route
    /// directly through Privacy & Security.
    func restoreRequestAttemptState(_ hasPreviouslyRequested: Bool) {
        hasRequestedPermission = hasRequestedPermission || hasPreviouslyRequested
    }

    func requestPermissionPage() {
        permissionPageRequestID &+= 1
    }

    func requestPermission() {
        beginPermissionAttempt()
        update(isGranted: authorizationRequest())
        if !isGranted {
            beginMonitoring()
            scheduleWaitingReset()
        }
    }

    /// A retry deliberately performs both actions: re-signal the system
    /// authorization APIs, then reopen the exact Settings pane. macOS may not
    /// show its one-time prompt again after a denial or revocation.
    @discardableResult
    func retryPermission() -> Bool {
        beginPermissionAttempt()
        update(isGranted: authorizationRequest())
        guard !isGranted else { return true }
        return openSystemSettingsForCurrentAttempt()
    }

    @discardableResult
    func openSystemSettings() -> Bool {
        beginPermissionAttempt()
        return openSystemSettingsForCurrentAttempt()
    }

    /// Refreshes immediately when the user returns from the system-owned prompt
    /// or System Settings, and clears any stale indefinite spinner.
    func didReturnToApp() {
        refresh()
        guard !isGranted else { return }
        cancelWaitingReset()
        isWaitingForPermission = false
    }

    private func openSystemSettingsForCurrentAttempt() -> Bool {
        setupErrorMessage = nil
        let didOpen = settingsOpener()
        if !didOpen {
            cancelWaitingReset()
            isWaitingForPermission = false
            setupErrorMessage = "NotchClip couldn’t open Privacy & Security. Open System Settings → Privacy & Security → Accessibility, then enable NotchClip."
        }
        refresh()
        if didOpen, !isGranted {
            beginMonitoring()
            scheduleWaitingReset()
        }
        return didOpen
    }

    func refresh() {
        update(isGranted: authorizationCheck())
    }

    /// Gate for the automatic-paste path. When the passive check fails, one
    /// active readiness probe runs before giving up — recovering the state
    /// where AX trust exists but the event-post preflight is stale.
    func ensureReadyForDispatch() -> Bool {
        refresh()
        if isGranted { return true }
        let ready = (dispatchReadinessCheck ?? authorizationCheck)()
        if ready {
            update(isGranted: true)
        }
        return ready
    }

    func beginMonitoring() {
        refresh()
        guard !isGranted, pollingTask == nil else { return }

        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollingIntervalNanoseconds else { return }
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard let self else { return }
                self.refresh()
                if self.isGranted { return }
            }
        }
    }

    func endMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
        cancelWaitingReset()
        isWaitingForPermission = false
    }

    private func update(isGranted newValue: Bool) {
        let wasGranted = isGranted
        let becameGranted = !wasGranted && newValue
        let becameRevoked = wasGranted && !newValue
        isGranted = newValue
        if newValue {
            setupErrorMessage = nil
            cancelWaitingReset()
            isWaitingForPermission = false
        }
        if becameGranted {
            endMonitoring()
            onPermissionGranted?()
        } else if becameRevoked {
            cancelWaitingReset()
            isWaitingForPermission = false
            restoreRequestAttemptState(true)
            onPermissionRequestAttempted?()
            onPermissionRevoked?()
        }
    }

    private func beginPermissionAttempt() {
        cancelWaitingReset()
        setupErrorMessage = nil
        isWaitingForPermission = true
        hasRequestedPermission = true
        setupAttemptID &+= 1
        onPermissionRequestAttempted?()
    }

    private func scheduleWaitingReset() {
        cancelWaitingReset()
        guard !isGranted else { return }
        let timeout = waitingTimeoutNanoseconds
        waitingResetTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            guard let self, !self.isGranted else { return }
            self.isWaitingForPermission = false
            self.waitingResetTask = nil
        }
    }

    private func cancelWaitingReset() {
        waitingResetTask?.cancel()
        waitingResetTask = nil
    }
}

/// Owns the one-time permission explanation window. Keep one instance alive in
/// `AppCoordinator`, call `presentIfNeeded()` after launch, and call `shutdown()`
/// during application termination.
@MainActor
final class AccessibilityPermissionOnboardingController: NSObject, NSWindowDelegate {
    static let completionVersionDefaultsKey = "com.anoop.notchclip.productOnboarding.completedVersion"
    static let deferredVersionDefaultsKey = "com.anoop.notchclip.productOnboarding.deferredVersion"
    static let permissionRequestAttemptedDefaultsKey = "com.anoop.notchclip.accessibility.requestAttempted"
    static let currentOnboardingVersion = 3

    private enum CloseReason {
        case userDismissed
        case completed
        case shutdown
    }

    private let defaults: UserDefaults
    let state: AccessibilityPermissionState
    private var window: NSWindow?
    private var closeReason: CloseReason = .userDismissed
    var onPermissionGranted: (() -> Void)?

    init(
        state: AccessibilityPermissionState,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.state = state
        super.init()
        let hasPreviouslyRequested =
            defaults.bool(forKey: Self.permissionRequestAttemptedDefaultsKey)
            || state.isGranted
        state.restoreRequestAttemptState(hasPreviouslyRequested)
        if state.isGranted {
            defaults.set(true, forKey: Self.permissionRequestAttemptedDefaultsKey)
        }
        state.onPermissionRequestAttempted = { [weak self] in
            self?.defaults.set(true, forKey: Self.permissionRequestAttemptedDefaultsKey)
        }
        state.onPermissionGranted = { [weak self] in
            self?.permissionWasGranted()
        }
        state.onPermissionRevoked = { [weak self] in
            self?.permissionWasRevoked()
        }
    }

    var isPermissionGranted: Bool {
        state.isGranted
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    var shouldPresentOnLaunch: Bool {
        state.refresh()
        return ProductOnboardingPolicy.shouldPresent(state: persistedOnboardingState)
    }

    /// Shows the product tour once per onboarding version. Accessibility is one
    /// step in the experience, but it does not gate whether the tour can appear.
    @discardableResult
    func presentIfNeeded(force: Bool = false) -> Bool {
        state.refresh()
        guard force || ProductOnboardingPolicy.shouldPresent(state: persistedOnboardingState) else {
            return false
        }

        present()
        return true
    }

    /// Presents the complete product tour, including the permission step.
    func present() {
        present(startsAtPermission: false)
    }

    /// Opens the permission step directly for a contextual setup request from
    /// Settings, the menu, or a failed automatic-paste attempt.
    func presentPermissionSetup() {
        state.requestPermissionPage()
        present(startsAtPermission: true)
    }

    private func present(startsAtPermission: Bool) {
        state.refresh()

        if let window, window.isVisible {
            if !state.isGranted {
                state.beginMonitoring()
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        closeReason = .userDismissed
        state.prepareForPresentation()

        let onboardingView = ProductOnboardingView(
            state: state,
            onEnable: { [weak self] in
                self?.beginAccessibilitySetup()
            },
            onOpenSettings: { [weak self] in
                self?.openAccessibilitySettings()
            },
            onDone: { [weak self] in
                self?.finishOnboarding()
            },
            startsAtPermission: startsAtPermission
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to NotchClip"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = NSHostingController(rootView: onboardingView)
        window.delegate = self
        window.center()

        self.window = window
        // Stay an accessory app: LSUIElement processes can present key windows
        // without switching to .regular, and flipping the activation policy made
        // a Dock icon flash in and out around every permission prompt.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func refreshPermissionStatus() {
        state.refresh()
        if window?.isVisible == true, !state.isGranted {
            state.beginMonitoring()
        }
    }

    func shutdown() {
        state.endMonitoring()
        closeReason = .shutdown
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        state.endMonitoring()

        if closeReason == .userDismissed {
            defaults.set(Self.currentOnboardingVersion, forKey: Self.deferredVersionDefaultsKey)
        }
        window = nil
    }

    private func permissionWasGranted() {
        onPermissionGranted?()
        guard let window else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func permissionWasRevoked() {
        guard window?.isVisible == true else { return }
        state.beginMonitoring()
    }

    private func finishOnboarding() {
        closeReason = .completed
        defaults.set(Self.currentOnboardingVersion, forKey: Self.completionVersionDefaultsKey)
        defaults.removeObject(forKey: Self.deferredVersionDefaultsKey)
        window?.close()
    }

    private func beginAccessibilitySetup() {
        state.requestPermission()
    }

    private func openAccessibilitySettings() {
        state.retryPermission()
    }

    private var persistedOnboardingState: AccessibilityOnboardingState {
        if defaults.integer(forKey: Self.completionVersionDefaultsKey) >= Self.currentOnboardingVersion {
            return .completed
        }
        if defaults.integer(forKey: Self.deferredVersionDefaultsKey) >= Self.currentOnboardingVersion {
            return .deferred
        }
        return .notPresented
    }
}
