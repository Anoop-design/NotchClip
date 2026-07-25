import AppKit
import CoreGraphics
import NotchClipCore

/// Restores the app captured when the notch opened and delivers one Command-V
/// after that app is verifiably frontmost. Clipboard data is already committed
/// before this service runs, so every failure preserves manual Command-V as a
/// safe fallback.
@MainActor
final class PasteCommandDispatcher {
    enum DispatchFailure: LocalizedError {
        case accessibilityPermissionRequired
        case targetUnavailable(String)
        case activationFailed(String)
        case activationTimedOut(String)
        case targetLostFocus(String)
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityPermissionRequired:
                return "Copied to the clipboard. Allow NotchClip in System Settings → Privacy & Security → Accessibility, then try again to paste automatically."
            case .targetUnavailable(let name):
                return "Copied to the clipboard, but \(name) is no longer available. Press Command-V to paste manually."
            case .activationFailed(let name):
                return "Copied to the clipboard, but NotchClip could not return focus to \(name). Press Command-V to paste manually."
            case .activationTimedOut(let name):
                return "Copied to the clipboard, but \(name) did not become active in time. Press Command-V to paste manually."
            case .targetLostFocus(let name):
                return "Copied to the clipboard, but focus moved away from \(name) before automatic paste. Press Command-V to paste manually."
            case .eventCreationFailed:
                return "Copied to the clipboard, but NotchClip could not send Command-V. Press Command-V to paste manually."
            }
        }
    }

    private let accessibility: AccessibilityPermissionState
    private let activationTimeoutNanoseconds: UInt64
    private let pollIntervalNanoseconds: UInt64
    private let focusSettleNanoseconds: UInt64
    private let frontmostProcessIdentifier: @MainActor () -> pid_t?
    private let targetActivator: @MainActor (NSRunningApplication) -> Bool
    private let targetProcessIdentifier: @MainActor (NSRunningApplication) -> pid_t
    private let targetIsTerminated: @MainActor (NSRunningApplication) -> Bool
    private let targetDisplayName: @MainActor (NSRunningApplication) -> String
    private let eventPoster: @MainActor (pid_t) throws -> Void

    private var generation: UInt64 = 0
    private var pendingTask: Task<Void, Never>?

    init(
        accessibility: AccessibilityPermissionState,
        workspace: NSWorkspace = .shared,
        activationTimeout: TimeInterval = 1.0,
        pollInterval: TimeInterval = 0.02,
        focusSettleDelay: TimeInterval = 0.04,
        frontmostProcessIdentifier: (@MainActor () -> pid_t?)? = nil,
        targetActivator: @escaping @MainActor (NSRunningApplication) -> Bool = {
            $0.activate(options: [])
        },
        targetProcessIdentifier: @escaping @MainActor (NSRunningApplication) -> pid_t = {
            $0.processIdentifier
        },
        targetIsTerminated: @escaping @MainActor (NSRunningApplication) -> Bool = {
            $0.isTerminated
        },
        targetDisplayName: @escaping @MainActor (NSRunningApplication) -> String = {
            $0.localizedName ?? "the previous app"
        },
        eventPoster: (@MainActor (pid_t) throws -> Void)? = nil
    ) {
        self.accessibility = accessibility
        self.activationTimeoutNanoseconds = Self.nanoseconds(for: activationTimeout)
        self.pollIntervalNanoseconds = Self.nanoseconds(for: pollInterval)
        self.focusSettleNanoseconds = Self.nanoseconds(for: focusSettleDelay)
        self.frontmostProcessIdentifier = frontmostProcessIdentifier ?? {
            workspace.frontmostApplication?.processIdentifier
        }
        self.targetActivator = targetActivator
        self.targetProcessIdentifier = targetProcessIdentifier
        self.targetIsTerminated = targetIsTerminated
        self.targetDisplayName = targetDisplayName
        self.eventPoster = eventPoster ?? Self.postCommandV
    }

    /// Invalidates every delayed activation/paste step without reporting an
    /// error. A newly opened notch presentation calls this to prevent an old
    /// selection from injecting into the wrong interaction.
    func cancelPending() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
    }

    /// Activates `target`, waits for its PID to become frontmost, then posts one
    /// Command-V pair directly to that PID. Completion runs on the main actor.
    func dispatch(
        to target: NSRunningApplication,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        cancelPending()
        let token = generation
        let targetPID = targetProcessIdentifier(target)
        let targetName = targetDisplayName(target)

        guard targetPID > 0, !targetIsTerminated(target) else {
            completion(.failure(DispatchFailure.targetUnavailable(targetName)))
            return
        }

        accessibility.refresh()
        guard accessibility.isGranted else {
            completion(.failure(DispatchFailure.accessibilityPermissionRequired))
            return
        }

        guard targetActivator(target) else {
            completion(.failure(DispatchFailure.activationFailed(targetName)))
            return
        }

        let timeout = activationTimeoutNanoseconds
        let poll = pollIntervalNanoseconds
        let settle = focusSettleNanoseconds
        pendingTask = Task { @MainActor [weak self, target] in
            guard let self else { return }
            let startedAt = DispatchTime.now().uptimeNanoseconds

            while true {
                guard !Task.isCancelled,
                      PasteDeliveryPolicy.isCurrent(token: token, generation: self.generation) else {
                    return
                }
                guard !self.targetIsTerminated(target) else {
                    self.finish(
                        token: token,
                        result: .failure(DispatchFailure.targetUnavailable(targetName)),
                        completion: completion
                    )
                    return
                }

                let frontmostPID = self.frontmostProcessIdentifier()
                if PasteDeliveryPolicy.isTargetFrontmost(
                    targetPID: targetPID,
                    frontmostPID: frontmostPID
                ) {
                    if settle > 0 {
                        try? await Task.sleep(nanoseconds: settle)
                    }
                    guard !Task.isCancelled,
                          PasteDeliveryPolicy.isCurrent(token: token, generation: self.generation) else {
                        return
                    }
                    guard PasteDeliveryPolicy.isTargetFrontmost(
                        targetPID: targetPID,
                        frontmostPID: self.frontmostProcessIdentifier()
                    ) else {
                        self.finish(
                            token: token,
                            result: .failure(DispatchFailure.targetLostFocus(targetName)),
                            completion: completion
                        )
                        return
                    }

                    // TCC can change while the destination is activating. Verify
                    // actual event-post readiness again at the final boundary so
                    // revocation never becomes a false successful paste.
                    self.accessibility.refresh()
                    guard self.accessibility.isGranted else {
                        self.finish(
                            token: token,
                            result: .failure(DispatchFailure.accessibilityPermissionRequired),
                            completion: completion
                        )
                        return
                    }

                    do {
                        try self.eventPoster(targetPID)
                        self.finish(token: token, result: .success(()), completion: completion)
                    } catch {
                        self.finish(token: token, result: .failure(error), completion: completion)
                    }
                    return
                }

                let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                guard elapsed < timeout else {
                    self.finish(
                        token: token,
                        result: .failure(DispatchFailure.activationTimedOut(targetName)),
                        completion: completion
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: poll)
            }
        }
    }

    private static func postCommandV(to targetPID: pid_t) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(9),
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(9),
                keyDown: false
              ) else {
            throw DispatchFailure.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(targetPID)
        keyUp.postToPid(targetPID)
    }

    private func finish(
        token: UInt64,
        result: Result<Void, Error>,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard PasteDeliveryPolicy.isCurrent(token: token, generation: generation) else { return }
        pendingTask = nil
        completion(result)
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval > 0 else { return 0 }
        return UInt64(min(interval, 60) * 1_000_000_000)
    }
}
