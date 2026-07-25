import Foundation

/// Injectable global-hotkey registration seam (Carbon implementation lives in the app target).
public protocol HotKeyRegistering: AnyObject {
    var isRegistered: Bool { get }
    /// Human-readable conflict / failure reason for menu/settings, if any.
    var registrationError: String? { get }
    /// Invoked on successful keydown toggle (once per press; no key-repeat storms).
    var onToggle: (() -> Void)? { get set }

    /// Attempt registration. Returns `true` when active.
    @discardableResult
    func register() -> Bool
    func unregister()
}

/// In-memory fake for unit tests — never touches the system hotkey table.
public final class FakeHotKeyRegistrar: HotKeyRegistering, @unchecked Sendable {
    public private(set) var isRegistered: Bool = false
    public var registrationError: String?
    public var onToggle: (() -> Void)?
    /// When `true`, `register()` fails and sets `registrationError`.
    public var shouldFailRegistration: Bool = false
    public private(set) var registerCallCount: Int = 0
    public private(set) var unregisterCallCount: Int = 0
    public private(set) var toggleDispatchCount: Int = 0

    public init() {}

    @discardableResult
    public func register() -> Bool {
        registerCallCount += 1
        if shouldFailRegistration {
            isRegistered = false
            registrationError = "Hotkey \(NotchClipHotKey.humanReadableName) is already in use by another application."
            return false
        }
        isRegistered = true
        registrationError = nil
        return true
    }

    public func unregister() {
        unregisterCallCount += 1
        isRegistered = false
    }

    /// Test helper: simulate a single keydown.
    public func simulateKeyDown() {
        guard isRegistered else { return }
        toggleDispatchCount += 1
        onToggle?()
    }
}

/// Semantic shortcut modifiers shared by the Carbon and SwiftUI adapters.
public enum NotchClipHotKeyModifier: String, CaseIterable, Hashable, Sendable {
    case command
    case control
    case option
    case shift
}

/// Fixed first-version shortcut identity and UI copy.
public enum NotchClipHotKey {
    public static let key: Character = "v"
    public static let modifiers: Set<NotchClipHotKeyModifier> = [.control]
    public static let displayName = "⌃V"
    public static let accessibilityName = "Control-V"
    public static let humanReadableName = "Control–V"
}
