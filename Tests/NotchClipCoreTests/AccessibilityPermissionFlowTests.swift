import AppKit
import XCTest
@testable import NotchClip

@MainActor
final class AccessibilityPermissionStateTests: XCTestCase {
    func testAutomaticPasteRequiresBothAXTrustAndEventPostAccess() {
        XCTAssertFalse(
            AccessibilityAuthorization.isReadyForAutomaticPaste(
                isAXTrusted: false,
                canPostEvents: false
            )
        )
        XCTAssertFalse(
            AccessibilityAuthorization.isReadyForAutomaticPaste(
                isAXTrusted: true,
                canPostEvents: false
            )
        )
        XCTAssertFalse(
            AccessibilityAuthorization.isReadyForAutomaticPaste(
                isAXTrusted: false,
                canPostEvents: true
            )
        )
        XCTAssertTrue(
            AccessibilityAuthorization.isReadyForAutomaticPaste(
                isAXTrusted: true,
                canPostEvents: true
            )
        )
    }

    func testOpenSettingsFailureIsNotReportedAsWaiting() {
        let state = AccessibilityPermissionState(
            authorizationCheck: { false },
            authorizationRequest: { false },
            settingsOpener: { false }
        )

        XCTAssertFalse(state.openSystemSettings())
        XCTAssertFalse(state.isGranted)
        XCTAssertTrue(state.hasRequestedPermission)
        XCTAssertFalse(state.isWaitingForPermission)
        XCTAssertNotNil(state.setupErrorMessage)
        XCTAssertEqual(state.statusTitle, "System Settings could not be opened")
    }

    func testPermissionRequestDoesNotOpenSettingsInTheSameStep() {
        var requestCount = 0
        var settingsOpenCount = 0
        let state = AccessibilityPermissionState(
            authorizationCheck: { false },
            authorizationRequest: {
                requestCount += 1
                return false
            },
            settingsOpener: {
                settingsOpenCount += 1
                return true
            }
        )

        state.requestPermission()

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(settingsOpenCount, 0)
        XCTAssertTrue(state.isWaitingForPermission)
        state.endMonitoring()
    }

    func testPresentationPreservesPriorRequestAndRetrySignalsThenOpensSettings() {
        var requestCount = 0
        var settingsOpenCount = 0
        let state = AccessibilityPermissionState(
            authorizationCheck: { false },
            authorizationRequest: {
                requestCount += 1
                return false
            },
            settingsOpener: {
                settingsOpenCount += 1
                return true
            }
        )
        state.restoreRequestAttemptState(true)

        state.prepareForPresentation()

        XCTAssertTrue(state.hasRequestedPermission)
        XCTAssertFalse(state.isWaitingForPermission)
        XCTAssertEqual(state.setupAttemptID, 0)

        XCTAssertTrue(state.retryPermission())

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(settingsOpenCount, 1)
        XCTAssertEqual(state.setupAttemptID, 1)
        XCTAssertTrue(state.isWaitingForPermission)
        XCTAssertTrue(state.isMonitoring)
        state.endMonitoring()
    }

    func testRepeatedRetriesRetriggerRequestAndSettingsEveryTime() {
        var requestCount = 0
        var settingsOpenCount = 0
        var persistedAttemptCount = 0
        let state = AccessibilityPermissionState(
            authorizationCheck: { false },
            authorizationRequest: {
                requestCount += 1
                return false
            },
            settingsOpener: {
                settingsOpenCount += 1
                return true
            }
        )
        state.onPermissionRequestAttempted = {
            persistedAttemptCount += 1
        }

        XCTAssertTrue(state.retryPermission())
        XCTAssertTrue(state.retryPermission())

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(settingsOpenCount, 2)
        XCTAssertEqual(persistedAttemptCount, 2)
        XCTAssertEqual(state.setupAttemptID, 2)
        state.endMonitoring()
    }

    func testSuccessfulRetryDoesNotOpenSettingsUnnecessarily() {
        var requestCount = 0
        var settingsOpenCount = 0
        let state = AccessibilityPermissionState(
            authorizationCheck: { requestCount > 0 },
            authorizationRequest: {
                requestCount += 1
                return true
            },
            settingsOpener: {
                settingsOpenCount += 1
                return true
            }
        )

        XCTAssertTrue(state.retryPermission())

        XCTAssertTrue(state.isGranted)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(settingsOpenCount, 0)
        XCTAssertFalse(state.isWaitingForPermission)
        XCTAssertFalse(state.isMonitoring)
    }

    func testControllerRestoresAndPersistsPermissionAttemptHistory() {
        let suiteName = "AccessibilityPermissionStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            true,
            forKey: AccessibilityPermissionOnboardingController
                .permissionRequestAttemptedDefaultsKey
        )
        let state = AccessibilityPermissionState(
            authorizationCheck: { false },
            authorizationRequest: { false },
            settingsOpener: { true }
        )
        let controller = AccessibilityPermissionOnboardingController(
            state: state,
            defaults: defaults
        )

        XCTAssertTrue(state.hasRequestedPermission)

        state.requestPermission()

