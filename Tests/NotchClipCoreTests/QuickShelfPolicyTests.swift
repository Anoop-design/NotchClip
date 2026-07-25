import XCTest
@testable import NotchClipCore

final class QuickShelfPolicyTests: XCTestCase {
    func testShelfHasHardEightItemLimit() {
        let entries = (0..<12).map { entry("recent-\($0)", age: $0) }

        let shelf = QuickShelfPolicy.entries(from: entries)

        XCTAssertEqual(shelf.count, 8)
        XCTAssertEqual(
            shelf.map(\.previewText),
            (0..<8).map { "recent-\($0)" }
        )
    }

    func testPinnedClipsDoNotCrowdOutRecentClips() {
        let pinned = (0..<8).map { entry("pinned-\($0)", pinned: true, age: $0) }
        let recent = (0..<12).map { entry("recent-\($0)", age: $0) }

        let shelf = QuickShelfPolicy.entries(from: pinned + recent)

        XCTAssertEqual(
            shelf.map(\.previewText),
            ["pinned-0", "pinned-1", "pinned-2"]
                + (0..<5).map { "recent-\($0)" }
        )
    }

    func testRecentClipsFillSpaceWhenThereAreFewPins() {
        let pinned = [entry("pinned", pinned: true)]
        let recent = (0..<16).map { entry("recent-\($0)", age: $0) }

        let shelf = QuickShelfPolicy.entries(from: pinned + recent)

        XCTAssertEqual(
            shelf.map(\.previewText),
            ["pinned"] + (0..<7).map { "recent-\($0)" }
        )
    }

    func testPinnedClipsFillSpaceWhenThereAreFewRecents() {
        let pinned = (0..<16).map { entry("pinned-\($0)", pinned: true, age: $0) }
        let recent = [entry("recent")]

        let shelf = QuickShelfPolicy.entries(from: pinned + recent)

        XCTAssertEqual(
            shelf.map(\.previewText),
            (0..<7).map { "pinned-\($0)" } + ["recent"]
        )
    }

    func testSelectionIsClampedToVisibleShelf() {
        let shelf = (0..<8).map { entry("item-\($0)", age: $0) }

        XCTAssertEqual(
            QuickShelfPolicy.moveSelection(currentID: nil, delta: 1, entries: shelf),
            shelf[0].id
        )
        XCTAssertEqual(
            QuickShelfPolicy.moveSelection(currentID: shelf[7].id, delta: 1, entries: shelf),
            shelf[7].id
        )
        XCTAssertEqual(
            QuickShelfPolicy.moveSelection(currentID: shelf[0].id, delta: -1, entries: shelf),
            shelf[0].id
        )
    }

    private func entry(
        _ name: String,
        pinned: Bool = false,
        age: Int = 0
    ) -> ClipboardEntry {
        ClipboardEntry(
            createdAt: Date(timeIntervalSince1970: TimeInterval(1_000 - age)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(1_000 - age)),
            isPinned: pinned,
            primaryKind: .plainText,
            previewText: name,
            searchText: name,
            fingerprint: name
        )
    }
}
