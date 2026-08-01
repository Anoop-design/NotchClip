import Foundation

/// Injectable global-hotkey registration seam (Carbon implementation lives in the app target).
public protocol HotKeyRegistering: AnyObject {
    var isRegistered: Bool { get }
    /// Human-readable conflict / failure reason for menu/settings, if any.
    var registrationError: String? { get }
    /// Invoked on successful keydown toggle (once per press; no key-repeat storms).
    var onToggle: (() -> Void)? { get set }
    /// The shortcut the last `register(_:)` attempted, successful or not.
    var binding: NotchClipHotKeyBinding { get }

    /// Replace any live registration with `binding`. Returns `true` when active.
    @discardableResult
    func register(_ binding: NotchClipHotKeyBinding) -> Bool
    func unregister()
}

public extension HotKeyRegistering {
    /// Re-register the current binding.
    @discardableResult
    func register() -> Bool {
        register(binding)
    }
}

/// In-memory fake for unit tests — never touches the system hotkey table.
public final class FakeHotKeyRegistrar: HotKeyRegistering, @unchecked Sendable {
    public private(set) var isRegistered: Bool = false
    public var registrationError: String?
    public var onToggle: (() -> Void)?
    public private(set) var binding: NotchClipHotKeyBinding = NotchClipHotKey.defaultBinding
    /// When `true`, `register(_:)` fails and sets `registrationError`.
    public var shouldFailRegistration: Bool = false
    public private(set) var registerCallCount: Int = 0
    public private(set) var unregisterCallCount: Int = 0
    public private(set) var toggleDispatchCount: Int = 0

    public init() {}

    @discardableResult
    public func register(_ binding: NotchClipHotKeyBinding) -> Bool {
        registerCallCount += 1
        self.binding = binding
        if shouldFailRegistration {
            isRegistered = false
            registrationError = "That shortcut is in use by another app."
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

/// Default shortcut identity and the UI copy that describes it. The live
/// shortcut is user-configurable; these are the factory values that a fresh
/// install — and "Reset to Default" — land on.
public enum NotchClipHotKey {
    /// `kVK_ANSI_V`.
    public static let defaultKeyCode: UInt16 = 0x09
    public static let defaultBinding = NotchClipHotKeyBinding(
        keyCode: defaultKeyCode,
        modifiers: [.control]
    )
    public static let key: Character = "v"
    public static let modifiers: Set<NotchClipHotKeyModifier> = [.control]
    public static let displayName = "⌃V"
    public static let accessibilityName = "Control-V"
    public static let humanReadableName = "Control–V"
}
