import AppKit
import Carbon
import SwiftUI
import NotchClipCore

/// The three renderings of a shortcut a NotchClip surface can need.
struct HotKeyDescription: Equatable {
    /// `⌃V` — keycaps and menus.
    let symbolic: String
    /// `Control-V` — VoiceOver.
    let spoken: String
    /// `Control–V` — sentence copy, en dash to match the rest of the onboarding prose.
    let prose: String

    static let `default` = HotKeyDescription(
        symbolic: NotchClipHotKey.displayName,
        spoken: NotchClipHotKey.accessibilityName,
        prose: NotchClipHotKey.humanReadableName
    )
}

/// Virtual key code → human label. Keys that produce characters are resolved
/// against the *current* keyboard layout (a French AZERTY user recorded ⌃A on
/// the physical Q key and must see ⌃A), so this cannot live in Core.
enum HotKeyKeyLabels {
    static func description(for binding: NotchClipHotKeyBinding) -> HotKeyDescription {
        HotKeyDescription(
            symbolic: binding.displayString(keyLabel: symbol(for: binding.keyCode)),
            spoken: binding.spokenName(keyName: spokenName(for: binding.keyCode)),
            prose: binding.spokenName(keyName: spokenName(for: binding.keyCode), separator: "–")
        )
    }

    static func symbol(for keyCode: UInt16) -> String {
        if let special = specialKeys[keyCode] { return special.symbol }
        if let character = layoutCharacter(for: keyCode) { return character.uppercased() }
        return ansiFallback[keyCode] ?? "Key \(keyCode)"
    }

    static func spokenName(for keyCode: UInt16) -> String {
        if let special = specialKeys[keyCode] { return special.spoken }
        if let character = layoutCharacter(for: keyCode) { return character.uppercased() }
        return ansiFallback[keyCode] ?? "key \(keyCode)"
    }

    /// SwiftUI menu equivalents take a lowercase character; anything that is not
    /// a single character (arrows, Space, F-keys) simply gets no menu shortcut.
    static func keyEquivalent(for keyCode: UInt16) -> KeyEquivalent? {
        guard specialKeys[keyCode] == nil else { return nil }
        let label = layoutCharacter(for: keyCode) ?? ansiFallback[keyCode]
        guard let lowered = label?.lowercased(), lowered.count == 1, let scalar = lowered.first else {
            return nil
        }
        return KeyEquivalent(scalar)
    }

    // MARK: - Tables

    private struct SpecialKey {
        let symbol: String
        let spoken: String
    }

    private static let specialKeys: [UInt16: SpecialKey] = [
        UInt16(kVK_Return): SpecialKey(symbol: "↩", spoken: "Return"),
        UInt16(kVK_ANSI_KeypadEnter): SpecialKey(symbol: "⌤", spoken: "Enter"),
        UInt16(kVK_Tab): SpecialKey(symbol: "⇥", spoken: "Tab"),
        UInt16(kVK_Space): SpecialKey(symbol: "Space", spoken: "Space"),
        UInt16(kVK_Delete): SpecialKey(symbol: "⌫", spoken: "Delete"),
        UInt16(kVK_ForwardDelete): SpecialKey(symbol: "⌦", spoken: "Forward Delete"),
        UInt16(kVK_Escape): SpecialKey(symbol: "⎋", spoken: "Escape"),
        UInt16(kVK_Home): SpecialKey(symbol: "↖", spoken: "Home"),
        UInt16(kVK_End): SpecialKey(symbol: "↘", spoken: "End"),
        UInt16(kVK_PageUp): SpecialKey(symbol: "⇞", spoken: "Page Up"),
        UInt16(kVK_PageDown): SpecialKey(symbol: "⇟", spoken: "Page Down"),
        UInt16(kVK_Help): SpecialKey(symbol: "Help", spoken: "Help"),
        UInt16(kVK_LeftArrow): SpecialKey(symbol: "←", spoken: "Left Arrow"),
        UInt16(kVK_RightArrow): SpecialKey(symbol: "→", spoken: "Right Arrow"),
        UInt16(kVK_UpArrow): SpecialKey(symbol: "↑", spoken: "Up Arrow"),
        UInt16(kVK_DownArrow): SpecialKey(symbol: "↓", spoken: "Down Arrow"),
        UInt16(kVK_F1): SpecialKey(symbol: "F1", spoken: "F1"),
        UInt16(kVK_F2): SpecialKey(symbol: "F2", spoken: "F2"),
        UInt16(kVK_F3): SpecialKey(symbol: "F3", spoken: "F3"),
        UInt16(kVK_F4): SpecialKey(symbol: "F4", spoken: "F4"),
        UInt16(kVK_F5): SpecialKey(symbol: "F5", spoken: "F5"),
        UInt16(kVK_F6): SpecialKey(symbol: "F6", spoken: "F6"),
        UInt16(kVK_F7): SpecialKey(symbol: "F7", spoken: "F7"),
        UInt16(kVK_F8): SpecialKey(symbol: "F8", spoken: "F8"),
        UInt16(kVK_F9): SpecialKey(symbol: "F9", spoken: "F9"),
        UInt16(kVK_F10): SpecialKey(symbol: "F10", spoken: "F10"),
        UInt16(kVK_F11): SpecialKey(symbol: "F11", spoken: "F11"),
        UInt16(kVK_F12): SpecialKey(symbol: "F12", spoken: "F12"),
        UInt16(kVK_F13): SpecialKey(symbol: "F13", spoken: "F13"),
        UInt16(kVK_F14): SpecialKey(symbol: "F14", spoken: "F14"),
        UInt16(kVK_F15): SpecialKey(symbol: "F15", spoken: "F15"),
        UInt16(kVK_F16): SpecialKey(symbol: "F16", spoken: "F16"),
        UInt16(kVK_F17): SpecialKey(symbol: "F17", spoken: "F17"),
        UInt16(kVK_F18): SpecialKey(symbol: "F18", spoken: "F18"),
        UInt16(kVK_F19): SpecialKey(symbol: "F19", spoken: "F19"),
        UInt16(kVK_F20): SpecialKey(symbol: "F20", spoken: "F20")
    ]

    /// Used when the layout has no Unicode data (rare) or translates to nothing.
    private static let ansiFallback: [UInt16: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
        0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",",
        0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`"
    ]

    // MARK: - Layout translation

    private static func layoutCharacter(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let translated = String(utf16CodeUnits: characters, count: length)
        // Control characters and whitespace are handled by `specialKeys`.
        guard !translated.isEmpty,
              translated.rangeOfCharacter(from: .controlCharacters) == nil,
              translated.trimmingCharacters(in: .whitespaces) == translated else {
            return nil
        }
        return translated
    }
}

extension NSEvent.ModifierFlags {
    var notchClipHotKeyModifiers: Set<NotchClipHotKeyModifier> {
        var modifiers: Set<NotchClipHotKeyModifier> = []
        if contains(.control) { modifiers.insert(.control) }
        if contains(.option) { modifiers.insert(.option) }
        if contains(.shift) { modifiers.insert(.shift) }
        if contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}
