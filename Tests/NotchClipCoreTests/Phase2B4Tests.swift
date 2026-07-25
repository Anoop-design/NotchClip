import XCTest
@testable import NotchClipCore
import Foundation
import AppKit

// MARK: - Selection copy completion tokens

final class SelectionCopyCompletionPolicyTests: XCTestCase {
    func testApplyRequiresMatchingOperationAndPresentation() {
        XCTAssertTrue(
            SelectionCopyCompletionPolicy.shouldApplyCompletion(
                operationToken: 3,
                activeOperationToken: 3,
                capturedOpenGeneration: 10,
                currentOpenGeneration: 10,
                isPanelStillVisible: true
            )
        )
    }

    func testStalePresentationRejected() {
        // Panel A dismissed / B opened: open generation advanced.
        XCTAssertFalse(
            SelectionCopyCompletionPolicy.shouldApplyCompletion(
                operationToken: 1,
                activeOperationToken: 1,
                capturedOpenGeneration: 5,
                currentOpenGeneration: 6,
                isPanelStillVisible: true
            )
        )
    }

    func testStaleOperationRejected() {
        XCTAssertFalse(
            SelectionCopyCompletionPolicy.shouldApplyCompletion(
                operationToken: 1,
                activeOperationToken: 2,
                capturedOpenGeneration: 5,
                currentOpenGeneration: 5,
                isPanelStillVisible: true
            )
        )
    }

    func testHiddenPanelRejected() {
        XCTAssertFalse(
            SelectionCopyCompletionPolicy.shouldApplyCompletion(
                operationToken: 1,
                activeOperationToken: 1,
                capturedOpenGeneration: 5,
                currentOpenGeneration: 5,
                isPanelStillVisible: false
            )
        )
    }

    func testNilActiveOperationRejected() {
        XCTAssertFalse(
            SelectionCopyCompletionPolicy.shouldApplyCompletion(
                operationToken: 1,
                activeOperationToken: nil,
                capturedOpenGeneration: 5,
                currentOpenGeneration: 5,
                isPanelStillVisible: true
            )
        )
    }

    func testDuplicateStartGating() {
        XCTAssertTrue(SelectionCopyCompletionPolicy.shouldStartPaste(isPasteInFlight: false))
        XCTAssertFalse(SelectionCopyCompletionPolicy.shouldStartPaste(isPasteInFlight: true))
    }
}

// MARK: - Drag lifecycle visibility

final class DragLifecyclePolicyTests: XCTestCase {
    func testCancelWhileVisibleFinishesKey() {
        XCTAssertTrue(
            DragEndPolicy.shouldFinishKeyAfterCancel(isPanelVisible: true, phase: .expanded)
        )
        XCTAssertTrue(
            DragEndPolicy.shouldFinishKeyAfterCancel(isPanelVisible: true, phase: .compact)
        )
    }

    func testCancelAfterHiddenDoesNotFinishKey() {
        XCTAssertFalse(
            DragEndPolicy.shouldFinishKeyAfterCancel(isPanelVisible: false, phase: .hidden)
        )
        XCTAssertFalse(
            DragEndPolicy.shouldFinishKeyAfterCancel(isPanelVisible: false, phase: .expanded)
        )
        XCTAssertFalse(
            DragEndPolicy.shouldFinishKeyAfterCancel(isPanelVisible: true, phase: .collapsing)
        )
        XCTAssertFalse(
            DragEndPolicy.shouldFinishKeyAfterCancel(isPanelVisible: true, phase: .hidden)
        )
    }

    func testSuccessfulDragDismissOnlyWhenVisible() {
        XCTAssertTrue(DragEndPolicy.shouldDismissAfterSuccessfulDrag(isPanelVisible: true))
        XCTAssertFalse(DragEndPolicy.shouldDismissAfterSuccessfulDrag(isPanelVisible: false))
        XCTAssertTrue(DragEndPolicy.shouldDismissAfterDrag(success: true))
        XCTAssertFalse(DragEndPolicy.shouldDismissAfterDrag(success: false))
    }

