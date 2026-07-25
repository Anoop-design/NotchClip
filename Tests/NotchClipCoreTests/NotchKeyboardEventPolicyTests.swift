import AppKit
@testable import NotchClip
import XCTest

final class NotchKeyboardEventPolicyTests: XCTestCase {
    func testArrowKeyDeviceFlagsAreNotTreatedAsUserModifiers() {
        let modifiers = NotchKeyboardEventPolicy.userModifiers(
            in: [.function, .numericPad]
        )

        XCTAssertTrue(modifiers.isEmpty)
    }

    func testUserHeldShiftSurvivesArrowKeyDeviceFlags() {
        let modifiers = NotchKeyboardEventPolicy.userModifiers(
            in: [.function, .numericPad, .shift]
        )

        XCTAssertEqual(modifiers, .shift)
    }

    func testUserHeldOptionStillBlocksUnmodifiedNavigationPath() {
        let modifiers = NotchKeyboardEventPolicy.userModifiers(
            in: [.function, .numericPad, .option]
        )

        XCTAssertEqual(modifiers, .option)
    }
}
