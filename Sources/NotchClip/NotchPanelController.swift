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

    /// Spring constants (mass 1) per axis. These springs are the *only* curves
    /// shaping the motion, since `shellLayout` is linear in each channel.
    typealias Spec = (stiffness: CGFloat, damping: CGFloat)

    /// The width channel leads. ζ ≈ 0.98 has no measurable overshoot and settles
    /// in 0.362 s — about 16 % ahead of the height — so the panel reaches its
    /// full width while it is still filling downward. The shape blooms sideways
    /// and the weight arrives after it, which is what stops the old
    /// single-scalar version from growing along a perfect diagonal.
    ///
    /// Damping is deliberately just *under* critical: `settlingDuration` is not
    /// monotonic in damping near ζ = 1 (measured: 600/48 settles in 0.362 s,
    /// but 620/50 at ζ = 1.004 jumps to 0.400 s), so overdamping to "guarantee"
    /// no overshoot would make the width slower than the height and invert the
    /// bloom.
    var widthSpec: Spec {
        switch self {
        case .expand: return (600, 48)    // ζ 0.980, settles 0.362 s
        case .collapse: return (560, 47)  // ζ 0.993, settles 0.390 s
        }
    }

    /// The height channel keeps the approved open character: ω₀ = √480 ≈ 21.9,
    /// ζ = 36/(2ω₀) ≈ 0.82 → peak ≈ 1.011. With the width already at rest that
    /// 1 % now reads as a downward swell — weight settling — rather than as the
    /// whole panel bouncing. ζ ≈ 0.73 overshot ~3 % and was rejected as elastic.
    ///
    /// On the way in the height leads instead (mirror of the open), but only
    /// just: 0.358 s against the width's 0.390 s. Both are ζ ≈ 0.99, because a
    /// bounce on dismissal reads as hesitation.
    var heightSpec: Spec {
        switch self {
        case .expand: return (480, 36)    // ζ 0.822, peak 1.011, settles 0.433 s
        case .collapse: return (660, 51)  // ζ 0.993, settles 0.358 s
        }
    }

    /// Displays with no notch scale uniformly, so there is no bloom to split —
    /// both channels ride this one spring, which is the pre-bloom character.
    var uniformSpec: Spec {
        switch self {
        case .expand: return (480, 36)
        case .collapse: return (560, 47)
        }
    }

    /// Settling time of the height axis. The *open's* content choreography is
    /// keyed to this and not to the width, which is ~16 % shorter by
    /// construction.
    var heightSettlingDuration: TimeInterval {
        Self.spring(keyPath: "shellProgressY", spec: heightSpec, from: 0, to: 1, velocity: 0)
            .settlingDuration
    }

    var widthSettlingDuration: TimeInterval {
        Self.spring(keyPath: "shellProgressX", spec: widthSpec, from: 0, to: 1, velocity: 0)
            .settlingDuration
    }

    /// When the shell has finished moving on *both* axes — which is when the
    /// animation group completes and the window is ordered out.
    ///
    /// The close's fade is keyed to this rather than to the height, because the
    /// axes swap roles on the way in: the height leads the collapse (0.358 s)
    /// and the width trails it (0.390 s), so a height-keyed fade would empty the
    /// shell ~32 ms before it actually finished closing.
    var shellSettlingDuration: TimeInterval {
        max(widthSettlingDuration, heightSettlingDuration)
    }

    /// Settling time of the uniform (detached) spring.
    var uniformSettlingDuration: TimeInterval {
        Self.spring(keyPath: "shellProgressY", spec: uniformSpec, from: 0, to: 1, velocity: 0)
            .settlingDuration
    }

    /// A normalized velocity beyond this is a sampling artefact, not motion.
    private static let maxNormalizedVelocity: CGFloat = 80

    /// Builds one channel's spring, seeded with the shell's current speed so an
    /// interrupted transition is retargeted rather than restarted.
    ///
    /// `initialVelocity` is normalized by the distance still to travel and is
    /// signed relative to the *target*, so motion away from it is negative.
    /// Measured, not assumed: animating 0.4 → 0 with -7.5 makes the value climb
    /// past 0.4 before turning around, which is exactly a reversal that keeps
    /// its momentum.
    static func spring(
        keyPath: String,
        spec: Spec,
        from current: CGFloat,
        to target: CGFloat,
        velocity: CGFloat
    ) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = spec.stiffness
        spring.damping = spec.damping
        let distance = target - current
        if abs(distance) > 0.0001, velocity != 0 {
            let normalized = velocity / distance
            spring.initialVelocity = min(
                max(normalized, -maxNormalizedVelocity),
                maxNormalizedVelocity
            )
        } else {
            spring.initialVelocity = 0
        }
        // settlingDuration accounts for the initial velocity, so read it last.
        spring.duration = spring.settlingDuration
        return spring
    }

    /// Both channels for this transition, seeded from the shell's current state.
    func springs(
        uniform: Bool,
        fromX: CGFloat,
        fromY: CGFloat,
        velocityX: CGFloat,
        velocityY: CGFloat,
        to target: CGFloat
    ) -> (x: CASpringAnimation, y: CASpringAnimation) {
        let xSpec = uniform ? uniformSpec : widthSpec
        let ySpec = uniform ? uniformSpec : heightSpec
        return (
            Self.spring(
                keyPath: "shellProgressX",
                spec: xSpec,
                from: fromX,
                to: target,
                velocity: velocityX
            ),
            Self.spring(
                keyPath: "shellProgressY",
                spec: ySpec,
                from: fromY,
                to: target,
                velocity: velocityY
            )
        )
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
    /// When the content's fade-in finishes on screen. `contentOpacity` cannot
    /// answer that — `withAnimation` moves the model value to 1 the instant the
    /// fade starts — and the collapse needs to know, because holding the
    /// fade-out back is only right for content that is already fully up.
    private var contentFadeInEnd: CFTimeInterval = 0
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
        // Each presentation starts from an unfiltered view so a stale query can
        // never hide the clip the user just copied.
        history.query = ""
        history.scope = .all
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
        let expanded = PanelGeometry.windowFrame(on: metrics)
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
        // A notched shell is continuous with the housing, so it is opaque from
        // the first frame. A detached shell has no anchor and must fade in, or
        // it reads as a rectangle popping into existence.
        let fadesIn = !plan.allowsGeometryAnimation || !metrics.hasNotch
        panel.alphaValue = fadesIn ? 0 : 1
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
                // Content timing is derived from the shell spring's own settling
                // duration, not from plan.openDuration. Those had drifted apart
                // once the spring replaced the bezier — the shell arrived while
                // the text was still fading, which reads as two separate
                // animations rather than one object opening.
                //
                // Keyed to the height axis specifically: on the way open it is
                // the longer of the two channels and the one the eye tracks, and
                // every ratio below was calibrated against it. Keying off the
                // width would shorten them all by ~16 % for no reason. (The
                // collapse is the other way round, and keys off the slower axis
                // explicitly — see `shellSettlingDuration`.)
                let shellDuration = NotchShellTransition.expand.heightSettlingDuration
                if !metrics.hasNotch {
                    // Fade completes early so the panel is solid while the
                    // spring is still settling — the scale carries the motion.
                    self.animatePanelAlpha(to: 1, duration: shellDuration * 0.45) {}
                }
                // The fade now starts while the shell is still small, where it
                // used to wait for real area (0.26). It can: the content is
                // carrying the shell's scale and blurring off, so there is no
                // flat block to pop in — the motion is what hides the arrival,
                // and holding the fade back only made the content look pasted on
                // afterwards. It still lands (0.14 + 0.62 ≈ 0.76 of the settle)
                // before the spring's final micro-settle, so the content is in
                // place and sharp as the shape stops moving — and comfortably
                // before the completion handler takes focus, so the search field
                // is never keyed while still blurred.
                DispatchQueue.main.asyncAfter(deadline: .now() + shellDuration * 0.14) { [weak self] in
                    guard let self else { return }
                    guard TransitionTokenPolicy.shouldApplyOpenCompletion(token: token, openGeneration: self.openGeneration) else { return }
                    self.animateContentIn(duration: shellDuration * 0.62, plan: plan)
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

        if !plan.allowsGeometryAnimation {
            // Reduce Motion: nothing moves, so the fade *is* the dismissal and
            // has to run for its whole duration, starting now.
            animateContentOut(duration: plan.closeDuration, plan: plan)
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

        // Detached shells ride one uniform spring; notched ones finish when the
        // slower of the two axes does, which is when the group completes and the
        // window is ordered out.
        let collapseDuration = metrics.hasNotch
            ? NotchShellTransition.collapse.shellSettlingDuration
            : NotchShellTransition.collapse.uniformSettlingDuration

        // Detached shells scale back down; without a matching fade they would
        // vanish abruptly at their smallest scale instead of dissolving.
        if !metrics.hasNotch {
            animatePanelAlpha(to: 0, duration: collapseDuration * 0.85) {}
        }

        // The content used to fade out in ≤ 0.14 s against a ~0.36 s collapse,
        // so the back two thirds of every dismissal was an empty black slab
        // shrinking into the notch. It now rides the shell down (that falls out
        // of the progress-derived transform) and only gives up its opacity over
        // roughly the last 40 %, landing just before the shell stops. Delayed,
        // so it must carry the close token: a reopen part-way through the
        // collapse bumps `closeGeneration` and this never fires, leaving the
        // content visible for the reversal instead of blinking out behind it.
        if CACurrentMediaTime() >= contentFadeInEnd {
            DispatchQueue.main.asyncAfter(deadline: .now() + collapseDuration * 0.58) { [weak self] in
                guard let self else { return }
                guard TransitionTokenPolicy.shouldApplyCloseCompletion(
                    token: closeToken,
                    closeGeneration: self.closeGeneration
                ) else { return }
                self.animateContentOut(duration: collapseDuration * 0.38, plan: plan)
            }
        } else {
            // Dismissed while the content was still fading *in*. Waiting would
            // let it go on brightening all the way into the notch, which reads
            // as the panel arguing with itself. Take it from wherever it is.
            animateContentOut(duration: min(0.14, collapseDuration * 0.38), plan: plan)
        }

        self.animate(
            to: PanelGeometry.windowFrame(on: metrics),
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
            self.panel?.alphaValue = 1
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

    private func handleSelectionCopy(shiftHeld: Bool = false) {
        if isDragging { return }
        // Repeated Return while an operation is active is ignored.
        if activeSelectionOperation != nil || history.isPasteInFlight { return }
        guard let selectedID = history.selectedID,
              history.projection.contains(id: selectedID) else {
            history.prepareSelection()
            return
        }

        selectionOperationToken &+= 1
        let opToken = selectionOperationToken
        let capturedOpen = openGeneration
        activeSelectionOperation = opToken

        let started = history.paste(
            entryID: selectedID,
            plainText: history.usesPlainText(shiftHeld: shiftHeld)
        ) { [weak self] written, error in
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
              let entry = history.projection.entry(id: selectedID) else { return }
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
        // The chrome draws its own shadow, ramped with the shell's progress.
        // AppKit's window shadow is derived from the window *shape* and is only
        // recomputed on resize or `invalidateShadow()`; the shell transition
        // animates a mask inside a fixed frame, so the window shadow would be
        // frozen in the compact cap's outline for the whole presentation.
        panel.hasShadow = false
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
        // Depth ramps with the shell instead of arriving finished under it; see
        // `panel.hasShadow` above for why AppKit's own shadow cannot do this.
        chrome.drawsShadow = true
        // The panel's window reserves room above the resting shell on notch-less
        // displays, which is what the detached open's downward settle moves
        // through. `windowFrame` reserves the matching margin.
        chrome.detachedTopHeadroom = PanelGeometry.detachedTopHeadroom

        let root = PanelRootView(
            history: history,
            visualState: visualState,
            dragController: dragController,
            onSelect: { [weak self] in
                self?.handleSelectionCopy()
            },
            onSelectAlternate: { [weak self] in
                self?.handleSelectionCopy(shiftHeld: true)
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
        hosting.frame = chrome.restingRect
        chrome.setContentHost(hosting)

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
        // Direct, unanimated: also discards sampled velocity, so a later
        // transition doesn't inherit momentum from a jump.
        chromeView?.setShellProgress(x: progress, y: progress)
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
        if plan.allowsGeometryAnimation, let chrome = chromeView {
            // Keep the transparent hosting window stable and animate only the shell mask.
            // Resizing both the window and the mask multiplies progress and causes a snap.
            panel.setFrame(frame, display: true)
            // Install the direction-specific springs, one per axis, each seeded
            // with that channel's current speed. AppKit drives both properties
            // through them, overshoot included.
            //
            // Never short-circuit when the target is unchanged: the completion
            // closure is what advances `phase` and takes focus, and `show()` has
            // already invalidated the in-flight animation's own completion by
            // bumping `openGeneration`. Restarting is safe precisely because the
            // velocity carries over — retargeting a linear spring to the same
            // target from the same state continues the same trajectory.
            let springs = transition.springs(
                uniform: !metrics.hasNotch,
                fromX: chrome.shellProgressX,
                fromY: chrome.shellProgressY,
                velocityX: chrome.widthVelocity,
                velocityY: chrome.heightVelocity,
                to: shellProgress
            )
            chrome.animations = [
                "shellProgressX": springs.x,
                "shellProgressY": springs.y
            ]
            NSAnimationContext.runAnimationGroup({ ctx in
                // Measured: each property honours its own animation's duration
                // even inside one group, so the group only needs to outlast the
                // slower channel for the completion to fire at the right time.
                ctx.duration = max(springs.x.settlingDuration, springs.y.settlingDuration)
                chrome.animator().shellProgressX = shellProgress
                chrome.animator().shellProgressY = shellProgress
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

    /// Opacity only — and the blur derived from it. The content's *motion* is
    /// not here: it comes off the shell's own progress in `NotchChromeView`, so
    /// there is no second animation that could fall out of step with the spring.
    ///
    /// No ceiling on the duration: the caller derives it from the shell spring,
    /// and clamping it here is what let the two drift apart.
    private func animateContentIn(duration: TimeInterval, plan: AnimationPlan) {
        contentFadeInEnd = CACurrentMediaTime() + duration
        withAnimation(.easeOut(duration: duration)) {
            visualState.contentOpacity = 1
            visualState.shellProgress = 1
        }
    }

    private func animateContentOut(duration: TimeInterval, plan: AnimationPlan) {
        withAnimation(.easeOut(duration: duration)) {
            visualState.contentOpacity = 0
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
            : PanelGeometry.windowFrame(on: metrics)
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
            let flags = NotchKeyboardEventPolicy.userModifiers(in: event.modifierFlags)

            if flags == .command {
                return self.handleCommandKey(event)
            }
            if flags == .option {
                return self.handleOptionKey(event)
            }
            // Anything else with a real modifier belongs to AppKit/SwiftUI.
            if !flags.isEmpty && flags != .shift { return event }

            switch event.keyCode {
            case 53: // Escape — narrow the surface before closing it.
                if self.isDragging { return nil }
                if self.isQuickLookActive || self.quickLook.isActiveOrStaging {
                    self.quickLook.close()
                    self.isQuickLookActive = false
                    return nil
                }
                if !self.history.query.isEmpty {
                    self.history.query = ""
                    return nil
                }
                if self.history.scope != .all {
                    self.history.scope = .all
                    return nil
                }
                self.dismiss(reason: .escape)
                return nil

            case 126: // Up
                if self.isDragging { return nil }
                self.history.selectPrevious()
                return nil

            case 125: // Down
                if self.isDragging { return nil }
                self.history.selectNext()
                return nil

            case 116: // Page Up
                if self.isDragging { return nil }
                self.history.selectByPage(-1)
                return nil

            case 121: // Page Down
                if self.isDragging { return nil }
                self.history.selectByPage(1)
                return nil

            case 115: // Home
                if self.isDragging { return nil }
                self.history.selectFirst()
                return nil

            case 119: // End
                if self.isDragging { return nil }
                self.history.selectLast()
                return nil

            case 36, 76: // Return / keypad Enter — ⇧ inverts the plain-text preference.
                if self.isDragging { return nil }
                self.handleSelectionCopy(shiftHeld: flags.contains(.shift))
                return nil

            default:
                // Everything else (including Space and all typing) goes to the
                // search field, which holds focus for the whole presentation.
                return event
            }
        }
    }

    /// ⌘-shortcuts owned by the panel. Unhandled ones fall through to SwiftUI.
    private func handleCommandKey(_ event: NSEvent) -> NSEvent? {
        let character = event.charactersIgnoringModifiers?.lowercased()

        // ⌘1–⌘9 paste the Nth visible row outright. Plain digits still type into
        // the search field, which holds focus for the whole presentation.
        if let character, let ordinal = Int(character),
           let entry = history.projection.entry(atOrdinal: ordinal) {
            // Checked before moving the selection: a repeat while a paste is
            // already running must not leave the highlight on a row it skipped.
            guard !isDragging, activeSelectionOperation == nil, !history.isPasteInFlight else {
                return nil
            }
            history.selectedID = entry.id
            handleSelectionCopy()
            return nil
        }

        switch character {
        case "f":
            // Search lives here now; ⌘F just returns focus to the field.
            visualState.requestSearchFocus()
            return nil
        case "y":
            // Quick Look the selection (⌘Y matches Finder).
            handleQuickLook()
            return nil
        case "p":
            if let id = history.selectedID { history.togglePin(id: id) }
            return nil
        case "delete", "\u{8}", "\u{7F}":
            if let id = history.selectedID { history.delete(id: id) }
            return nil
        default:
            return event
        }
    }

    /// ⌥1–⌥6 select a content filter; ⌘1–⌘9 now paste by row position.
    private func handleOptionKey(_ event: NSEvent) -> NSEvent? {
        // Option remaps typed characters (⌥1 → "¡"), so read the un-modified key.
        guard let digit = Int(event.charactersIgnoringModifiers ?? ""),
              let scope = ClipScope.scope(forShortcutNumber: digit) else {
            return event
        }
        history.scope = scope
        return nil
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
        // The window is larger than the visible shell (overshoot headroom), so
        // hit-test the resting rect or a click in the margin would be ignored.
        // Detached presentations also carry headroom above the shell; without
        // subtracting it, clicks in the strip just above the panel would count
        // as inside and stop dismissing it.
        let hasNotch = presentationMetrics?.hasNotch ?? true
        var visible = panel.frame.insetBy(dx: PanelGeometry.overshootHeadroomX, dy: 0)
        visible.origin.y += PanelGeometry.overshootHeadroomBottom
        visible.size.height -= PanelGeometry.overshootHeadroomBottom
            + PanelGeometry.topHeadroom(hasNotch: hasNotch)
        if !visible.contains(location) {
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
