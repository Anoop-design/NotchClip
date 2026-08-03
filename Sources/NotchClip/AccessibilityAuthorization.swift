import AppKit
import ApplicationServices
import NotchClipCore

/// The single system boundary for NotchClip's Accessibility authorization.
///
/// macOS never lets an app grant this permission for itself. Calling
/// `requestPermission()` displays the system-owned prompt; the user remains in
/// control of the switch in Privacy & Security.
@MainActor
enum AccessibilityAuthorization {
    /// Posting a synthetic Command-V is ready only when the process is trusted
    /// by Accessibility *and* Core Graphics confirms event-post access. The two
    /// checks can briefly disagree while TCC is changing, so neither one is
    /// sufficient on its own.
    ///
    /// `CGPreflightPostEventAccess()` answers from a per-process cache that is
    /// not invalidated when the user flips the switch in Privacy & Security, so
    /// polling it alone reported "permission required" until NotchClip was
    /// relaunched. When AX trust says the grant exists, refresh that cache
    /// before believing the preflight's denial.
    static var isGranted: Bool {
        let isAXTrusted = AXIsProcessTrusted()
        guard isAXTrusted else { return false }
        if CGPreflightPostEventAccess() { return true }
        return refreshPostEventAccess()
    }

    /// Last active event-post refresh, so a 500 ms poll cannot hammer CoreGraphics.
    private static var lastPostEventRefresh: Date?
    private static let postEventRefreshInterval: TimeInterval = 2

    /// Re-asks CoreGraphics for event-post access to invalidate the stale
    /// preflight cache. Callers must have already established AX trust, which
    /// means the user allowed NotchClip — so this resolves silently rather than
    /// presenting a prompt.
    private static func refreshPostEventAccess(now: Date = Date()) -> Bool {
        if let last = lastPostEventRefresh,
           now.timeIntervalSince(last) < postEventRefreshInterval {
            return false
        }
        lastPostEventRefresh = now
        return CGRequestPostEventAccess()
    }

    static func isReadyForAutomaticPaste(
        isAXTrusted: Bool,
        canPostEvents: Bool
    ) -> Bool {
        isAXTrusted && canPostEvents
    }

    /// Readiness check for the explicit paste path only.
    ///
    /// Unlike `isGranted` (safe to poll), this may perform a system event-post
    /// request when AX trust exists but the CG preflight disagrees — a state TCC
    /// can briefly enter after Settings changes. The request returns true
    /// silently when the grant actually exists and false without UI when it was
    /// denied, so a user who already decided is never re-prompted here.
    static func ensureReadyToPostEvents() -> Bool {
        if isGranted { return true }
        guard AXIsProcessTrusted() else { return false }
        return CGRequestPostEventAccess()
    }

    /// Requests the system-owned Accessibility prompt after a user action.
    /// The return value is the authorization state at the instant of the call;
    /// it normally remains `false` until the user finishes in System Settings.
    @discardableResult
    static func requestPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let isAXTrusted = AXIsProcessTrustedWithOptions(
            [promptKey: true] as CFDictionary
        )
        let canPostEvents = CGRequestPostEventAccess()
        return isReadyForAutomaticPaste(
            isAXTrusted: isAXTrusted,
            canPostEvents: canPostEvents
        )
    }

    /// Opens the exact pane where the user can review NotchClip's permission.
    @discardableResult
    static func openSystemSettings() -> Bool {
        // macOS 26+ routes Privacy through its Settings extension identifier;
        // the legacy preference-pane identifier remains correct on macOS 14–15.
        let destination = AccessibilitySettingsRoute.urlString(
            operatingSystemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
        guard let url = URL(string: destination) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
