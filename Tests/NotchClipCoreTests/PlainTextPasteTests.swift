import AppKit
import XCTest
@testable import NotchClipCore

final class PlainTextPastePolicyTests: XCTestCase {
    private func entry(
        kind: ClipboardContentKind,
        types: [String],
        text: String = "clip"
    ) -> ClipboardEntry {
        ClipboardEntry(
            primaryKind: kind,
            previewText: text,
            searchText: text.lowercased(),
            fingerprint: text,
            payloadRefs: types.enumerated().map { index, type in
                PayloadReference(
                    typeIdentifier: type,
                    relativePath: "r\(index)",
                    byteCount: 1
                )
            }
        )
    }

    func testRichTextPrefersRetainedPlainStringOverRTFAndHTML() {
        let decision = PlainTextPastePolicy.decision(
            kind: .rtf,
            availableTypeIdentifiers: [
                ClipboardTypeIdentifiers.rtf,
                ClipboardTypeIdentifiers.html,
                ClipboardTypeIdentifiers.utf8PlainText
            ]
        )
        XCTAssertEqual(decision, .plainText(sourceTypeIdentifier: ClipboardTypeIdentifiers.utf8PlainText))
    }

    func testRTFWithoutPlainStringStillStripsToText() {
        let decision = PlainTextPastePolicy.decision(
            kind: .rtf,
            availableTypeIdentifiers: [ClipboardTypeIdentifiers.rtf]
        )
        XCTAssertEqual(decision, .plainText(sourceTypeIdentifier: ClipboardTypeIdentifiers.rtf))
    }

    func testURLPastesItsAbsoluteStringRatherThanTheAnchorMarkup() {
        let decision = PlainTextPastePolicy.decision(
            kind: .url,
            availableTypeIdentifiers: [
                ClipboardTypeIdentifiers.html,
                ClipboardTypeIdentifiers.url
            ]
        )
        XCTAssertEqual(decision, .plainText(sourceTypeIdentifier: ClipboardTypeIdentifiers.url))
    }

    func testImagesAndFileListsFallBackToNormalPaste() {
        XCTAssertEqual(
            PlainTextPastePolicy.decision(
                kind: .image,
                availableTypeIdentifiers: [
                    ClipboardTypeIdentifiers.png,
                    // Even a stray text flavor must not turn an image into text.
                    ClipboardTypeIdentifiers.utf8PlainText
                ]
            ),
            .fallbackToNormalPaste
        )
        XCTAssertEqual(
            PlainTextPastePolicy.decision(
                kind: .fileList,
                availableTypeIdentifiers: [ClipboardTypeIdentifiers.fileURL]
            ),
            .fallbackToNormalPaste
        )
    }

    func testTextKindWithNoTextualRepresentationFallsBack() {
        XCTAssertEqual(
            PlainTextPastePolicy.decision(
                kind: .other,
                availableTypeIdentifiers: ["com.example.opaque"]
            ),
            .fallbackToNormalPaste
        )
    }

    func testUnwritablePayloadRefsAreNotOfferedAsSources() {
        var candidate = entry(kind: .plainText, types: [ClipboardTypeIdentifiers.utf8PlainText])
        candidate.payloadRefs[0].relativePath = ""
        XCTAssertEqual(PlainTextPastePolicy.decision(for: candidate), .fallbackToNormalPaste)
    }

    func testDecisionForEntryUsesItsRetainedTypes() {
        let candidate = entry(
            kind: .html,
            types: [ClipboardTypeIdentifiers.html, ClipboardTypeIdentifiers.plainText]
        )
        XCTAssertEqual(
            PlainTextPastePolicy.decision(for: candidate),
            .plainText(sourceTypeIdentifier: ClipboardTypeIdentifiers.plainText)
        )
    }

