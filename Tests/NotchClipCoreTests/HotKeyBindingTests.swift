import XCTest
@testable import NotchClipCore

final class HotKeyBindingTests: XCTestCase {
    // MARK: - Encoding

    func testDefaultBindingIsControlV() {
        XCTAssertEqual(NotchClipHotKey.defaultBinding.keyCode, 0x09)
        XCTAssertEqual(NotchClipHotKey.defaultBinding.modifiers, [.control])
    }

    func testEncodingRoundTripsEveryModifierCombination() {
        let all = NotchClipHotKeyModifier.allCases
        for mask in 0..<(1 << all.count) {
            let modifiers = Set(all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            let binding = NotchClipHotKeyBinding(keyCode: 0x31, modifiers: modifiers)
            XCTAssertEqual(NotchClipHotKeyBinding.decode(binding.encoded), binding)
        }
    }

    func testEncodedFormIsStable() {
        // Frozen on-disk shape; changing it silently resets every user's shortcut.
        XCTAssertEqual(NotchClipHotKey.defaultBinding.encoded, "nc1:9:1")
        let all = NotchClipHotKeyBinding(keyCode: 0x7A, modifiers: [.control, .option, .shift, .command])
        XCTAssertEqual(all.encoded, "nc1:122:15")
        XCTAssertEqual(NotchClipHotKeyBinding.decode("nc1:9:1"), NotchClipHotKey.defaultBinding)
    }

    func testDecodeRejectsCorruptAndAbsentData() {
        let corrupt = [
            nil,
            "",
            "nc1",
            "nc1:9",
            "nc1:9:1:1",
            "nc0:9:1",
            "nc1:v:1",
            "nc1:9:x",
            "nc1:-1:1",
            "nc1:70000:1",
            // Unknown modifier bits mean a newer encoding wrote this.
            "nc1:9:16",
            "⌃V"
        ]
        for raw in corrupt {
            XCTAssertNil(NotchClipHotKeyBinding.decode(raw), "decoded \(raw ?? "nil")")
        }
    }

    func testPreferencesFallBackToDefaultOnAbsentAndCorruptData() {
        let name = "com.anoop.notchclip.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }

        XCTAssertEqual(AppPreferences.load(defaults: suite).hotKey, NotchClipHotKey.defaultBinding)

        suite.set("garbage", forKey: AppPreferences.hotKeyKey)
        XCTAssertEqual(AppPreferences.load(defaults: suite).hotKey, NotchClipHotKey.defaultBinding)

        suite.set(42, forKey: AppPreferences.hotKeyKey)
        XCTAssertEqual(AppPreferences.load(defaults: suite).hotKey, NotchClipHotKey.defaultBinding)
    }

    func testPreferencesPersistACustomBinding() {
        let name = "com.anoop.notchclip.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }

        let custom = NotchClipHotKeyBinding(keyCode: 0x31, modifiers: [.option, .command])
        AppPreferences(hotKey: custom).save(defaults: suite)
        XCTAssertEqual(AppPreferences.load(defaults: suite).hotKey, custom)
        // Other preferences keep their own defaults.
        XCTAssertEqual(AppPreferences.load(defaults: suite).historyLimit, RetentionPolicy.defaultLimit)
    }

    // MARK: - Display

    func testModifierSymbolsUseCanonicalOrder() {
        let binding = NotchClipHotKeyBinding(
            keyCode: 0x09,
            modifiers: [.command, .shift, .option, .control]
        )
        XCTAssertEqual(binding.modifierSymbols, "⌃⌥⇧⌘")
        XCTAssertEqual(binding.displayString(keyLabel: "V"), "⌃⌥⇧⌘V")
        XCTAssertEqual(
            binding.orderedModifiers,
            [.control, .option, .shift, .command]
        )
    }

    func testCanonicalOrderCoversEveryModifierExactlyOnce() {
        XCTAssertEqual(
            Set(NotchClipHotKeyModifier.canonicalOrder),
            Set(NotchClipHotKeyModifier.allCases)
        )
        XCTAssertEqual(
            NotchClipHotKeyModifier.canonicalOrder.count,
            NotchClipHotKeyModifier.allCases.count
        )
    }

    func testOrderingIsIndependentOfInsertionOrder() {
        let a = NotchClipHotKeyBinding(keyCode: 0x09, modifiers: [.shift, .control])
        let b = NotchClipHotKeyBinding(keyCode: 0x09, modifiers: [.control, .shift])
        XCTAssertEqual(a.modifierSymbols, "⌃⇧")
        XCTAssertEqual(a.modifierSymbols, b.modifierSymbols)
    }

    func testSpokenNameJoinsModifiersAndKey() {
        let binding = NotchClipHotKeyBinding(keyCode: 0x09, modifiers: [.control])
        XCTAssertEqual(binding.spokenName(keyName: "V"), "Control-V")
        XCTAssertEqual(binding.spokenName(keyName: "V", separator: "–"), "Control–V")
        let bare = NotchClipHotKeyBinding(keyCode: 0x7A, modifiers: [])
        XCTAssertEqual(bare.spokenName(keyName: "F1"), "F1")
        XCTAssertEqual(bare.modifierSymbols, "")
    }

    func testDefaultDescriptorsMatchTheDefaultBinding() {
        XCTAssertEqual(NotchClipHotKey.defaultBinding.displayString(keyLabel: "V"), NotchClipHotKey.displayName)
        XCTAssertEqual(NotchClipHotKey.defaultBinding.spokenName(keyName: "V"), NotchClipHotKey.accessibilityName)
        XCTAssertEqual(
            NotchClipHotKey.defaultBinding.spokenName(keyName: "V", separator: "–"),
            NotchClipHotKey.humanReadableName
        )
    }

    // MARK: - Validation

    func testBareLettersAndDigitsAreRejected() {
        // 0x09 is V, 0x12 is 1.
        for keyCode: UInt16 in [0x09, 0x12] {
            XCTAssertEqual(
                NotchClipHotKeyValidation.failure(for: NotchClipHotKeyBinding(keyCode: keyCode, modifiers: [])),
                .missingRequiredModifier
            )
            XCTAssertEqual(
                NotchClipHotKeyValidation.failure(for: NotchClipHotKeyBinding(keyCode: keyCode, modifiers: [.shift])),
                .missingRequiredModifier
            )
        }
    }

    func testAnyQualifyingModifierMakesALetterLegal() {
        for modifier in NotchClipHotKeyValidation.qualifyingModifiers {
            XCTAssertTrue(
                NotchClipHotKeyValidation.isValid(
                    NotchClipHotKeyBinding(keyCode: 0x09, modifiers: [modifier])
                )
            )
            XCTAssertTrue(
                NotchClipHotKeyValidation.isValid(
                    NotchClipHotKeyBinding(keyCode: 0x09, modifiers: [modifier, .shift])
                )
            )
        }
        XCTAssertFalse(NotchClipHotKeyValidation.qualifyingModifiers.contains(.shift))
    }

    func testBareFunctionKeysAreAllowed() {
        // F1 … F19 plus F20.
        let functionKeys: [UInt16] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
            0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A
        ]
        XCTAssertEqual(Set(functionKeys), NotchClipHotKeyValidation.functionKeyCodes)
        for keyCode in functionKeys {
            XCTAssertTrue(
                NotchClipHotKeyValidation.isValid(NotchClipHotKeyBinding(keyCode: keyCode, modifiers: [])),
                "F-key \(keyCode) should be legal bare"
            )
            XCTAssertTrue(
                NotchClipHotKeyValidation.isValid(NotchClipHotKeyBinding(keyCode: keyCode, modifiers: [.shift]))
            )
        }
    }