    func testFinishKeyFocusNeverOnHiddenOrCollapsing() {
        XCTAssertTrue(FinishKeyFocusPolicy.shouldMakeKeyAndFocus(phase: .expanded, windowIsVisible: true))
        XCTAssertTrue(FinishKeyFocusPolicy.shouldMakeKeyAndFocus(phase: .compact, windowIsVisible: true))
        XCTAssertTrue(FinishKeyFocusPolicy.shouldMakeKeyAndFocus(phase: .expanding, windowIsVisible: true))
        XCTAssertFalse(FinishKeyFocusPolicy.shouldMakeKeyAndFocus(phase: .hidden, windowIsVisible: true))
        XCTAssertFalse(FinishKeyFocusPolicy.shouldMakeKeyAndFocus(phase: .collapsing, windowIsVisible: true))
        XCTAssertFalse(FinishKeyFocusPolicy.shouldMakeKeyAndFocus(phase: .expanded, windowIsVisible: false))
    }

    func testDragSuppressesCompetingDismissPaths() {
        XCTAssertTrue(
            DragInteractionPolicy.shouldSuppressDismissWhileDragging(isDragging: true, reason: .escape)
        )
        XCTAssertTrue(
            DragInteractionPolicy.shouldSuppressDismissWhileDragging(isDragging: true, reason: .hotkeyToggle)
        )
        XCTAssertTrue(
            DragInteractionPolicy.shouldSuppressDismissWhileDragging(isDragging: true, reason: .outsideClick)
        )
        XCTAssertTrue(
            DragInteractionPolicy.shouldSuppressDismissWhileDragging(isDragging: true, reason: .selection)
        )
        XCTAssertFalse(
            DragInteractionPolicy.shouldSuppressDismissWhileDragging(isDragging: true, reason: .dragCompleted)
        )
        XCTAssertFalse(
            DragInteractionPolicy.shouldSuppressDismissWhileDragging(isDragging: true, reason: .programmatic)
        )
        XCTAssertFalse(
            DragInteractionPolicy.shouldSuppressDismissWhileDragging(isDragging: false, reason: .escape)
        )
    }
}

// MARK: - Representation grouping / order

final class PasteboardItemGroupingTests: XCTestCase {
    func testGroupsByAscendingItemIndexPreservesWithinItemOrder() {
        let refs = [
            PayloadReference(itemIndex: 1, typeIdentifier: "b.custom", relativePath: "1/b", byteCount: 1),
            PayloadReference(itemIndex: 0, typeIdentifier: "z.last", relativePath: "0/z", byteCount: 1),
            PayloadReference(itemIndex: 0, typeIdentifier: "a.first", relativePath: "0/a", byteCount: 1),
            PayloadReference(itemIndex: 1, typeIdentifier: "a.plain", relativePath: "1/a", byteCount: 1)
        ]
        let groups = PasteboardItemGrouping.groupPayloadRefs(refs)
        XCTAssertEqual(groups.map(\.itemIndex), [0, 1])
        // Within item 0: order of appearance in input for that index, not UTI alphabetical.
        XCTAssertEqual(groups[0].refs.map(\.typeIdentifier), ["z.last", "a.first"])
        XCTAssertEqual(groups[1].refs.map(\.typeIdentifier), ["b.custom", "a.plain"])
    }

    func testSkipsEmptyRelativePaths() {
        let refs = [
            PayloadReference(itemIndex: 0, typeIdentifier: "t", relativePath: "", byteCount: 0),
            PayloadReference(itemIndex: 0, typeIdentifier: "u", relativePath: "ok", byteCount: 1)
        ]
        let groups = PasteboardItemGrouping.groupPayloadRefs(refs)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].refs.map(\.typeIdentifier), ["u"])
    }

    func testRepresentationGroupingPreservesOrder() {
        let reps = [
            ParsedRepresentation(itemIndex: 1, typeIdentifier: "public.rtf", data: Data("r".utf8)),
            ParsedRepresentation(itemIndex: 0, typeIdentifier: "public.html", data: Data("h".utf8)),
            ParsedRepresentation(itemIndex: 0, typeIdentifier: "public.utf8-plain-text", data: Data("p".utf8))
        ]
        let groups = PasteboardItemGrouping.groupRepresentations(reps)
        XCTAssertEqual(groups.map(\.itemIndex), [0, 1])
        XCTAssertEqual(
            groups[0].reps.map(\.typeIdentifier),
            ["public.html", "public.utf8-plain-text"]
        )
        XCTAssertEqual(groups[1].reps.map(\.typeIdentifier), ["public.rtf"])
    }
}

