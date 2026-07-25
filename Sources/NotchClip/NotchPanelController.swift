import AppKit
import SwiftUI
import NotchClipCore

/// Key-capable panel for Spotlight-like text focus without becoming main.
final class NotchKeyPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Filters the device-generated flags macOS attaches to navigation keys from
/// the modifiers the user intentionally held. Arrow events commonly include
/// `.function` and `.numericPad`; treating those as shortcuts prevents the
/// notch's Left/Right/Up/Down handling from ever running.
enum NotchKeyboardEventPolicy {
    private static let userModifierMask: NSEvent.ModifierFlags = [
        .command,
        .control,
        .option,
        .shift
    ]

    static func userModifiers(
        in modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        modifierFlags.intersection(userModifierMask)
    }
}

private enum NotchShellTransition {
    case expand
    case collapse

    var timingFunction: CAMediaTimingFunction {
        switch self {
        case .expand:
            return CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
        case .collapse:
            return CAMediaTimingFunction(controlPoints: 0.40, 0.0, 0.20, 1.0)
        }
    }
}

/// Retained transparent borderless panel hosting the clipboard UI.
@MainActor
final class NotchPanelController: NSObject, NSWindowDelegate {
    private(set) var panel: NotchKeyPanel?
    private var hostingView: NSHostingView<PanelRootView>?
    private var chromeView: NotchChromeView?

    private(set) var phase: PanelPresentationPhase = .hidden
    private var presentation = PresentationGeneration()
    /// Generation for open/content/focus completions.
    private(set) var openGeneration: UInt64 = 0
    /// Generation for close completions — invalidated on reopen or new open.
    private(set) var closeGeneration: UInt64 = 0
    /// Token for the in-flight selection paste; cleared when completion applies or is abandoned.
    private var selectionOperationToken: UInt64 = 0
    private var activeSelectionOperation: UInt64?
    private(set) var isDragging: Bool = false
    private(set) var isQuickLookActive: Bool = false
    /// Open generation captured when Quick Look staging/presentation begins (refocus policy).
    private var quickLookRefocusOpenGeneration: UInt64 = 0

    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var keyMonitor: Any?
    private var accessibilityObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    let history: HistoryModel
    let visualState = PanelVisualState()
    let dragController = HistoryDragController()
    let quickLook = QuickLookController()
    /// Presentation-scoped restore target; coordinator performs restore exactly once.
    private(set) var restoreApp: NSRunningApplication?
    var onDismiss: ((DismissReason) -> Void)?
    weak var engine: ClipboardEngine?

    private var reduceMotion: Bool = false
    private var reduceTransparency: Bool = false
    /// Screen metrics frozen at presentation start so dismiss collapses on the same display.
    private var presentationMetrics: ScreenMetrics?