    func testShiftInvertsThePreferenceRatherThanAddingToIt() {
        XCTAssertFalse(PlainTextPastePolicy.usesPlainText(alwaysPlainText: false, shiftHeld: false))
        XCTAssertTrue(PlainTextPastePolicy.usesPlainText(alwaysPlainText: false, shiftHeld: true))
        XCTAssertTrue(PlainTextPastePolicy.usesPlainText(alwaysPlainText: true, shiftHeld: false))
        XCTAssertFalse(PlainTextPastePolicy.usesPlainText(alwaysPlainText: true, shiftHeld: true))
    }

    func testHTMLDecodesWithoutMainThreadAttributedStringImport() {
        let html = Data("<p>hello <b>world</b></p>".utf8)
        let text = PlainTextPastePolicy.plainString(
            from: html,
            typeIdentifier: ClipboardTypeIdentifiers.html
        )
        XCTAssertEqual(text?.contains("hello"), true)
        XCTAssertEqual(text?.contains("world"), true)
        XCTAssertEqual(text?.contains("<b>"), false)
    }

    func testURLDataDecodesToItsAbsoluteString() {
        let data = Data("https://example.com/a?b=c".utf8)
        XCTAssertEqual(
            PlainTextPastePolicy.plainString(from: data, typeIdentifier: ClipboardTypeIdentifiers.url),
            "https://example.com/a?b=c"
        )
    }

    func testEmptyPayloadDecodesToNil() {
        XCTAssertNil(
            PlainTextPastePolicy.plainString(
                from: Data(),
                typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText
            )
        )
    }

    func testOutputWritesOnlyPlainTextFlavors() {
        XCTAssertEqual(
            PlainTextPastePolicy.outputTypeIdentifiers,
            [ClipboardTypeIdentifiers.utf8PlainText, ClipboardTypeIdentifiers.plainText]
        )
        XCTAssertFalse(PlainTextPastePolicy.outputTypeIdentifiers.contains(ClipboardTypeIdentifiers.rtf))
        XCTAssertFalse(PlainTextPastePolicy.outputTypeIdentifiers.contains(ClipboardTypeIdentifiers.html))
    }

    func testEnginePastePlainTextStripsFormattingOnARealPasteboard() throws {
        let store = InMemoryPayloadStore()
        let engine = ClipboardEngine(
            repository: InMemoryClipboardRepository(),
            payloadStore: store
        )
        let plain = Data("NOTCHCLIP PLAIN TEXT TEST".utf8)
        let parsed = ParsedPasteboardItem(
            representations: [
                ParsedRepresentation(
                    itemIndex: 0,
                    typeIdentifier: ClipboardTypeIdentifiers.rtf,
                    data: Data("{\\rtf1\\ansi\\b NOTCHCLIP PLAIN TEXT TEST}".utf8)
                ),
                ParsedRepresentation(
                    itemIndex: 0,
                    typeIdentifier: ClipboardTypeIdentifiers.utf8PlainText,
                    data: plain
                )
            ],
            primaryKind: .rtf,
            previewText: "NOTCHCLIP PLAIN TEXT TEST",
            searchText: "notchclip plain text test",
            fingerprint: "plain-text-integration"
        )
        guard case .inserted(let entry) = engine.ingest(parsed: parsed) else {
            return XCTFail("Expected the formatted test clip to be retained")
        }

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.anoop.notchclip.tests.plain.\(UUID().uuidString)")
        )
        pasteboard.clearContents()

        XCTAssertEqual(try engine.pastePlainText(entry: entry, pasteboard: pasteboard), 1)
        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertEqual(
            item.data(forType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.utf8PlainText)),
            plain
        )
        XCTAssertNil(item.data(forType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.rtf)))
        XCTAssertNil(item.data(forType: NSPasteboard.PasteboardType(ClipboardTypeIdentifiers.html)))
    }

    func testAlwaysPastePlainTextDefaultsOffAndPersists() {
        let name = "com.anoop.notchclip.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        XCTAssertFalse(AppPreferences.load(defaults: suite).alwaysPastePlainText)
        AppPreferences(alwaysPastePlainText: true).save(defaults: suite)
        XCTAssertTrue(AppPreferences.load(defaults: suite).alwaysPastePlainText)
    }
}

