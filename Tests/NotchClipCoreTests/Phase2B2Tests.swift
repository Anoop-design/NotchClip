import XCTest
@testable import NotchClipCore
import Foundation
import AppKit

final class PasteboardItemFactoryTests: XCTestCase {
    func testMakeItemsPreservesTwoFilesAndDoesNotClearUnrelatedBoard() throws {
        let store = InMemoryPayloadStore()
        let engine = ClipboardEngine(repository: InMemoryClipboardRepository(), payloadStore: store)

        // Seed unrelated board content.
        let other = NSPasteboard(name: NSPasteboard.Name("NotchClipOther.\(UUID().uuidString)"))
        other.clearContents()
        other.setString("keep-me", forType: .string)

        let pathA = "/tmp/notch-a-\(UUID().uuidString).txt"
        let pathB = "/tmp/notch-b-\(UUID().uuidString).txt"
        let dataA = Data(pathA.utf8)
        let dataB = Data(pathB.utf8)
        let reps = [
            ParsedRepresentation(
                itemIndex: 0,
                typeIdentifier: ClipboardTypeIdentifiers.fileURL,
                data: dataA,
                originalFilePath: pathA
            ),
            ParsedRepresentation(
                itemIndex: 1,
                typeIdentifier: ClipboardTypeIdentifiers.fileURL,
                data: dataB,
                originalFilePath: pathB
            )
        ]
        let parsed = ParsedPasteboardItem(
            representations: reps,
            primaryKind: .fileList,
            previewText: "2 files",
            searchText: "2 files",
            fingerprint: Fingerprinter.fingerprint(representations: reps),
            originalFilePaths: [pathA, pathB]
        )
        guard case .inserted(let entry) = engine.ingest(parsed: parsed) else {
            return XCTFail("insert")
        }

        let items = try engine.makeDraggingItems(for: entry)
        XCTAssertEqual(items.count, 2)
        XCTAssertNotNil(items[0].data(forType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.fileURL)))
        XCTAssertNotNil(items[1].data(forType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.fileURL)))
        XCTAssertEqual(other.string(forType: .string), "keep-me")
    }

    func testMakeItemsPreservesMultipleRepresentationsOnOneItem() throws {
        let store = InMemoryPayloadStore()
        let engine = ClipboardEngine(repository: InMemoryClipboardRepository(), payloadStore: store)
        let plain = Data("hello".utf8)
        let rtf = Data("{\\rtf1 hello}".utf8)
        let reps = [
            ParsedRepresentation(itemIndex: 0, typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText, data: plain),
            ParsedRepresentation(itemIndex: 0, typeIdentifier: ClipboardTypeIdentifiers.rtf, data: rtf)
        ]
        let parsed = ParsedPasteboardItem(
            representations: reps,
            primaryKind: .rtf,
            previewText: "hello",
            searchText: "hello",
            fingerprint: Fingerprinter.fingerprint(representations: reps)
        )
        guard case .inserted(let entry) = engine.ingest(parsed: parsed) else {
            return XCTFail("insert")
        }
        let items = try engine.makeDraggingItems(for: entry)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(
            items[0].data(forType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.utf8PlainText)),
            plain
        )
        XCTAssertEqual(
            items[0].data(forType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.rtf)),
            rtf
        )
    }
}

final class SelectionCopyPolicyTests: XCTestCase {
    func testDismissOnlyOnSuccessfulWrite() {
        XCTAssertTrue(SelectionCopyPolicy.shouldDismiss(written: 1, error: nil))
        XCTAssertFalse(SelectionCopyPolicy.shouldDismiss(written: 0, error: nil))
        XCTAssertFalse(SelectionCopyPolicy.shouldDismiss(written: 2, error: ClipboardRepositoryError.notFound))
    }
}

final class DragEndPolicyTests: XCTestCase {
    func testSuccessfulDropClosesWithoutRestore() {
        XCTAssertTrue(DragEndPolicy.shouldDismissAfterDrag(success: true))
        XCTAssertFalse(DragEndPolicy.shouldRestoreAfterDrag(success: true))
        XCTAssertFalse(DragEndPolicy.shouldDismissAfterDrag(success: false))
    }
}