final class RepresentationOrderRegressionTests: XCTestCase {
    private func uniquePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("NotchClip.Phase2B4.\(UUID().uuidString)"))
    }

    /// Deliberately ordered rich/plain/custom set must come back in that order (not preferredOrder).
    func testParserRetainsSourceTypesOrderNotPreferredOrder() {
        let html = Data("<b>x</b>".utf8)
        let plain = Data("plain".utf8)
        let custom = Data("custom-bytes".utf8)
        let customType = "com.notchclip.test.custom"

        // preferredOrder would put html before plain before unknown custom.
        // Snapshot types are custom → plain → html on purpose.
        let snapItem = PasteboardItemSnapshot(
            types: [
                customType,
                ClipboardTypeIdentifiers.utf8PlainText,
                ClipboardTypeIdentifiers.html
            ],
            dataByType: [
                customType: custom,
                ClipboardTypeIdentifiers.utf8PlainText: plain,
                ClipboardTypeIdentifiers.html: html
            ]
        )
        let snap = PasteboardSnapshot(
            changeCount: 1,
            boardTypes: snapItem.types,
            items: [snapItem],
            source: SourceMetadata(),
            isConsistent: true,
            totalBytesRetained: custom.count + plain.count + html.count
        )

        let parser = PasteboardParser()
        guard let parsed = parser.parse(snapshot: snap) else {
            return XCTFail("parse")
        }

        XCTAssertEqual(
            parsed.representations.map(\.typeIdentifier),
            [customType, ClipboardTypeIdentifiers.utf8PlainText, ClipboardTypeIdentifiers.html]
        )
        XCTAssertEqual(parsed.representations.map(\.data), [custom, plain, html])
        XCTAssertTrue(parsed.representations.allSatisfy { $0.itemIndex == 0 })
    }

    func testParserPreservesMultiItemTopologyInSourceOrder() {
        let d0 = Data("first".utf8)
        let d1a = Data("second-a".utf8)
        let d1b = Data("second-b".utf8)
        let snap = PasteboardSnapshot(
            changeCount: 2,
            boardTypes: [ClipboardTypeIdentifiers.utf8PlainText, ClipboardTypeIdentifiers.rtf],
            items: [
                PasteboardItemSnapshot(
                    types: [ClipboardTypeIdentifiers.utf8PlainText],
                    dataByType: [ClipboardTypeIdentifiers.utf8PlainText: d0]
                ),
                PasteboardItemSnapshot(
                    types: [ClipboardTypeIdentifiers.rtf, ClipboardTypeIdentifiers.utf8PlainText],
                    dataByType: [
                        ClipboardTypeIdentifiers.rtf: d1a,
                        ClipboardTypeIdentifiers.utf8PlainText: d1b
                    ]
                )
            ],
            source: SourceMetadata(),
            isConsistent: true,
            totalBytesRetained: d0.count + d1a.count + d1b.count
        )
        let parser = PasteboardParser()
        guard let parsed = parser.parse(snapshot: snap) else {
            return XCTFail("parse")
        }
        XCTAssertEqual(parsed.representations.map(\.itemIndex), [0, 1, 1])
        XCTAssertEqual(
            parsed.representations.map(\.typeIdentifier),
            [
                ClipboardTypeIdentifiers.utf8PlainText,
                ClipboardTypeIdentifiers.rtf,
                ClipboardTypeIdentifiers.utf8PlainText
            ]
        )
    }

    func testWriterPreservesRepresentationOrderAndMultiItemTopology() throws {
        let store = InMemoryPayloadStore()
        let engine = ClipboardEngine(repository: InMemoryClipboardRepository(), payloadStore: store)

        // Deliberate non-alphabetical UTI order within items; two items.
        let customType = "com.example.z-custom"
        let reps = [
            ParsedRepresentation(
                itemIndex: 0,
                typeIdentifier: ClipboardTypeIdentifiers.html,
                data: Data("<i>hi</i>".utf8)
            ),
            ParsedRepresentation(
                itemIndex: 0,
                typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText,
                data: Data("hi".utf8)
            ),
            ParsedRepresentation(
                itemIndex: 0,
                typeIdentifier: customType,
                data: Data("meta".utf8)
            ),
            ParsedRepresentation(
                itemIndex: 1,
                typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText,
                data: Data("second".utf8)
            )
        ]
        let parsed = ParsedPasteboardItem(
            representations: reps,
            primaryKind: .html,
            previewText: "hi",
            searchText: "hi",
            fingerprint: Fingerprinter.fingerprint(representations: reps)
        )
        guard case .inserted(let entry) = engine.ingest(parsed: parsed) else {
            return XCTFail("insert")
        }

        // Payload refs should retain storeAll order from representations.
        let groups = PasteboardItemGrouping.groupPayloadRefs(entry.payloadRefs)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].itemIndex, 0)
        XCTAssertEqual(groups[1].itemIndex, 1)
        XCTAssertEqual(
            groups[0].refs.map(\.typeIdentifier),
            [ClipboardTypeIdentifiers.html, ClipboardTypeIdentifiers.utf8PlainText, customType]
        )

        let dest = uniquePasteboard()
        let written = try engine.paste(entry: entry, pasteboard: dest)
        XCTAssertEqual(written, 2)
        let items = dest.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2)

        // Item 0 carries all three flavors (order of declaration is best-effort via setData sequence).
        XCTAssertEqual(
            items[0].data(forType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.html)),
            Data("<i>hi</i>".utf8)
        )
        XCTAssertEqual(
            items[0].data(forType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.utf8PlainText)),
            Data("hi".utf8)
        )
        XCTAssertEqual(
            items[0].data(forType: NSPasteboard.PasteboardType(customType)),
            Data("meta".utf8)
        )
        XCTAssertEqual(
            items[1].data(forType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.utf8PlainText)),
            Data("second".utf8)
        )
    }

    func testWriterFromParsedRepresentationsDoesNotAlphaSortUTIs() {
        let custom = "com.z.custom"
        let reps = [
            ParsedRepresentation(itemIndex: 0, typeIdentifier: custom, data: Data("c".utf8)),
            ParsedRepresentation(
                itemIndex: 0,
                typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText,
                data: Data("p".utf8)
            )
        ]
        let pb = uniquePasteboard()
        let count = PasteboardWriter().write(representations: reps, pasteboard: pb)
        XCTAssertEqual(count, 1)
        let item = pb.pasteboardItems?.first
        XCTAssertEqual(item?.data(forType: NSPasteboard.PasteboardType(custom)), Data("c".utf8))
        XCTAssertEqual(
            item?.data(forType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.utf8PlainText)),
            Data("p".utf8)
        )
    }
}