final class QuickPasteOrdinalTests: XCTestCase {
    private func entry(
        _ text: String,
        kind: ClipboardContentKind = .plainText,
        pinned: Bool = false,
        updatedAt: Date = .now
    ) -> ClipboardEntry {
        ClipboardEntry(
            updatedAt: updatedAt,
            isPinned: pinned,
            primaryKind: kind,
            previewText: text,
            searchText: text.lowercased(),
            fingerprint: text
        )
    }

    func testOrdinalCountsTopToBottomAcrossSections() {
        let pinned = entry("pinned one", pinned: true)
        let today = entry("today one")
        let earlier = entry("earlier one", updatedAt: Date(timeIntervalSinceReferenceDate: 0))
        let projection = ClipProjection.make(entries: [today, earlier, pinned], query: "", scope: .all)

        // The flattened section order is what the list draws, so it is what ⌘N counts.
        XCTAssertEqual(
            projection.sections.flatMap(\.entries).map(\.id),
            projection.visibleEntries.map(\.id)
        )
        XCTAssertEqual(projection.entry(atOrdinal: 1)?.id, pinned.id)
        XCTAssertEqual(projection.entry(atOrdinal: 2)?.id, today.id)
        XCTAssertEqual(projection.entry(atOrdinal: 3)?.id, earlier.id)
    }

    func testOrdinalRespectsActiveSearchAndScope() {
        let text = entry("swift notes")
        let link = entry("https://example.com", kind: .url)

        let filteredByScope = ClipProjection.make(entries: [text, link], query: "", scope: .links)
        XCTAssertEqual(filteredByScope.entry(atOrdinal: 1)?.id, link.id)
        XCTAssertNil(filteredByScope.entry(atOrdinal: 2))

        let filteredByQuery = ClipProjection.make(entries: [text, link], query: "swift", scope: .all)
        XCTAssertEqual(filteredByQuery.entry(atOrdinal: 1)?.id, text.id)
        XCTAssertNil(filteredByQuery.entry(atOrdinal: 2))
    }

    func testOrdinalRejectsZeroNegativeAndAboveNine() {
        let entries = (1...12).map { entry("row \($0)", updatedAt: Date(timeIntervalSinceReferenceDate: Double(1000 - $0))) }
        let projection = ClipProjection.make(entries: entries, query: "", scope: .all)

        XCTAssertEqual(projection.visibleEntries.count, 12)
        XCTAssertNil(projection.entry(atOrdinal: 0))
        XCTAssertNil(projection.entry(atOrdinal: -1))
        XCTAssertEqual(projection.entry(atOrdinal: 9)?.id, projection.visibleEntries[8].id)
        // A tenth row is visible but unreachable — ⌘10 is not a keystroke.
        XCTAssertNil(projection.entry(atOrdinal: 10))
    }

    func testOrdinalPastTheEndOfAShortListIsNil() {
        let projection = ClipProjection.make(entries: [entry("only")], query: "", scope: .all)
        XCTAssertEqual(projection.entry(atOrdinal: 1)?.previewText, "only")
        XCTAssertNil(projection.entry(atOrdinal: 2))
        XCTAssertNil(ClipProjection.empty.entry(atOrdinal: 1))
    }

    func testScopeShortcutsStillCoverSixFiltersAfterMovingToOption() {
        // ⌥1–⌥6 kept the same ordering; only the modifier changed.
        XCTAssertEqual(ClipScope.allCases.count, 6)
        XCTAssertEqual(ClipScope.scope(forShortcutNumber: 1), .all)
        XCTAssertEqual(ClipScope.scope(forShortcutNumber: 6), .files)
        XCTAssertNil(ClipScope.scope(forShortcutNumber: 7))
    }
}
