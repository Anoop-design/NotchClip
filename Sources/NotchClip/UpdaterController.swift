import Sparkle
import SwiftUI

/// Owns the Sparkle updater and mirrors the two updater properties the menu and
/// Settings bind to. Sparkle stores its own preferences (feed check interval,
/// automatic checks, skipped versions) in UserDefaults, so nothing here is
/// duplicated in `AppPreferences`.
@MainActor
@Observable
final class UpdaterController {
    private var controller: SPUStandardUpdaterController?
    /// Sparkle refuses concurrent checks; the menu item and button follow this.
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = true
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Started from `AppCoordinator.start()` rather than `init` so the updater
    /// begins scheduling only once the app has finished launching.
    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller

        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = updater.canCheckForUpdates
                }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
                }
            }
        ]
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }
}
