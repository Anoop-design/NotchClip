import XCTest
@testable import NotchClipCore

final class QuickLookFirstFilePolicyTests: XCTestCase {
    func testFirstExistingFilePathSelectsFirstMatchInOrder() {
        let paths = [
            "/missing/a",
            "/exists/b",
            "/exists/c"
        ]
        let existing: Set<String> = ["/exists/b", "/exists/c"]
        let first = QuickLookPolicy.firstExistingFilePath(from: paths) { existing.contains($0) }
        XCTAssertEqual(first, "/exists/b")
    }

    func testFirstExistingFilePathNilWhenNoneExist() {
        let first = QuickLookPolicy.firstExistingFilePath(from: ["/a", "/b"]) { _ in false }
        XCTAssertNil(first)
    }

    func testRouteUsesFirstExistingOnly() {
        let entry = ClipboardEntry(
            primaryKind: .fileList,
            previewText: "files",
            searchText: "files",
            fingerprint: "ql-files",
            payloadRefs: [
                PayloadReference(
                    typeIdentifier: ClipboardTypeIdentifiers.fileURL,
                    relativePath: "r1",
                    byteCount: 1,
                    originalFilePath: "/missing/one"
                ),
                PayloadReference(
                    typeIdentifier: ClipboardTypeIdentifiers.fileURL,
                    relativePath: "r2",
                    byteCount: 1,
                    originalFilePath: "/present/two"
                ),
                PayloadReference(
                    typeIdentifier: ClipboardTypeIdentifiers.fileURL,
                    relativePath: "r3",
                    byteCount: 1,
                    originalFilePath: "/present/three"
                )
            ]
        )
        let route = QuickLookPolicy.route(for: entry) { path in
            path == "/present/two" || path == "/present/three"
        }
        if case .fileURLs(let paths) = route {
            XCTAssertEqual(paths, ["/present/two"])
        } else {
            XCTFail("expected first existing file only, got \(route)")
        }
    }

    func testRouteMissingWhenNoFilesExist() {
        let entry = ClipboardEntry(
            primaryKind: .fileList,
            previewText: "gone",
            searchText: "gone",
            fingerprint: "ql-gone",
            payloadRefs: [
                PayloadReference(
                    typeIdentifier: ClipboardTypeIdentifiers.fileURL,
                    relativePath: "r",
                    byteCount: 1,
                    originalFilePath: "/nope"
                )
            ]
        )
        if case .missingFiles = QuickLookPolicy.route(for: entry, fileExists: { _ in false }) {
            // ok
        } else {
            XCTFail("expected missingFiles")
        }
    }
}

final class QuickLookLifecyclePolicyTests: XCTestCase {
    func testStaleGenerationRejected() {
        XCTAssertTrue(
            QuickLookLifecyclePolicy.shouldApplyStagingCompletion(
                requestGeneration: 3,
                currentGeneration: 3
            )
        )
        XCTAssertFalse(
            QuickLookLifecyclePolicy.shouldApplyStagingCompletion(
                requestGeneration: 2,
                currentGeneration: 3
            )
        )
        XCTAssertFalse(
            QuickLookLifecyclePolicy.shouldApplyStagingCompletion(
                requestGeneration: 4,
                currentGeneration: 3
            )
        )
    }

    func testSpaceCancelToggleSemantics() {
        XCTAssertTrue(QuickLookLifecyclePolicy.shouldCancelOrCloseOnSpace(isActiveOrStaging: true))
        XCTAssertFalse(QuickLookLifecyclePolicy.shouldCancelOrCloseOnSpace(isActiveOrStaging: false))
    }

    func testRefocusAllowedOnlyForSameVisibleInteractablePresentation() {
        XCTAssertTrue(
            QuickLookLifecyclePolicy.shouldRefocusParentAfterClose(
                capturedOpenGeneration: 5,
                currentOpenGeneration: 5,
                phase: .expanded,
                windowIsVisible: true
            )
        )
        XCTAssertTrue(
            QuickLookLifecyclePolicy.shouldRefocusParentAfterClose(
                capturedOpenGeneration: 5,
                currentOpenGeneration: 5,
                phase: .expanding,
                windowIsVisible: true
            )
        )
        // Newer presentation must not refocus.
        XCTAssertFalse(
            QuickLookLifecyclePolicy.shouldRefocusParentAfterClose(
                capturedOpenGeneration: 5,
                currentOpenGeneration: 6,
                phase: .expanded,
                windowIsVisible: true
            )
        )
        // Hidden / collapsing must never resurrect.
        XCTAssertFalse(
            QuickLookLifecyclePolicy.shouldRefocusParentAfterClose(
                capturedOpenGeneration: 5,
                currentOpenGeneration: 5,
                phase: .hidden,
                windowIsVisible: true
            )
        )
        XCTAssertFalse(
            QuickLookLifecyclePolicy.shouldRefocusParentAfterClose(
                capturedOpenGeneration: 5,
                currentOpenGeneration: 5,
                phase: .collapsing,
                windowIsVisible: true
            )
        )
        XCTAssertFalse(
            QuickLookLifecyclePolicy.shouldRefocusParentAfterClose(
                capturedOpenGeneration: 5,
                currentOpenGeneration: 5,
                phase: .expanded,
                windowIsVisible: false
            )
        )
    }

    func testParentDismissCancelsQuickLookExceptOutsideClick() {
        XCTAssertTrue(
            QuickLookLifecyclePolicy.shouldCancelQuickLookOnParentDismiss(
                isQuickLookActiveOrStaging: true,
                reason: .escape
            )
        )
        XCTAssertTrue(
            QuickLookLifecyclePolicy.shouldCancelQuickLookOnParentDismiss(
                isQuickLookActiveOrStaging: true,
                reason: .hotkeyToggle
            )
        )
        XCTAssertTrue(
            QuickLookLifecyclePolicy.shouldCancelQuickLookOnParentDismiss(
                isQuickLookActiveOrStaging: true,
                reason: .selection
            )
        )
        XCTAssertTrue(
            QuickLookLifecyclePolicy.shouldCancelQuickLookOnParentDismiss(
                isQuickLookActiveOrStaging: true,
                reason: .programmatic
            )
        )
        XCTAssertFalse(
            QuickLookLifecyclePolicy.shouldCancelQuickLookOnParentDismiss(
                isQuickLookActiveOrStaging: true,
                reason: .outsideClick
            )
        )
        XCTAssertFalse(
            QuickLookLifecyclePolicy.shouldCancelQuickLookOnParentDismiss(
                isQuickLookActiveOrStaging: false,
                reason: .escape
            )
        )
    }
}
