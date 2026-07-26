import Foundation

/// Pure decisions for the copy-acknowledgment pulse — the brief Dynamic-Island
/// swell the notch performs when a clip is captured while the panel is closed.
public enum CapturePulsePolicy {
    /// A pulse announces only real history changes, and never competes with the
    /// open panel (which already shows the new clip at the top of its list).
    public static func shouldShow(
        result: CaptureResult,
        panelPhase: PanelPresentationPhase
    ) -> Bool {
        guard panelPhase == .hidden else { return false }
        switch result {
        case .inserted, .updatedExisting:
            return true
        case .ignoredEmpty, .ignoredSelfWrite, .ignoredTransient, .failed:
            // Self-writes are the app's own paste; failures surface through the
            // capture-error banner, not an upbeat "Copied" pulse.
            return false
        }
    }

    /// The entry a pulse would announce, when there is one.
    public static func entry(for result: CaptureResult) -> ClipboardEntry? {
        switch result {
        case .inserted(let entry), .updatedExisting(let entry):
            return entry
        case .ignoredEmpty, .ignoredSelfWrite, .ignoredTransient, .failed:
            return nil
        }
    }

    /// "Copied · Terminal", falling back to the content kind when the source
    /// app is unknown ("Copied · Image").
    public static func label(for entry: ClipboardEntry) -> String {
        if let source = EntryPresentation.sourceLabel(from: entry.source) {
            return "Copied · \(source)"
        }
        return "Copied · \(EntryKindLabel.displayName(for: entry.primaryKind))"
    }

    /// Seconds the lip stays fully shown before retracting. Restarted when a
    /// newer capture lands while the pulse is still up.
    public static let holdDuration: TimeInterval = 1.5
    public static let expandDuration: TimeInterval = 0.26
    public static let retractDuration: TimeInterval = 0.20
    /// Height of the visible lip below the camera housing.
    public static let lipHeight: CGFloat = 30
    /// Extra width beyond the cap so the label clears the housing's corners.
    public static let widthBeyondCap: CGFloat = 84
}
