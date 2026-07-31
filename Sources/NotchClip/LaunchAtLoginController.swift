import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    enum State: Equatable {
        case off
        case on
        case requiresApproval
        case unavailable
    }

    private let service: SMAppService

    private(set) var state: State = .off
    private(set) var errorMessage: String?

    init(service: SMAppService = .mainApp) {
        self.service = service
        refresh()
    }

    var isRequested: Bool {
        state == .on || state == .requiresApproval
    }

    var needsApproval: Bool {
        state == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        refresh()

        do {
            if enabled {
                switch service.status {
                case .enabled:
                    break
                case .requiresApproval:
                    SMAppService.openSystemSettingsLoginItems()
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
        if enabled, needsApproval {
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

    private static func message(for error: Error, enabling: Bool) -> String {
        let action = enabling ? "enable" : "disable"
        return "Couldn’t \(action) Launch at Login. \(error.localizedDescription)"
    }
}
