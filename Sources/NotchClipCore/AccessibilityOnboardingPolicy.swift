/// The lifecycle state of the one-time Accessibility onboarding experience.
///
/// `presented` is intentionally distinct from a user decision so a coordinator
/// can prevent duplicate windows while the onboarding is already on screen.
/// `deferred` and `completed` are terminal for automatic presentation: the app
/// can continue to expose permission setup from Settings without nagging at
/// every launch.
public enum AccessibilityOnboardingState: String, CaseIterable, Equatable, Sendable {
    case notPresented
    case presented
    case deferred
    case completed
}

/// Pure launch policy for the Accessibility permission onboarding window.
public enum AccessibilityOnboardingPolicy {
    /// Presents exactly once when Accessibility is still unavailable.
    ///
    /// A trusted app never needs onboarding. An untrusted app is eligible only
    /// before the experience has been presented or explicitly resolved.
    public static func shouldPresent(
        isAccessibilityTrusted: Bool,
        state: AccessibilityOnboardingState
    ) -> Bool {
        !isAccessibilityTrusted && state == .notPresented
    }
}

/// Launch policy for the versioned product tour. Unlike the Accessibility-only
/// policy, this experience is useful even when the OS permission is already
/// granted because it teaches the shortcut, notch shelf, dragging, and library.
public enum ProductOnboardingPolicy {
    /// Automatically presents only until the current tour has either been
    /// completed or explicitly deferred. A Settings/debug action can bypass
    /// this policy at the coordinator level.
    public static func shouldPresent(state: AccessibilityOnboardingState) -> Bool {
        state == .notPresented
    }
}

/// Chooses the System Settings deep-link identifier used by each macOS family.
/// Apple moved Privacy & Security from its legacy preference-pane identifier
/// to a Settings extension when macOS adopted the year-based version numbers.
public enum AccessibilitySettingsRoute {
    public static func urlString(operatingSystemMajorVersion: Int) -> String {
        if operatingSystemMajorVersion >= 26 {
            return "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        }
        return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    }
}
