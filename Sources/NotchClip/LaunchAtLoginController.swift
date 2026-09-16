import Foundation
import Observation
import ServiceManagement

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginServicing {}

@MainActor
@Observable
final class LaunchAtLoginController {
    static let defaultAppliedDefaultsKey = "com.anoop.notchclip.launchAtLogin.defaultApplied"

    enum State: Equatable {
        case off
        case on
        case requiresApproval
        case unavailable
    }

    @ObservationIgnored private let service: any LaunchAtLoginServicing
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bundleURL: URL

    private(set) var state: State = .off
    private(set) var errorMessage: String?

    init(
        service: any LaunchAtLoginServicing = SMAppService.mainApp,
        defaults: UserDefaults = .standard,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        self.service = service
        self.defaults = defaults
        self.bundleURL = bundleURL
        refresh()
    }

    var isRequested: Bool {
        state == .on || state == .requiresApproval
    }

    var needsApproval: Bool {
        state == .requiresApproval
    }

    /// Launch at Login ships on by default, but only once. Recording the applied
    /// default means a later user opt-out remains respected on every launch.
    func enableByDefaultIfNeeded() {
        guard !defaults.bool(forKey: Self.defaultAppliedDefaultsKey),
              Self.canRegisterDefault(from: bundleURL) else {
            refresh()
            return
        }

        refresh()
        if isRequested {
            defaults.set(true, forKey: Self.defaultAppliedDefaultsKey)
            return
        }

        setEnabled(true, opensSettingsForApproval: false, recordsUserChoice: false)
        if isRequested {
            defaults.set(true, forKey: Self.defaultAppliedDefaultsKey)
        }
    }

    func setEnabled(_ enabled: Bool) {
        setEnabled(enabled, opensSettingsForApproval: true, recordsUserChoice: true)
    }

    private func setEnabled(
        _ enabled: Bool,
        opensSettingsForApproval: Bool,
        recordsUserChoice: Bool
    ) {
        if recordsUserChoice {
            defaults.set(true, forKey: Self.defaultAppliedDefaultsKey)
        }
        errorMessage = nil
        refresh()

        do {
            if enabled {
                switch service.status {
                case .enabled:
                    break
                case .requiresApproval:
                    if opensSettingsForApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                case .notRegistered, .notFound:
                    try service.register()
                @unknown default:
                    try service.register()
                }
            } else {
                switch service.status {
                case .notRegistered, .notFound:
                    break
                case .enabled, .requiresApproval:
                    try service.unregister()
                @unknown default:
                    try service.unregister()
                }
            }
        } catch {
            refresh()
            if isRequested != enabled {
                errorMessage = Self.message(for: error, enabling: enabled)
            }
            return
        }

        refresh()
        if enabled, needsApproval, opensSettingsForApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func refresh() {
        switch service.status {
        case .notRegistered:
            state = .off
        case .enabled:
            state = .on
        case .requiresApproval:
            state = .requiresApproval
        case .notFound:
            state = .unavailable
        @unknown default:
            state = .unavailable
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func canRegisterDefault(from bundleURL: URL) -> Bool {
        bundleURL.pathExtension == "app"
            && !bundleURL.path.hasPrefix("/Volumes/")
    }

    private static func message(for error: Error, enabling: Bool) -> String {
        let action = enabling ? "enable" : "disable"
        return "Couldn’t \(action) Launch at Login. \(error.localizedDescription)"
    }
}