    init(history: HistoryModel) {
        self.history = history
        super.init()
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        visualState.reduceMotion = reduceMotion
        visualState.reduceTransparency = reduceTransparency
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                self?.visualState.reduceMotion = self?.reduceMotion ?? false
                self?.visualState.reduceTransparency = self?.reduceTransparency ?? false
                self?.applyChromeMaterial()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.repositionIfVisible()
            }
        }
        dragController.onBegin = { [weak self] in self?.beginDragging() }
        dragController.onEnd = { [weak self] success in
            self?.handleDragEnded(success: success)
        }
        quickLook.onWillShow = { [weak self] in
            self?.isQuickLookActive = true
        }
        quickLook.onDidClose = { [weak self] in
            guard let self else { return }
            self.isQuickLookActive = false
            // Re-key parent only for the same visible/interactable presentation (never resurrect).
            let captured = self.quickLookRefocusOpenGeneration
            self.quickLookRefocusOpenGeneration = 0
            if QuickLookLifecyclePolicy.shouldRefocusParentAfterClose(
                capturedOpenGeneration: captured,
                currentOpenGeneration: self.openGeneration,
                phase: self.phase,
                windowIsVisible: self.panel?.isVisible == true
            ) {
                self.finishKeyAndFocus()
            }
        }
        buildPanelIfNeeded()
    }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func attach(engine: ClipboardEngine?) {
        self.engine = engine
        dragController.attach(engine: engine)
    }

    func shutdown() {
        history.setPanelVisible(false)
        quickLook.shutdown()
        removeMonitors()
    }

    var isVisible: Bool {
        panel?.isVisible == true && phase != .hidden
    }

    func beginDragging() {
        isDragging = true
    }

    func endDragging() {
        isDragging = false
    }

    private func handleDragEnded(success: Bool) {
        endDragging()
        if DragEndPolicy.shouldDismissAfterDrag(success: success) {
            if DragEndPolicy.shouldDismissAfterSuccessfulDrag(isPanelVisible: isVisible) {
                dismiss(reason: .dragCompleted)
            }
        } else if DragEndPolicy.shouldFinishKeyAfterCancel(
            isPanelVisible: isVisible,
            phase: phase
        ) {
            finishKeyAndFocus()
        }
    }

    // MARK: - Show / hide

    func toggle(restoreApp: NSRunningApplication?) {
        switch PanelPhasePolicy.toggleAction(for: phase) {
        case .show:
            show(restoreApp: restoreApp)
        case .dismiss:
            dismiss(reason: .hotkeyToggle)
        case .reopen:
            // Invalidate closing completions, then open a new generation.
            closeGeneration &+= 1
            show(restoreApp: restoreApp)
        }
    }

    func show(restoreApp: NSRunningApplication?) {
        buildPanelIfNeeded()
        guard let panel else { return }

        let isReversingCollapse = phase == .collapsing && panel.isVisible

        self.restoreApp = restoreApp
        // Gate link previews before any visible-row work / refresh side effects.
        // Search belongs to the complete library now; never let a stale legacy
        // query hide a quick-shelf selection.
        history.query = ""
        visualState.libraryTileSelected = false
        history.setPanelVisible(true)
        history.refresh()

        // New open generation invalidates both prior open and close completions.
        openGeneration = presentation.beginPresentation()
        closeGeneration &+= 1
        let token = openGeneration

        let metrics = isReversingCollapse
            ? (presentationMetrics ?? currentScreenMetrics())
            : currentScreenMetrics()
        presentationMetrics = metrics
        let expanded = PanelGeometry.expandedFrame(on: metrics)
        let plan = AnimationPlanner.plan(reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
        visualState.capWidth = PanelGeometry.capWidth(on: metrics)
        visualState.capHeight = max(PanelGeometry.compactMinHeight, metrics.topSafeInset > 0 ? metrics.topSafeInset : PanelGeometry.compactMinHeight)
        panel.setFrame(expanded, display: true)
        if !isReversingCollapse {
            visualState.resetForCompact()
            updateShellMask(for: panel.frame.size, metrics: metrics, progress: 0)
        }
        phase = .compact
        applyChromeMaterial()
        panel.alphaValue = plan.allowsGeometryAnimation ? 1 : 0
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        installMonitors()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard TransitionTokenPolicy.shouldApplyOpenCompletion(token: token, openGeneration: self.openGeneration) else { return }
            self.phase = .expanding

            if plan.allowsGeometryAnimation {
                self.visualState.contentOpacity = 0
                self.visualState.contentScale = 1
                self.animate(
                    to: expanded,
                    shellProgress: 1,
                    duration: plan.openDuration,
                    plan: plan,
                    transition: .expand,
                    openToken: token,
                    closeToken: nil
                ) { [weak self] in
                    guard let self else { return }
                    guard TransitionTokenPolicy.shouldApplyOpenCompletion(token: token, openGeneration: self.openGeneration) else { return }
                    self.phase = .expanded
                    self.finishKeyAndFocus()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + plan.openDuration * 0.48) { [weak self] in
                    guard let self else { return }
                    guard TransitionTokenPolicy.shouldApplyOpenCompletion(token: token, openGeneration: self.openGeneration) else { return }
                    self.animateContentIn(duration: plan.openDuration * 0.50, plan: plan)
                }
            } else {
                panel.setFrame(expanded, display: true)
                self.updateShellMask(for: expanded.size, metrics: metrics, progress: 1)
                self.visualState.shellProgress = 1
                self.animateContentIn(duration: plan.openDuration, plan: plan)
                self.phase = .expanded
                self.animatePanelAlpha(to: 1, duration: plan.openDuration) { [weak self] in
                    self?.finishKeyAndFocus()
                }
            }
        }
    }

    func dismiss(reason: DismissReason) {
        guard phase != .hidden else { return }

        if DragInteractionPolicy.shouldSuppressDismissWhileDragging(
            isDragging: isDragging,
            reason: reason
        ) {
            return
        }
        if isQuickLookActive, reason == .outsideClick { return }

        // Real parent dismiss: cancel/close Quick Look before collapse begins.
        // Clear refocus capture first so close callback cannot re-key a dismissing notch.
        if QuickLookLifecyclePolicy.shouldCancelQuickLookOnParentDismiss(
            isQuickLookActiveOrStaging: isQuickLookActive || quickLook.isActiveOrStaging,
            reason: reason
        ) {
            quickLookRefocusOpenGeneration = 0
            quickLook.close()
            isQuickLookActive = false
        }

        // Immediately invalidate outstanding open/content/focus completions.
        openGeneration &+= 1
        closeGeneration &+= 1
        // Abandon any in-flight selection completion for this presentation.
        activeSelectionOperation = nil
        let closeToken = closeGeneration

        // Any real dismissal begins: stop link fetches (rows stay mounted in hosting view).
        history.setPanelVisible(false)

        let plan = AnimationPlanner.plan(reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
        phase = .collapsing
        removeMonitors()

        let metrics = presentationMetrics ?? currentScreenMetrics()
        let compact = PanelGeometry.compactFrame(on: metrics)

        let contentFadeDuration = plan.allowsGeometryAnimation
            ? min(0.14, plan.closeDuration * 0.68)
            : plan.closeDuration
        animateContentOut(duration: contentFadeDuration, plan: plan)

        if !plan.allowsGeometryAnimation {
            animatePanelAlpha(to: 0, duration: plan.closeDuration) { [weak self] in
                guard let self else { return }
                guard TransitionTokenPolicy.shouldApplyCloseCompletion(
                    token: closeToken,
                    closeGeneration: self.closeGeneration
                ) else { return }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
                self.panel?.setFrame(compact, display: false)
                self.updateShellMask(for: compact.size, metrics: metrics, progress: 0)
                self.phase = .hidden
                self.presentationMetrics = nil
                self.visualState.applyCollapsedAppearance()
                self.onDismiss?(reason)
            }
            return
        }

        self.animate(
            to: PanelGeometry.expandedFrame(on: metrics),
            shellProgress: 0,
            duration: plan.closeDuration,
            plan: plan,
            transition: .collapse,
            openToken: nil,
            closeToken: closeToken
        ) { [weak self] in
            guard let self else { return }
            guard TransitionTokenPolicy.shouldApplyCloseCompletion(token: closeToken, closeGeneration: self.closeGeneration) else { return }

            self.panel?.orderOut(nil)
            self.panel?.setFrame(compact, display: false)
            self.updateShellMask(for: compact.size, metrics: metrics, progress: 0)
            self.phase = .hidden
            self.presentationMetrics = nil
            self.visualState.applyCollapsedAppearance()
            self.onDismiss?(reason)
        }
    }

    private func finishKeyAndFocus() {
        let windowVisible = panel?.isVisible == true
        guard FinishKeyFocusPolicy.shouldMakeKeyAndFocus(
            phase: phase,
            windowIsVisible: windowVisible
        ) else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(hostingView)
        visualState.requestSearchFocus()
    }

    private func handleSelectionCopy() {
        if isDragging { return }
        if visualState.libraryTileSelected {
            dismiss(reason: .openLibrary)
            return
        }
        // Repeated Return while an operation is active is ignored.
        if activeSelectionOperation != nil || history.isPasteInFlight { return }
        guard let selectedID = history.selectedID,
              history.quickShelf.contains(where: { $0.id == selectedID }) else {
            history.prepareQuickShelfSelection()
            return
        }

        selectionOperationToken &+= 1
        let opToken = selectionOperationToken
        let capturedOpen = openGeneration
        activeSelectionOperation = opToken

        let started = history.paste(entryID: selectedID) { [weak self] written, error in
            guard let self else { return }
            let apply = SelectionCopyCompletionPolicy.shouldApplyCompletion(
                operationToken: opToken,
                activeOperationToken: self.activeSelectionOperation,
                capturedOpenGeneration: capturedOpen,
                currentOpenGeneration: self.openGeneration,
                isPanelStillVisible: self.isVisible
            )
            // Always clear gate when this was the active op (even if presentation is stale).
            if self.activeSelectionOperation == opToken {
                self.activeSelectionOperation = nil
            }
            guard apply else { return }
            if SelectionCopyPolicy.shouldDismiss(written: written, error: error) {
                self.dismiss(reason: .selection)
            } else {
                if let error {
                    self.history.setCaptureError(error.localizedDescription)
                } else if written == 0 {
                    self.history.setCaptureError("Could not copy this item to the clipboard.")
                }
            }
        }
        if !started {
            activeSelectionOperation = nil
        }
    }

    private func handleQuickLook() {
        // Space while staging/active toggles closed cleanly.
        if quickLook.isActiveOrStaging || isQuickLookActive {
            quickLook.close()
            isQuickLookActive = false
            return
        }
        guard let selectedID = history.selectedID,
              let entry = history.quickShelf.first(where: { $0.id == selectedID }) else { return }
        let route = QuickLookPolicy.route(for: entry)
        switch route {
        case .unsupported(let message), .missingFiles(let message):
            history.setCaptureError(message)
            return
        case .fileURLs, .materializeRetainedImage:
            break
        }
        // Treat staging as active so outside-click / key-resign cannot dismiss or steal focus.
        quickLookRefocusOpenGeneration = openGeneration
        isQuickLookActive = true
        quickLook.present(route: route, entry: entry, engine: engine) { [weak self] errorMessage in
            guard let self else { return }
            if let errorMessage {
                self.isQuickLookActive = false
                self.quickLookRefocusOpenGeneration = 0
                self.history.setCaptureError(errorMessage)
            } else if !self.quickLook.isActiveOrStaging {
                // Clean cancel without a lasting presentation.
                self.isQuickLookActive = false
            } else {
                self.isQuickLookActive = true
            }
        }
    }

    // MARK: - Panel construction

    private func buildPanelIfNeeded() {
        if panel != nil { return }

        let style: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
        let panel = NotchKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.isQuickLookActive || self.quickLook.isActiveOrStaging {
                self.quickLook.close()
                self.isQuickLookActive = false
            } else {
                self.dismiss(reason: .escape)
            }
        }

        let chrome = NotchChromeView(frame: .zero)
        chrome.autoresizingMask = [.width, .height]

        let root = PanelRootView(
            history: history,
            visualState: visualState,
            dragController: dragController,
            onSelect: { [weak self] in
                self?.handleSelectionCopy()
            },
            onOpenLibrary: { [weak self] in
                self?.dismiss(reason: .openLibrary)
            },
            onEscape: { [weak self] in
                guard let self else { return }
                if self.isQuickLookActive || self.quickLook.isActiveOrStaging {
                    self.quickLook.close()
                    self.isQuickLookActive = false
                } else {
                    self.dismiss(reason: .escape)
                }
            },
            onBeginDrag: { [weak self] in self?.beginDragging() },
            onEndDrag: { [weak self] in self?.endDragging() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = chrome.bounds
        hosting.autoresizingMask = [.width, .height]
        chrome.addSubview(hosting)

        panel.contentView = chrome
        self.panel = panel
        self.hostingView = hosting
        self.chromeView = chrome
        applyChromeMaterial()
    }

    private func applyChromeMaterial() {
        let plan = AnimationPlanner.plan(reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
        chromeView?.preferOpaque = plan.preferOpaqueChrome
    }

    private func updateShellMask(for size: CGSize, metrics: ScreenMetrics, progress: CGFloat) {
        let capW = PanelGeometry.capWidth(on: metrics)
        let capH = max(PanelGeometry.compactMinHeight, metrics.hasNotch ? metrics.topSafeInset : PanelGeometry.compactMinHeight)
        chromeView?.updateShell(width: capW, height: capH, attachesToNotch: metrics.hasNotch)
        chromeView?.shellProgress = progress
        visualState.shellProgress = progress
        visualState.capWidth = capW
        visualState.capHeight = capH
        _ = size
    }

    private func animate(
        to frame: CGRect,
        shellProgress: CGFloat,
        duration: TimeInterval,
        plan: AnimationPlan,
        transition: NotchShellTransition,
        openToken: UInt64?,
        closeToken: UInt64?,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let panel else {
            Task { @MainActor in completion() }
            return
        }
        let metrics = presentationMetrics ?? currentScreenMetrics()
        if plan.allowsGeometryAnimation {
            // Keep the transparent hosting window stable and animate only the shell mask.
            // Resizing both the window and the mask multiplies progress and causes a snap.
            panel.setFrame(frame, display: true)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = transition.timingFunction
                self.chromeView?.animator().shellProgress = shellProgress
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if let openToken,
                       !TransitionTokenPolicy.shouldApplyOpenCompletion(
                        token: openToken,
                        openGeneration: self.openGeneration
                       ) {
                        return
                    }
                    if let closeToken,
                       !TransitionTokenPolicy.shouldApplyCloseCompletion(
                        token: closeToken,
                        closeGeneration: self.closeGeneration
                       ) {
                        return
                    }
                    self.updateShellMask(for: frame.size, metrics: metrics, progress: shellProgress)
                    completion()
                }
            })
        } else {
            panel.setFrame(frame, display: true)
            updateShellMask(for: frame.size, metrics: metrics, progress: shellProgress)
            Task { @MainActor in completion() }
        }
    }

    private func animatePanelAlpha(
        to value: CGFloat,
        duration: TimeInterval,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let panel else {
            Task { @MainActor in completion() }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = value
        }, completionHandler: {
            Task { @MainActor in completion() }
        })
    }

    private func animateContentIn(duration: TimeInterval, plan: AnimationPlan) {
        visualState.contentScale = 1
        let animation: Animation = plan.allowsGeometryAnimation
            ? .easeOut(duration: min(0.16, duration))
            : .easeOut(duration: duration)
        withAnimation(animation) {
            visualState.contentOpacity = 1
            visualState.contentScale = 1
            visualState.shellProgress = 1
        }
    }

    private func animateContentOut(duration: TimeInterval, plan: AnimationPlan) {
        let animation: Animation = .easeOut(duration: duration)
        withAnimation(animation) {
            visualState.contentOpacity = 0
            visualState.contentScale = 1
        }
    }

    private func repositionIfVisible() {
        guard phase == .expanded || phase == .expanding || phase == .compact, let panel else { return }
        let screens = NSScreen.screens.map { Self.metrics(from: $0) }
        let frozen = presentationMetrics
        let stillValid: Bool = {
            guard let frozen else { return false }
            return screens.contains { screen in
                screen.frame.intersects(frozen.frame) || screen.frame == frozen.frame
            }
        }()
        let metrics: ScreenMetrics
        if stillValid, let frozen {
            metrics = frozen
        } else {
            metrics = currentScreenMetrics()
            presentationMetrics = metrics
        }
        let frame = (phase == .compact)
            ? PanelGeometry.compactFrame(on: metrics)
            : PanelGeometry.expandedFrame(on: metrics)
        panel.setFrame(frame, display: true)
        updateShellMask(for: frame.size, metrics: metrics, progress: phase == .compact ? 0 : 1)
    }

    // MARK: - Screens

    private func currentScreenMetrics() -> ScreenMetrics {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens.map { Self.metrics(from: $0) }
        let primary = NSScreen.main.map { Self.metrics(from: $0) }
        return PanelGeometry.screen(containing: mouse, candidates: screens, fallback: primary)
            ?? ScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
            )
    }

    static func metrics(from screen: NSScreen) -> ScreenMetrics {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let topInset = screen.safeAreaInsets.top
        // `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are optional on some SDKs.
        let leftW = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightW = screen.auxiliaryTopRightArea?.width ?? 0
        let fallback = min(200, frame.width * 0.14)
        let notchW: CGFloat? = topInset > 0
            ? PanelGeometry.inferredNotchWidth(
                screenWidth: frame.width,
                auxiliaryTopLeftWidth: leftW,
                auxiliaryTopRightWidth: rightW,
                fallback: fallback
            )
            : nil
        return ScreenMetrics(
            frame: frame,
            visibleFrame: visible,
            topSafeInset: topInset,
            notchWidth: notchW
        )
    }

    // MARK: - Monitors

    private func installMonitors() {
        removeMonitors()
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleMouseDown(event)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.panel?.isKeyWindow == true else { return event }
            // Command-F hands off to the full searchable library. Other
            // command-like shortcuts remain available to AppKit/SwiftUI.
            let flags = NotchKeyboardEventPolicy.userModifiers(
                in: event.modifierFlags
            )
            if flags == .command,
               event.charactersIgnoringModifiers?.lowercased() == "f" {
                self.dismiss(reason: .openLibrary)
                return nil
            }
            if !flags.isEmpty && flags != .shift { return event }

            switch event.keyCode {
            case 53: // Escape
                if self.isDragging { return nil }
                if self.isQuickLookActive || self.quickLook.isActiveOrStaging {
                    self.quickLook.close()
                    self.isQuickLookActive = false
                    return nil
                }
                self.dismiss(reason: .escape)
                return nil
            case 123, 126: // Left / Up
                if self.isDragging { return nil }
                if self.visualState.libraryTileSelected {
                    self.visualState.libraryTileSelected = false
                    self.history.selectedID = self.history.quickShelf.last?.id
                } else {
                    self.history.selectPreviousOnQuickShelf()
                }
                return nil
            case 124, 125: // Right / Down
                if self.isDragging { return nil }
                if !self.visualState.libraryTileSelected {
                    let shelf = self.history.quickShelf
                    if shelf.isEmpty || self.history.selectedID == shelf.last?.id {
                        self.visualState.libraryTileSelected = true
                    } else {
                        self.history.selectNextOnQuickShelf()
                    }
                }
                return nil
            case 36, 76: // Return / keypad Enter
                if self.isDragging { return nil }
                self.handleSelectionCopy()
                return nil
            case 49: // Space — Quick Look when not typing into search
                if self.isDragging { return nil }
                if flags.contains(.shift) { return event }
                if self.visualState.libraryTileSelected { return nil }
                if !self.history.query.isEmpty { return event }
                self.handleQuickLook()
                return nil
            default:
                return event
            }
        }
    }

    private func removeMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard isVisible else { return }
        guard !isDragging, !isQuickLookActive else { return }
        guard let panel else { return }
        let location = NSEvent.mouseLocation
        if !panel.frame.contains(location) {
            let gen = openGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.openGeneration == gen else { return }
                self.dismiss(reason: .outsideClick)
            }
        }
        _ = event
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        guard !isDragging, !isQuickLookActive else { return }
        let gen = openGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.openGeneration == gen else { return }
            if self.panel?.isKeyWindow == false, !self.isQuickLookActive {
                self.dismiss(reason: .outsideClick)
            }
        }
    }
}