    func testEscapeIsReservedWithAndWithoutModifiers() {
        XCTAssertEqual(NotchClipHotKeyValidation.escapeKeyCode, 0x35)
        XCTAssertEqual(
            NotchClipHotKeyValidation.failure(for: NotchClipHotKeyBinding(keyCode: 0x35, modifiers: [])),
            .reservedKey
        )
        XCTAssertEqual(
            NotchClipHotKeyValidation.failure(
                for: NotchClipHotKeyBinding(keyCode: 0x35, modifiers: [.control, .command])
            ),
            .reservedKey
        )
    }

    func testDefaultBindingPassesValidation() {
        XCTAssertTrue(NotchClipHotKeyValidation.isValid(NotchClipHotKey.defaultBinding))
    }

    func testFailureMessagesAreDistinctAndNonEmpty() {
        let missing = NotchClipHotKeyValidation.message(for: .missingRequiredModifier)
        let reserved = NotchClipHotKeyValidation.message(for: .reservedKey)
        XCTAssertFalse(missing.isEmpty)
        XCTAssertFalse(reserved.isEmpty)
        XCTAssertNotEqual(missing, reserved)
    }

    // MARK: - Seam

    func testFakeRegistrarTracksTheRequestedBinding() {
        let fake = FakeHotKeyRegistrar()
        XCTAssertEqual(fake.binding, NotchClipHotKey.defaultBinding)

        let custom = NotchClipHotKeyBinding(keyCode: 0x31, modifiers: [.control, .option])
        XCTAssertTrue(fake.register(custom))
        XCTAssertEqual(fake.binding, custom)
        XCTAssertTrue(fake.isRegistered)

        // The no-argument shim re-registers whatever is current.
        fake.unregister()
        XCTAssertTrue(fake.register())
        XCTAssertEqual(fake.binding, custom)
    }

    func testFakeRegistrarKeepsTheAttemptedBindingOnFailure() {
        let fake = FakeHotKeyRegistrar()
        fake.shouldFailRegistration = true
        let custom = NotchClipHotKeyBinding(keyCode: 0x31, modifiers: [.command])
        XCTAssertFalse(fake.register(custom))
        XCTAssertFalse(fake.isRegistered)
        XCTAssertEqual(fake.binding, custom)
        XCTAssertNotNil(fake.registrationError)
    }
}
