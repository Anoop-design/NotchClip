import Foundation

/// Why the clipboard panel is closing.
public enum DismissReason: String, Equatable, Sendable, CaseIterable {
    /// User selected an item (paste to clipboard).
    case selection
    /// Escape while panel is key.
    case escape
    /// Global hotkey or menu Show Clipboard toggled closed.
    case hotkeyToggle
    /// Click outside the panel.
    case outsideClick
    /// Drag session completed to an external destination.
    case dragCompleted
    /// The quick shelf is handing off to the complete history library.
    case openLibrary
    /// Internal/programmatic hide.
    case programmatic
}

/// Pure focus / dismissal policy for the panel (unit-testable).
public enum DismissPolicy {
    /// Whether to reactivate the remembered external app after dismiss.
    public static func shouldRestorePreviousApp(_ reason: DismissReason) -> Bool {
        switch reason {
        case .selection, .escape, .hotkeyToggle:
            return true
        case .outsideClick, .dragCompleted, .openLibrary, .programmatic:
            return false
        }
    }

    /// Outside-click / resign-key must not dismiss while a drag is active.
    public static func shouldSuppressOutsideDismiss(isDragging: Bool) -> Bool {
        isDragging
    }

    /// Escape is only handled while the panel itself is key.
    public static func shouldConsumeEscape(panelIsKey: Bool) -> Bool {
        panelIsKey
    }

    /// A delayed completion for generation `token` is stale if a newer presentation is active.
    public static func isStaleCompletion(token: UInt64, current: PresentationGeneration) -> Bool {
        !current.isCurrent(token)
    }

    /// Rapid show-hide-show: only the latest generation may order the panel out.
    public static func shouldOrderOut(token: UInt64, current: PresentationGeneration, isVisible: Bool) -> Bool {
        isVisible && current.isCurrent(token)
    }

    /// Restore the previous app at most once per presentation (coordinator-owned).
    public static func shouldPerformRestore(
        reason: DismissReason,
        alreadyRestored: Bool
    ) -> Bool {
        !alreadyRestored && shouldRestorePreviousApp(reason)
    }
}

/// Toggle intent derived purely from presentation phase (unit-testable).
public enum PanelToggleAction: Equatable, Sendable {
    /// Panel is hidden — begin a new presentation.
    case show
    /// Panel is interactive — start dismiss.
    case dismiss
    /// Panel is mid-collapse — bump generation and reopen without waiting for order-out.
    case reopen
}

public enum PanelPhasePolicy {
    /// hidden → show; compact/expanding/expanded → dismiss; collapsing → reopen.
    public static func toggleAction(for phase: PanelPresentationPhase) -> PanelToggleAction {
        switch phase {
        case .hidden:
            return .show
        case .compact, .expanding, .expanded:
            return .dismiss
        case .collapsing:
            return .reopen
        }
    }
}

/// Pure selection-copy completion policy (async paste).
public enum SelectionCopyPolicy {
    /// Dismiss only after a successful non-zero write with no error.
    public static func shouldDismiss(written: Int, error: Error?) -> Bool {
        error == nil && written > 0
    }
}

/// Pure selection-copy completion-token policy: presentation + operation must still match.
public enum SelectionCopyCompletionPolicy {
    /// Whether a paste completion may dismiss / surface an error for the originating presentation.
    public static func shouldApplyCompletion(
        operationToken: UInt64,
        activeOperationToken: UInt64?,
        capturedOpenGeneration: UInt64,
        currentOpenGeneration: UInt64,
        isPanelStillVisible: Bool
    ) -> Bool {
        guard isPanelStillVisible else { return false }
        guard let active = activeOperationToken, active == operationToken else { return false }
        return capturedOpenGeneration == currentOpenGeneration
    }

    /// Whether `pasteSelected` may start a new operation (single-flight gate).
    public static func shouldStartPaste(isPasteInFlight: Bool) -> Bool {
        !isPasteInFlight
    }
}

