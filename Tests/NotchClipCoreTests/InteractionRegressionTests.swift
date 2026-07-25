import XCTest
import AppKit
@testable import NotchClipCore

final class PasteDeliveryPolicyRegressionTests: XCTestCase {
    func testAutomaticDeliveryStartsOnlyForFirstSelectionDismissalWithTarget() {
        XCTAssertTrue(
            PasteDeliveryPolicy.shouldStart(
                reason: .selection,
                hasTarget: true,
                alreadyRestored: false
            )
        )

        for reason in DismissReason.allCases where reason != .selection {
            XCTAssertFalse(
                PasteDeliveryPolicy.shouldStart(
                    reason: reason,
                    hasTarget: true,
                    alreadyRestored: false
                ),
                "Unexpected delivery for \(reason)"
            )
        }
        XCTAssertFalse(
            PasteDeliveryPolicy.shouldStart(
                reason: .selection,
                hasTarget: false,
                alreadyRestored: false
            )
        )
        XCTAssertFalse(
            PasteDeliveryPolicy.shouldStart(
                reason: .selection,
                hasTarget: true,
                alreadyRestored: true
            )
        )
    }

    func testDelayedDeliveryRequiresExactGeneration() {
        XCTAssertTrue(PasteDeliveryPolicy.isCurrent(token: 0, generation: 0))
        XCTAssertTrue(PasteDeliveryPolicy.isCurrent(token: 42, generation: 42))
        XCTAssertTrue(PasteDeliveryPolicy.isCurrent(token: .max, generation: .max))
        XCTAssertFalse(PasteDeliveryPolicy.isCurrent(token: 41, generation: 42))
        XCTAssertFalse(PasteDeliveryPolicy.isCurrent(token: 43, generation: 42))
    }

    func testCommandVTargetMustBeExactPositiveFrontmostPID() {
        XCTAssertTrue(PasteDeliveryPolicy.isTargetFrontmost(targetPID: 123, frontmostPID: 123))
        XCTAssertFalse(PasteDeliveryPolicy.isTargetFrontmost(targetPID: 123, frontmostPID: 124))
        XCTAssertFalse(PasteDeliveryPolicy.isTargetFrontmost(targetPID: 123, frontmostPID: nil))
        XCTAssertFalse(PasteDeliveryPolicy.isTargetFrontmost(targetPID: 0, frontmostPID: 0))
        XCTAssertFalse(PasteDeliveryPolicy.isTargetFrontmost(targetPID: -1, frontmostPID: -1))
    }
}

final class DragGesturePolicyRegressionTests: XCTestCase {
    func testDefaultThresholdDoesNotStartAtOrBelowBoundary() {
        let origin = CGPoint(x: 10, y: 20)
        XCTAssertFalse(DragGesturePolicy.shouldBeginDrag(mouseDown: origin, current: origin))
        XCTAssertFalse(
            DragGesturePolicy.shouldBeginDrag(
                mouseDown: origin,
                current: CGPoint(x: 14, y: 20)
            )
        )
        XCTAssertFalse(
            DragGesturePolicy.shouldBeginDrag(
                mouseDown: origin,
                current: CGPoint(x: 6, y: 20)
            )
        )
    }

    func testDefaultThresholdStartsImmediatelyBeyondBoundaryInEveryDirection() {
        let origin = CGPoint(x: 10, y: 20)
        let epsilon: CGFloat = 0.001
        XCTAssertTrue(
            DragGesturePolicy.shouldBeginDrag(
                mouseDown: origin,
                current: CGPoint(x: 14 + epsilon, y: 20)
            )
        )
        XCTAssertTrue(
            DragGesturePolicy.shouldBeginDrag(
                mouseDown: origin,
                current: CGPoint(x: 10, y: 16 - epsilon)
            )
        )
    }

    func testDiagonalMovementUsesEuclideanDistance() {
        let origin = CGPoint.zero
        // Neither axis alone crosses four points, but the 3-4-5 diagonal does.
        XCTAssertTrue(
            DragGesturePolicy.shouldBeginDrag(
                mouseDown: origin,
                current: CGPoint(x: 3, y: 4)
            )
        )
        XCTAssertTrue(
            DragGesturePolicy.shouldBeginDrag(
                mouseDown: origin,
                current: CGPoint(x: 3, y: 3)
            )
        )
        XCTAssertFalse(
            DragGesturePolicy.shouldBeginDrag(
                mouseDown: origin,
                current: CGPoint(x: 2.8, y: 2.8)
            )
        )
    }

    func testNegativeThresholdNeverStartsDrag() {
        XCTAssertFalse(
            DragGesturePolicy.shouldBeginDrag(
                mouseDown: .zero,
                current: CGPoint(x: 10_000, y: 10_000),
                threshold: -1
            )
        )
    }

    func testZeroThresholdRequiresActualMovement() {
        XCTAssertFalse(
            DragGesturePolicy.shouldBeginDrag(
                mouseDown: .zero,
                current: .zero,
                threshold: 0
            )
        )
        XCTAssertTrue(
            DragGesturePolicy.shouldBeginDrag(
                mouseDown: .zero,
                current: CGPoint(x: 0.001, y: 0),
                threshold: 0
            )
        )
    }
}

