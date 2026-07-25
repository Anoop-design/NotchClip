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
    static var isGranted: Bool {
        isReadyForAutomaticPaste(
            isAXTrusted: AXIsProcessTrusted(),
            canPostEvents: CGPreflightPostEventAccess()
        )
    }

    static func isReadyForAutomaticPaste(
        isAXTrusted: Bool,
        canPostEvents: Bool
    ) -> Bool {
        isAXTrusted && canPostEvents
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