/// Pure gates for the app-side automatic Command-V delivery that follows a
/// successful selection copy. The AppKit dispatcher owns activation, trust,
/// timeout, and event posting; these helpers keep lifecycle decisions testable.
public enum PasteDeliveryPolicy {
    /// Automatic paste may begin only for the first completed selection
    /// dismissal of a presentation, and only when its captured target exists.
    public static func shouldStart(
        reason: DismissReason,
        hasTarget: Bool,
        alreadyRestored: Bool
    ) -> Bool {
        reason == .selection && hasTarget && !alreadyRestored
    }

    /// A delayed dispatcher step is current only while its generation matches.
    public static func isCurrent(token: UInt64, generation: UInt64) -> Bool {
        token == generation
    }

    /// Command-V must only be emitted while the captured target is frontmost.
    public static func isTargetFrontmost(targetPID: Int32, frontmostPID: Int32?) -> Bool {
        targetPID > 0 && frontmostPID == targetPID
    }
}

/// Pure drag-session end / focus policy (unit-testable, no AppKit).
public enum DragEndPolicy {
    /// Successful external drop closes without app restore; cancel keeps panel open.
    public static func shouldDismissAfterDrag(success: Bool) -> Bool {
        success
    }

    public static func shouldRestoreAfterDrag(success: Bool) -> Bool {
        false
    }

    /// Cancel/fail: re-key only when the same presentation is still visible/interactable.
    public static func shouldFinishKeyAfterCancel(
        isPanelVisible: Bool,
        phase: PanelPresentationPhase
    ) -> Bool {
        isPanelVisible && (phase == .compact || phase == .expanding || phase == .expanded)
    }

    /// Successful dragCompleted: dismiss only if the panel is still ordered in / presenting.
    public static func shouldDismissAfterSuccessfulDrag(isPanelVisible: Bool) -> Bool {
        isPanelVisible
    }
}

/// Pure guard for `finishKeyAndFocus` (must never resurrect a hidden/collapsing panel).
public enum FinishKeyFocusPolicy {
    public static func shouldMakeKeyAndFocus(
        phase: PanelPresentationPhase,
        windowIsVisible: Bool
    ) -> Bool {
        guard windowIsVisible else { return false }
        switch phase {
        case .compact, .expanding, .expanded:
            return true
        case .hidden, .collapsing:
            return false
        }
    }
}

/// While a drag is active, suppress competing dismiss paths (hotkey, Escape, outside-click, selection).
public enum DragInteractionPolicy {
    public static func shouldSuppressDismissWhileDragging(
        isDragging: Bool,
        reason: DismissReason
    ) -> Bool {
        guard isDragging else { return false }
        switch reason {
        case .dragCompleted, .programmatic:
            return false
        case .selection, .escape, .hotkeyToggle, .outsideClick, .openLibrary:
            return true
        }
    }
}

/// Pure Quick Look routing (no UI).
public enum QuickLookRoute: Equatable, Sendable {
    case fileURLs([String])
    case materializeRetainedImage
    case unsupported(String)
    case missingFiles(String)
}

public enum QuickLookPolicy {
    /// v1: preview the first path that currently exists (order-preserving).
    public static func firstExistingFilePath(
        from paths: [String],
        fileExists: (String) -> Bool
    ) -> String? {
        paths.first { fileExists($0) }
    }

    public static func route(
        for entry: ClipboardEntry,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> QuickLookRoute {
        switch entry.primaryKind {
        case .fileList:
            let paths = entry.originalFilePaths
            if paths.isEmpty {
                return .unsupported("No file paths are available for Quick Look.")
            }
            if let first = firstExistingFilePath(from: paths, fileExists: fileExists) {
                return .fileURLs([first])
            }
            return .missingFiles("One or more files are missing and cannot be previewed.")
        case .image:
            let hasImage = entry.payloadRefs.contains {
                !$0.relativePath.isEmpty && (
                    $0.typeIdentifier == ClipboardTypeIdentifiers.png
                        || $0.typeIdentifier == ClipboardTypeIdentifiers.tiff
                )
            }
            if hasImage { return .materializeRetainedImage }
            return .unsupported("No retained image data is available for Quick Look.")
        default:
            return .unsupported("Quick Look is available for files and images.")
        }
    }

    public static func imageFileExtension(forType typeIdentifier: String) -> String {
        if typeIdentifier == ClipboardTypeIdentifiers.png { return "png" }
        if typeIdentifier == ClipboardTypeIdentifiers.tiff { return "tiff" }
        return "img"
    }
}

/// Pure lifecycle decisions for dedicated Quick Look presentation (no AppKit).
public enum QuickLookLifecyclePolicy {
    /// Staging/presentation completions must match the monotonic request generation.
    public static func shouldApplyStagingCompletion(
        requestGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        requestGeneration == currentGeneration
    }