// MARK: - Lazy drag providers

final class LazyDragPayloadTests: XCTestCase {
    func testMakeLazyDraggingItemsPerformsZeroPayloadLoadsUntilTypeRequested() throws {
        let store = InMemoryPayloadStore()
        let engine = ClipboardEngine(repository: InMemoryClipboardRepository(), payloadStore: store)
        let plain = Data("lazy-payload".utf8)
        let rtf = Data("{\\rtf1 lazy}".utf8)
        let reps = [
            ParsedRepresentation(
                itemIndex: 0,
                typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText,
                data: plain
            ),
            ParsedRepresentation(
                itemIndex: 0,
                typeIdentifier: ClipboardTypeIdentifiers.rtf,
                data: rtf
            ),
            ParsedRepresentation(
                itemIndex: 1,
                typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText,
                data: Data("item1".utf8)
            )
        ]
        let parsed = ParsedPasteboardItem(
            representations: reps,
            primaryKind: .rtf,
            previewText: "lazy",
            searchText: "lazy",
            fingerprint: Fingerprinter.fingerprint(representations: reps)
        )
        guard case .inserted(let entry) = engine.ingest(parsed: parsed) else {
            return XCTFail("insert")
        }

        store.resetLoadCount()
        let built = engine.makeLazyDraggingItems(for: entry)
        XCTAssertEqual(built.items.count, 2)
        XCTAssertEqual(built.providers.count, 2)
        // Constructing lazy items must not load retained bytes.
        XCTAssertEqual(store.loadCount, 0)

        // Request one flavor — only that ref loads.
        let type = NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.utf8PlainText)
        built.providers[0].pasteboard(nil, item: built.items[0], provideDataForType: type)
        XCTAssertEqual(store.loadCount, 1)
        XCTAssertEqual(built.items[0].data(forType: type), plain)

