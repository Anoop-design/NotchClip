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
    /// macOS exposes full Accessibility trust and the narrower event-post grant
    /// as separate TCC services, even though both appear under Accessibility in
    /// System Settings. Either one authorizes the only privileged operation
    /// NotchClip performs: synthesizing Command-V.
    ///
    /// Requiring both caused a false negative after a valid grant whenever one
    /// preflight cache lagged behind the other. Keep this check passive so the
    /// onboarding poll never presents a second system prompt.
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
        isAXTrusted || canPostEvents
    }

    /// Readiness check for the explicit paste path only.
    ///
    /// This stays passive. Permission prompts belong to the explicit onboarding
    /// action, never to a clip selection in another app.
    static func ensureReadyToPostEvents() -> Bool {
        isGranted
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