/// Destination-facing integration coverage for the same lazy pasteboard items used by AppKit drags.
///
/// These tests intentionally ask Cocoa's standard readers to consume the items from a named
/// pasteboard. Calling `LazyDragPayloadProvider` directly proves byte loading, but does not prove
/// that a real text, file, or image destination can discover and decode the declared flavor.
final class DragDestinationCompatibilityTests: XCTestCase {
    func testLazyTextItemIsReadableByCocoaStringDestination() throws {
        let text = "NotchClip destination text \(UUID().uuidString)"
        let data = Data(text.utf8)
        let entry = try makeEntry(
            representations: [
                ParsedRepresentation(
                    itemIndex: 0,
                    typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText,
                    data: data
                )
            ],
            kind: .plainText,
            previewText: text
        )

        let built = engine.makeLazyDraggingItems(for: entry)
        XCTAssertEqual(built.items.count, 1)
        XCTAssertEqual(payloadStore.loadCount, 0)

        let pasteboard = uniquePasteboard()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(built.items))

        let values = pasteboard.readObjects(forClasses: [NSString.self]) as? [NSString]
        XCTAssertEqual(values?.map(String.init), [text])
        XCTAssertGreaterThan(payloadStore.loadCount, 0)

        // AppKit's data providers are weakly held by pasteboard items on some OS releases.
        // Match production by retaining them through the destination read.
        withExtendedLifetime(built.providers) {}
    }

    func testLazyFileURLItemIsReadableByCocoaURLDestination() throws {
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchclip-drag-\(UUID().uuidString).txt")
        try Data("file payload".utf8).write(to: temporaryFile, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryFile) }

        let entry = try makeEntry(
            representations: [
                ParsedRepresentation(
                    itemIndex: 0,
                    typeIdentifier: ClipboardTypeIdentifiers.fileURL,
                    data: Data(temporaryFile.absoluteString.utf8),
                    originalFilePath: temporaryFile.path
                )
            ],
            kind: .fileList,
            previewText: temporaryFile.lastPathComponent,
            originalFilePaths: [temporaryFile.path]
        )

        let built = engine.makeLazyDraggingItems(for: entry)
        XCTAssertEqual(built.items.count, 1)
        XCTAssertEqual(payloadStore.loadCount, 0)

        let pasteboard = uniquePasteboard()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(built.items))

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let values = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL]
        XCTAssertEqual(
            values?.map { ($0 as URL).standardizedFileURL.path },
            [temporaryFile.standardizedFileURL.path]
        )
        XCTAssertGreaterThan(payloadStore.loadCount, 0)

        withExtendedLifetime(built.providers) {}
    }

    func testLazyTIFFItemIsReadableByCocoaImageDestination() throws {
        let sourceImage = NSImage(size: NSSize(width: 3, height: 2), flipped: false) { rect in
            NSColor.systemPurple.setFill()
            rect.fill()
            return true
        }
        let tiffData = try XCTUnwrap(sourceImage.tiffRepresentation)
        let entry = try makeEntry(
            representations: [
                ParsedRepresentation(
                    itemIndex: 0,
                    typeIdentifier: ClipboardTypeIdentifiers.tiff,
                    data: tiffData
                )
            ],
            kind: .image,
            previewText: "Image"
        )

        let built = engine.makeLazyDraggingItems(for: entry)
        XCTAssertEqual(built.items.count, 1)
        XCTAssertEqual(payloadStore.loadCount, 0)

        let pasteboard = uniquePasteboard()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(built.items))

        let decoded = try XCTUnwrap(NSImage(pasteboard: pasteboard))
        XCTAssertEqual(decoded.size.width, 3, accuracy: 0.01)
        XCTAssertEqual(decoded.size.height, 2, accuracy: 0.01)
        XCTAssertGreaterThan(payloadStore.loadCount, 0)

        withExtendedLifetime(built.providers) {}
    }

    private var engine: ClipboardEngine!
    private var payloadStore: InMemoryPayloadStore!

    override func setUp() {
        super.setUp()
        payloadStore = InMemoryPayloadStore()
        engine = ClipboardEngine(
            repository: InMemoryClipboardRepository(),
            payloadStore: payloadStore
        )
    }

    override func tearDown() {
        engine = nil
        payloadStore = nil
        super.tearDown()
    }

    private func makeEntry(
        representations: [ParsedRepresentation],
        kind: ClipboardContentKind,
        previewText: String,
        originalFilePaths: [String] = []
    ) throws -> ClipboardEntry {
        let parsed = ParsedPasteboardItem(
            representations: representations,
            primaryKind: kind,
            previewText: previewText,
            searchText: previewText,
            fingerprint: Fingerprinter.fingerprint(representations: representations),
            originalFilePaths: originalFilePaths
        )
        guard case .inserted(let entry) = engine.ingest(parsed: parsed) else {
            throw TestFailure.entryWasNotInserted
        }
        return entry
    }

    private func uniquePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("NotchClip.Destination.\(UUID().uuidString)"))
    }

    private enum TestFailure: Error {
        case entryWasNotInserted
    }
}
