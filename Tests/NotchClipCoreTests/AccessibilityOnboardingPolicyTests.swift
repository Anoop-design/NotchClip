import XCTest
@testable import NotchClipCore

final class AccessibilityOnboardingPolicyTests: XCTestCase {
    func testUntrustedAppPresentsWhenOnboardingHasNotBeenPresented() {
        XCTAssertTrue(
            AccessibilityOnboardingPolicy.shouldPresent(
                isAccessibilityTrusted: false,
                state: .notPresented
            )
        )
    }

    func testTrustedAppNeverPresentsForAnyLifecycleState() {
        for state in AccessibilityOnboardingState.allCases {
            XCTAssertFalse(
                AccessibilityOnboardingPolicy.shouldPresent(
                    isAccessibilityTrusted: true,
                    state: state
                ),
                "Unexpected onboarding for trusted app in state \(state)"
            )
        }
    }

    func testAlreadyPresentedOnboardingDoesNotCreateADuplicate() {
        XCTAssertFalse(
            AccessibilityOnboardingPolicy.shouldPresent(
                isAccessibilityTrusted: false,
                state: .presented
            )
        )
    }

    func testExplicitlyDeferredOnboardingDoesNotNagAgain() {
        XCTAssertFalse(
            AccessibilityOnboardingPolicy.shouldPresent(
                isAccessibilityTrusted: false,
                state: .deferred
            )
        )
    }

    func testCompletedOnboardingDoesNotNagIfPermissionIsLaterUnavailable() {
        XCTAssertFalse(
            AccessibilityOnboardingPolicy.shouldPresent(
                isAccessibilityTrusted: false,
                state: .completed
            )
        )
    }
}

final class AccessibilitySettingsRouteTests: XCTestCase {
    func testMacOS14And15UseLegacyPrivacyPaneRoute() {
        for version in [14, 15] {
            XCTAssertEqual(
                AccessibilitySettingsRoute.urlString(operatingSystemMajorVersion: version),
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        }
    }

    func testMacOS26AndLaterUsePrivacySettingsExtensionRoute() {
        for version in [26, 27, 28] {
            XCTAssertEqual(
                AccessibilitySettingsRoute.urlString(operatingSystemMajorVersion: version),
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
            )
        }
    }
}

final class ProductOnboardingPolicyTests: XCTestCase {
    func testNewOnboardingVersionPresents() {
        XCTAssertTrue(ProductOnboardingPolicy.shouldPresent(state: .notPresented))
    }

    func testResolvedOnboardingDoesNotPresentAutomatically() {
        for state in [
            AccessibilityOnboardingState.presented,
            .deferred,
            .completed,
        ] {
            XCTAssertFalse(
                ProductOnboardingPolicy.shouldPresent(state: state),
                "Unexpected product onboarding for state \(state)"
            )
        }
    }
}