final class QuickLookPolicyTests: XCTestCase {
    func testRoutes() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? Data("x".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileOK = ClipboardEntry(
            primaryKind: .fileList,
            previewText: "x",
            searchText: "x",
            fingerprint: "f1",
            payloadRefs: [
                PayloadReference(
                    typeIdentifier: ClipboardTypeIdentifiers.fileURL,
                    relativePath: "r",
                    byteCount: 1,
                    originalFilePath: tmp.path
                )
            ]
        )
        if case .fileURLs(let paths) = QuickLookPolicy.route(for: fileOK) {
            XCTAssertEqual(paths, [tmp.path])
        } else {
            XCTFail("expected fileURLs")
        }

        let missing = ClipboardEntry(
            primaryKind: .fileList,
            previewText: "m",
            searchText: "m",
            fingerprint: "f2",
            payloadRefs: [
                PayloadReference(
                    typeIdentifier: ClipboardTypeIdentifiers.fileURL,
                    relativePath: "r",
                    byteCount: 1,
                    originalFilePath: "/tmp/notchclip-missing-\(UUID().uuidString)"
                )
            ]
        )
        if case .missingFiles = QuickLookPolicy.route(for: missing) {
            // ok
        } else {
            XCTFail("expected missing")
        }

        let image = ClipboardEntry(
            primaryKind: .image,
            previewText: "Image",
            searchText: "image",
            fingerprint: "f3",
            payloadRefs: [
                PayloadReference(
                    typeIdentifier: ClipboardTypeIdentifiers.png,
                    relativePath: "p",
                    byteCount: 10
                )
            ]
        )
        XCTAssertEqual(QuickLookPolicy.route(for: image), .materializeRetainedImage)

        let text = ClipboardEntry(
            primaryKind: .plainText,
            previewText: "hi",
            searchText: "hi",
            fingerprint: "f4"
        )
        if case .unsupported = QuickLookPolicy.route(for: text) {
            // ok
        } else {
            XCTFail("expected unsupported")
        }
    }

    func testImageExtension() {
        XCTAssertEqual(QuickLookPolicy.imageFileExtension(forType: ClipboardTypeIdentifiers.png), "png")
        XCTAssertEqual(QuickLookPolicy.imageFileExtension(forType: ClipboardTypeIdentifiers.tiff), "tiff")
    }
}

final class TransitionTokenPolicyTests: XCTestCase {
    func testOpenAndCloseTokensInvalidatedIndependently() {
        var open: UInt64 = 1
        var close: UInt64 = 1
        XCTAssertTrue(TransitionTokenPolicy.shouldApplyOpenCompletion(token: 1, openGeneration: open))
        // Dismiss starts: bump open so old open completions die.
        open &+= 1
        XCTAssertFalse(TransitionTokenPolicy.shouldApplyOpenCompletion(token: 1, openGeneration: open))
        close &+= 1
        let closeToken = close
        // Reopen bumps close generation.
        close &+= 1
        XCTAssertFalse(TransitionTokenPolicy.shouldApplyCloseCompletion(token: closeToken, closeGeneration: close))
    }
}

final class SnapshotBudgetAndConsistencyTests: XCTestCase {
    func testTotalBudgetStopsIncludingFurtherRepresentations() {
        let pb = NSPasteboard(name: NSPasteboard.Name("budget-\(UUID().uuidString)"))
        let i0 = NSPasteboardItem()
        i0.setData(Data(repeating: 1, count: 50), forType: .string)
        let i1 = NSPasteboardItem()
        i1.setData(Data(repeating: 2, count: 50), forType: .string)
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([i0, i1]))

        let snap = PasteboardSnapshotter.snapshot(
            pasteboard: pb,
            source: SourceMetadata(),
            maxRepresentationBytes: 100,
            maxTotalRetainedBytes: 60
        )
        XCTAssertTrue(snap.isConsistent)
        XCTAssertLessThanOrEqual(snap.totalBytesRetained, 60)
        // First item included; second may be dropped due to budget.
        XCTAssertEqual(snap.items.count, 1)
    }

    func testInconsistentChangeCountIsFlagged() {
        // Pure structural: construct inconsistent snapshot manually.
        let snap = PasteboardSnapshot(
            changeCount: 9,
            boardTypes: [],
            items: [],
            source: SourceMetadata(),
            isConsistent: false,
            totalBytesRetained: 0
        )
        let engine = ClipboardEngine(
            repository: InMemoryClipboardRepository(),
            payloadStore: InMemoryPayloadStore()
        )
        let result = engine.ingest(snapshot: snap)
        XCTAssertEqual(result, .ignoredEmpty)
    }
}