        XCTAssertTrue(
            defaults.bool(
                forKey: AccessibilityPermissionOnboardingController
                    .permissionRequestAttemptedDefaultsKey
            )
        )
        state.endMonitoring()
        controller.shutdown()
    }

    func testReturningToAppClearsStaleWaitingStateButKeepsRetryRoute() {
        let state = AccessibilityPermissionState(
            authorizationCheck: { false },
            authorizationRequest: { false },
            settingsOpener: { true }
        )

        state.requestPermission()
        XCTAssertTrue(state.isWaitingForPermission)

        state.didReturnToApp()

        XCTAssertFalse(state.isWaitingForPermission)
        XCTAssertTrue(state.hasRequestedPermission)
        XCTAssertTrue(state.isMonitoring)
        state.endMonitoring()
    }

    func testWaitingStateSettlesWithoutStoppingPermissionMonitoring() async throws {
        let state = AccessibilityPermissionState(
            authorizationCheck: { false },
            authorizationRequest: { false },
            settingsOpener: { true },
            pollingIntervalNanoseconds: 1_000_000,
            waitingTimeoutNanoseconds: 1_000_000
        )

        state.requestPermission()
        XCTAssertTrue(state.isWaitingForPermission)

        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertFalse(state.isWaitingForPermission)
        XCTAssertTrue(state.isMonitoring)
        state.endMonitoring()
    }

    func testGrantAndRevocationTransitionsFireExactlyOnce() {
        var isReady = false
        var grantedCount = 0
        var revokedCount = 0
        let state = AccessibilityPermissionState(
            authorizationCheck: { isReady },
            authorizationRequest: { isReady },
            settingsOpener: { true }
        )
        state.onPermissionGranted = { grantedCount += 1 }
        state.onPermissionRevoked = { revokedCount += 1 }

        isReady = true
        state.refresh()
        state.refresh()

        XCTAssertTrue(state.isGranted)
        XCTAssertEqual(grantedCount, 1)
        XCTAssertEqual(revokedCount, 0)

        isReady = false
        state.refresh()
        state.refresh()

        XCTAssertFalse(state.isGranted)
        XCTAssertEqual(grantedCount, 1)
        XCTAssertEqual(revokedCount, 1)
    }

    func testPermissionPageRequestsAreMonotonic() {
        let state = AccessibilityPermissionState(
            authorizationCheck: { false },
            authorizationRequest: { false },
            settingsOpener: { true }
        )

        XCTAssertEqual(state.permissionPageRequestID, 0)
        state.requestPermissionPage()
        state.requestPermissionPage()
        XCTAssertEqual(state.permissionPageRequestID, 2)
    }

    func testMonitoringCanRestartAfterRevocationAndObserveNextGrant() async throws {
        var isReady = true
        let granted = expectation(description: "permission grant observed")
        let state = AccessibilityPermissionState(
            authorizationCheck: { isReady },
            authorizationRequest: { isReady },
            settingsOpener: { true },
            pollingIntervalNanoseconds: 1_000_000
        )
        state.onPermissionGranted = { granted.fulfill() }

        isReady = false
        state.refresh()
        state.beginMonitoring()
        XCTAssertTrue(state.isMonitoring)

        isReady = true
        await fulfillment(of: [granted], timeout: 1.0)

        XCTAssertTrue(state.isGranted)
        XCTAssertFalse(state.isMonitoring)
    }
}

@MainActor
final class PasteCommandDispatcherPermissionTests: XCTestCase {
    func testRevocationAfterActivationPreventsEventPost() async {
        var isReady = true
        var didPostEvent = false
        let target = NSRunningApplication.current
        let targetPID: pid_t = 4_242
        let completion = expectation(description: "dispatch completed")
        let state = AccessibilityPermissionState(
            authorizationCheck: { isReady },
            authorizationRequest: { isReady },
            settingsOpener: { true }
        )
        let dispatcher = PasteCommandDispatcher(
            accessibility: state,
            activationTimeout: 0.1,
            pollInterval: 0.001,
            focusSettleDelay: 0,
            frontmostProcessIdentifier: { targetPID },
            targetActivator: { _ in
                isReady = false
                return true
            },
            targetProcessIdentifier: { _ in targetPID },
            targetIsTerminated: { _ in false },
            targetDisplayName: { _ in "Test Target" },
            eventPoster: { _ in didPostEvent = true }
        )

        dispatcher.dispatch(to: target) { result in
            guard case .failure(let error) = result,
                  let failure = error as? PasteCommandDispatcher.DispatchFailure,
                  case .accessibilityPermissionRequired = failure else {
                XCTFail("Expected an Accessibility failure after revocation")
                completion.fulfill()
                return
            }
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 1.0)
        XCTAssertFalse(didPostEvent)
    }

    func testReadyDispatcherPostsExactlyOnce() async {
        var postedPIDs: [pid_t] = []
        let target = NSRunningApplication.current
        let targetPID: pid_t = 4_242
        let completion = expectation(description: "dispatch completed")
        let state = AccessibilityPermissionState(
            authorizationCheck: { true },
            authorizationRequest: { true },
            settingsOpener: { true }
        )
        let dispatcher = PasteCommandDispatcher(
            accessibility: state,
            activationTimeout: 0.1,
            pollInterval: 0.001,
            focusSettleDelay: 0,
            frontmostProcessIdentifier: { targetPID },
            targetActivator: { _ in true },
            targetProcessIdentifier: { _ in targetPID },
            targetIsTerminated: { _ in false },
            targetDisplayName: { _ in "Test Target" },
            eventPoster: { postedPIDs.append($0) }
        )

        dispatcher.dispatch(to: target) { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected dispatch failure: \(error)")
            }
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 1.0)
        XCTAssertEqual(postedPIDs, [targetPID])
    }
}