        // Second type on same item.
        let rtfType = NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.rtf)
        built.providers[0].pasteboard(nil, item: built.items[0], provideDataForType: rtfType)
        XCTAssertEqual(store.loadCount, 2)
        XCTAssertEqual(built.items[0].data(forType: rtfType), rtf)
    }

    func testLazyProviderLoadFailureOmitsFlavorWithoutCrashing() throws {
        let store = InMemoryPayloadStore()
        let engine = ClipboardEngine(repository: InMemoryClipboardRepository(), payloadStore: store)
        let good = Data("ok".utf8)
        let reps = [
            ParsedRepresentation(
                itemIndex: 0,
                typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText,
                data: good
            )
        ]
        let parsed = ParsedPasteboardItem(
            representations: reps,
            primaryKind: .plainText,
            previewText: "ok",
            searchText: "ok",
            fingerprint: Fingerprinter.fingerprint(representations: reps)
        )
        guard case .inserted(var entry) = engine.ingest(parsed: parsed) else {
            return XCTFail("insert")
        }
        // Inject a broken ref alongside the good one.
        entry.payloadRefs.append(
            PayloadReference(
                itemIndex: 0,
                typeIdentifier: "com.broken.type",
                relativePath: "does/not/exist",
                byteCount: 1
            )
        )

        let built = engine.makeLazyDraggingItems(for: entry)
        XCTAssertEqual(built.items.count, 1)
        let item = built.items[0]
        let provider = built.providers[0]

        // Failed flavor: omit only that type.
        provider.pasteboard(
            nil,
            item: item,
            provideDataForType: NSPasteboard.PasteboardType("com.broken.type")
        )
        XCTAssertNil(item.data(forType: NSPasteboard.PasteboardType("com.broken.type")))

        // Good flavor still works.
        provider.pasteboard(
            nil,
            item: item,
            provideDataForType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.utf8PlainText)
        )
        XCTAssertEqual(
            item.data(forType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.utf8PlainText)),
            good
        )
    }

    func testLazyItemsDoNotTouchGeneralPasteboard() throws {
        let general = NSPasteboard.general
        let marker = "notchclip-phase2b4-\(UUID().uuidString)"
        general.clearContents()
        general.setString(marker, forType: .string)

        let store = InMemoryPayloadStore()
        let engine = ClipboardEngine(repository: InMemoryClipboardRepository(), payloadStore: store)
        let reps = [
            ParsedRepresentation(
                itemIndex: 0,
                typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText,
                data: Data("drag".utf8)
            )
        ]
        let parsed = ParsedPasteboardItem(
            representations: reps,
            primaryKind: .plainText,
            previewText: "drag",
            searchText: "drag",
            fingerprint: Fingerprinter.fingerprint(representations: reps)
        )
        guard case .inserted(let entry) = engine.ingest(parsed: parsed) else {
            return XCTFail("insert")
        }

        let built = engine.makeLazyDraggingItems(for: entry)
        XCTAssertFalse(built.items.isEmpty)
        built.providers.first?.pasteboard(
            nil,
            item: built.items[0],
            provideDataForType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.utf8PlainText)
        )

        XCTAssertEqual(general.string(forType: .string), marker)
    }

    func testExactRefLoadSeam() throws {
        let store = InMemoryPayloadStore()
        let engine = ClipboardEngine(repository: InMemoryClipboardRepository(), payloadStore: store)
        let data = Data("exact".utf8)
        let reps = [
            ParsedRepresentation(
                itemIndex: 0,
                typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText,
                data: data
            )
        ]
        guard case .inserted(let entry) = engine.ingest(parsed: ParsedPasteboardItem(
            representations: reps,
            primaryKind: .plainText,
            previewText: "exact",
            searchText: "exact",
            fingerprint: Fingerprinter.fingerprint(representations: reps)
        )) else {
            return XCTFail("insert")
        }
        let ref = try XCTUnwrap(entry.payloadRefs.first)
        store.resetLoadCount()
        let loaded = try engine.loadPayloadData(for: ref)
        XCTAssertEqual(loaded, data)
        XCTAssertEqual(store.loadCount, 1)
    }
}
