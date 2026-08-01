import Foundation

/// A recorded global shortcut: one Carbon virtual key code plus its modifiers.
/// Layout-dependent key *labels* live in the app target; everything here is pure.
public struct NotchClipHotKeyBinding: Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: Set<NotchClipHotKeyModifier>

    public init(keyCode: UInt16, modifiers: Set<NotchClipHotKeyModifier>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

// MARK: - Persistence

public extension NotchClipHotKeyBinding {
    /// Stable UserDefaults form: `nc1:<keyCode>:<modifierMask>`.
    /// The mask is NotchClip's own bit assignment, never Carbon's or AppKit's,
    /// so a framework constant change can never reinterpret a stored shortcut.
    static let encodingPrefix = "nc1"

    var encoded: String {
        let mask = modifiers.reduce(into: UInt8(0)) { $0 |= $1.persistenceBit }
        return "\(Self.encodingPrefix):\(keyCode):\(mask)"
    }

    /// Returns `nil` for absent or malformed data so callers fall back to the default.
    static func decode(_ raw: String?) -> NotchClipHotKeyBinding? {
        guard let raw else { return nil }
        let fields = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == encodingPrefix else { return nil }
        guard let keyCode = UInt16(fields[1]), let mask = UInt8(fields[2]) else { return nil }
        let known = NotchClipHotKeyModifier.allCases.reduce(into: UInt8(0)) { $0 |= $1.persistenceBit }
        guard mask & ~known == 0 else { return nil }
        let modifiers = NotchClipHotKeyModifier.allCases.filter { mask & $0.persistenceBit != 0 }
        return NotchClipHotKeyBinding(keyCode: keyCode, modifiers: Set(modifiers))
    }
}

// MARK: - Display

public extension NotchClipHotKeyModifier {
    /// Apple's canonical glyph order, the order Menu Manager renders equivalents in.
    static let canonicalOrder: [NotchClipHotKeyModifier] = [.control, .option, .shift, .command]

    var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    var spokenName: String {
        switch self {
        case .control: return "Control"
        case .option: return "Option"
        case .shift: return "Shift"
        case .command: return "Command"
        }
    }

    var persistenceBit: UInt8 {
        switch self {
        case .control: return 1 << 0
        case .option: return 1 << 1
        case .shift: return 1 << 2
        case .command: return 1 << 3
        }
    }
}

public extension NotchClipHotKeyBinding {
    var orderedModifiers: [NotchClipHotKeyModifier] {
        NotchClipHotKeyModifier.canonicalOrder.filter { modifiers.contains($0) }
    }

    var modifierSymbols: String {
        orderedModifiers.map(\.symbol).joined()
    }

    /// `⌃⌥V` — the app target supplies the layout-dependent key label.
    func displayString(keyLabel: String) -> String {
        modifierSymbols + keyLabel
    }

    /// `Control-Option-V` for VoiceOver; `separator: "–"` for prose copy.
    func spokenName(keyName: String, separator: String = "-") -> String {
        (orderedModifiers.map(\.spokenName) + [keyName]).joined(separator: separator)
    }
}

// MARK: - Validation

/// Which shortcuts NotchClip is willing to claim system-wide.
public enum NotchClipHotKeyValidation {
    public enum Failure: Equatable, Sendable {
        /// A bare letter, digit, or shift-only combination would hijack typing.
        case missingRequiredModifier
        /// Escape cancels recording and dismisses the panel; it can never be the shortcut.
        case reservedKey
    }

    /// Function keys carry no typing meaning, so they are legal without modifiers.
    public static let functionKeyCodes: Set<UInt16> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A
    ]

    public static let escapeKeyCode: UInt16 = 0x35

    /// Any one of these makes a shortcut safe; ⇧ alone does not.
    public static let qualifyingModifiers: Set<NotchClipHotKeyModifier> = [.control, .option, .command]

    public static func failure(for binding: NotchClipHotKeyBinding) -> Failure? {
        if binding.keyCode == escapeKeyCode { return .reservedKey }
        if !binding.modifiers.isDisjoint(with: qualifyingModifiers) { return nil }
        if functionKeyCodes.contains(binding.keyCode) { return nil }
        return .missingRequiredModifier
    }

    public static func isValid(_ binding: NotchClipHotKeyBinding) -> Bool {
        failure(for: binding) == nil
    }

    public static func message(for failure: Failure) -> String {
        switch failure {
        case .missingRequiredModifier:
            return "Add Control, Option, or Command to that shortcut."
        case .reservedKey:
            return "Escape is reserved for closing the clipboard."
        }
    }
}
