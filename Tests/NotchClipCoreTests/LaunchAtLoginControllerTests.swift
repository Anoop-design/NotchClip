import ServiceManagement
import XCTest
@testable import NotchClip

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testFirstInstalledLaunchRegistersAndRecordsDefault() {
        let fixture = makeFixture(status: .notRegistered)

        fixture.controller.enableByDefaultIfNeeded()

        XCTAssertEqual(fixture.service.registerCount, 1)
        XCTAssertEqual(fixture.controller.state, .on)
        XCTAssertTrue(
            fixture.defaults.bool(forKey: LaunchAtLoginController.defaultAppliedDefaultsKey)
        )
    }

    func testDefaultDoesNotRegisterFromMountedDMG() {
        let fixture = makeFixture(
            status: .notRegistered,
            bundleURL: URL(fileURLWithPath: "/Volumes/NotchClip Installer/NotchClip.app")
        )

        fixture.controller.enableByDefaultIfNeeded()

        XCTAssertEqual(fixture.service.registerCount, 0)
        XCTAssertFalse(
            fixture.defaults.bool(forKey: LaunchAtLoginController.defaultAppliedDefaultsKey)
        )
    }

    func testPriorOptOutIsRespectedOnLaterLaunches() {
        let fixture = makeFixture(status: .notRegistered)
        fixture.defaults.set(true, forKey: LaunchAtLoginController.defaultAppliedDefaultsKey)

        fixture.controller.enableByDefaultIfNeeded()

        XCTAssertEqual(fixture.service.registerCount, 0)
        XCTAssertEqual(fixture.controller.state, .off)
    }

    func testExplicitDisableRecordsTheUserChoice() {
        let fixture = makeFixture(status: .enabled)

        fixture.controller.setEnabled(false)

        XCTAssertEqual(fixture.service.unregisterCount, 1)
        XCTAssertEqual(fixture.controller.state, .off)
        XCTAssertTrue(
            fixture.defaults.bool(forKey: LaunchAtLoginController.defaultAppliedDefaultsKey)
        )
    }

    func testFailedDefaultRegistrationRetriesOnNextLaunch() {
        let fixture = makeFixture(status: .notRegistered)
        fixture.service.registrationError = TestError.registrationFailed

        fixture.controller.enableByDefaultIfNeeded()

        XCTAssertEqual(fixture.service.registerCount, 1)
        XCTAssertFalse(
            fixture.defaults.bool(forKey: LaunchAtLoginController.defaultAppliedDefaultsKey)
        )

        fixture.service.registrationError = nil
        fixture.controller.enableByDefaultIfNeeded()

        XCTAssertEqual(fixture.service.registerCount, 2)
        XCTAssertEqual(fixture.controller.state, .on)
        XCTAssertTrue(
            fixture.defaults.bool(forKey: LaunchAtLoginController.defaultAppliedDefaultsKey)
        )
    }

    private func makeFixture(
        status: SMAppService.Status,
        bundleURL: URL = URL(fileURLWithPath: "/Applications/NotchClip.app")
    ) -> Fixture {
        let suiteName = "LaunchAtLoginControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let service = FakeLaunchAtLoginService(status: status)
        let controller = LaunchAtLoginController(
            service: service,
            defaults: defaults,
            bundleURL: bundleURL
        )
        return Fixture(controller: controller, service: service, defaults: defaults)
    }
}

@MainActor
private struct Fixture {
    let controller: LaunchAtLoginController
    let service: FakeLaunchAtLoginService
    let defaults: UserDefaults
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: SMAppService.Status
    var registrationError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registrationError {
            throw registrationError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = .notRegistered
    }
}

private enum TestError: Error {
    case registrationFailed
}