    /// Whether Space should cancel an in-flight staging or close an open preview (toggle).
    public static func shouldCancelOrCloseOnSpace(isActiveOrStaging: Bool) -> Bool {
        isActiveOrStaging
    }

    /// Quick Look close may re-key the parent only for the same visible/interactable presentation.
    public static func shouldRefocusParentAfterClose(
        capturedOpenGeneration: UInt64,
        currentOpenGeneration: UInt64,
        phase: PanelPresentationPhase,
        windowIsVisible: Bool
    ) -> Bool {
        guard capturedOpenGeneration == currentOpenGeneration else { return false }
        return FinishKeyFocusPolicy.shouldMakeKeyAndFocus(
            phase: phase,
            windowIsVisible: windowIsVisible
        )
    }

    /// Parent notch dismiss must cancel Quick Look for real dismiss reasons (not outside-click while QL is up).
    public static func shouldCancelQuickLookOnParentDismiss(
        isQuickLookActiveOrStaging: Bool,
        reason: DismissReason
    ) -> Bool {
        guard isQuickLookActiveOrStaging else { return false }
        // Outside-click is suppressed while QL is active; other dismiss paths cancel QL first.
        switch reason {
        case .outsideClick:
            return false
        case .escape, .hotkeyToggle, .selection, .programmatic, .dragCompleted, .openLibrary:
            return true
        }
    }
}

/// Pure helpers for transition-token invalidation at dismiss/reopen.
public enum TransitionTokenPolicy {
    /// Opening completions must ignore tokens that are no longer the open generation.
    public static func shouldApplyOpenCompletion(token: UInt64, openGeneration: UInt64) -> Bool {
        token == openGeneration
    }

    /// Closing completions must ignore tokens that are no longer the close generation.
    public static func shouldApplyCloseCompletion(token: UInt64, closeGeneration: UInt64) -> Bool {
        token == closeGeneration
    }
}

/// Planned motion for open/close (derived from accessibility prefs).
public struct AnimationPlan: Equatable, Sendable {
    public var openDuration: TimeInterval
    public var closeDuration: TimeInterval
    /// When false, only opacity changes (Reduce Motion).
    public var allowsGeometryAnimation: Bool
    public var contentScaleEnabled: Bool
    public var preferOpaqueChrome: Bool

    public init(
        openDuration: TimeInterval,
        closeDuration: TimeInterval,
        allowsGeometryAnimation: Bool,
        contentScaleEnabled: Bool,
        preferOpaqueChrome: Bool
    ) {
        self.openDuration = openDuration
        self.closeDuration = closeDuration
        self.allowsGeometryAnimation = allowsGeometryAnimation
        self.contentScaleEnabled = contentScaleEnabled
        self.preferOpaqueChrome = preferOpaqueChrome
    }
}

public enum AnimationPlanner {
    public static func plan(reduceMotion: Bool, reduceTransparency: Bool) -> AnimationPlan {
        if reduceMotion {
            return AnimationPlan(
                openDuration: 0.12,
                closeDuration: 0.10,
                allowsGeometryAnimation: false,
                contentScaleEnabled: false,
                preferOpaqueChrome: true
            )
        }
        return AnimationPlan(
            openDuration: 0.31,
            closeDuration: 0.23,
            allowsGeometryAnimation: true,
            contentScaleEnabled: false,
            preferOpaqueChrome: reduceTransparency
        )
    }
}
