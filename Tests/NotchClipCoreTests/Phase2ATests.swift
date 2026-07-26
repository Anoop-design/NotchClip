import XCTest
@testable import NotchClipCore
import Foundation
import AppKit

final class PanelGeometryTests: XCTestCase {
    func testNotchedInternalScreenCompactAttachesToTop() {
        // Built-in notched display (global coords).
        let screen = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            topSafeInset: 32,
            notchWidth: 180
        )
        let compact = PanelGeometry.compactFrame(on: screen)
        XCTAssertEqual(compact.width, 180, accuracy: 0.5)
        XCTAssertEqual(compact.height, 32, accuracy: 0.5)
        XCTAssertEqual(compact.maxY, screen.frame.maxY, accuracy: 0.5)
        XCTAssertEqual(compact.midX, screen.frame.midX, accuracy: 1.0)
    }

    func testExternalScreenUsesTopEdgePill() {
        let screen = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
            topSafeInset: 0
        )
        XCTAssertFalse(screen.hasNotch)
        let compact = PanelGeometry.compactFrame(on: screen)
        XCTAssertLessThanOrEqual(compact.maxY, screen.visibleFrame.maxY + 0.5)
        XCTAssertGreaterThan(compact.minY, screen.visibleFrame.midY)
        XCTAssertEqual(compact.midX, screen.visibleFrame.midX, accuracy: 1.0)
    }

    func testSmallDisplayClampsExpanded() {
        let screen = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 800, height: 500),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 470),
            topSafeInset: 0
        )
        let expanded = PanelGeometry.expandedFrame(on: screen)
        XCTAssertLessThanOrEqual(expanded.width, screen.visibleFrame.width)
        XCTAssertLessThanOrEqual(expanded.height, screen.visibleFrame.height)
        XCTAssertGreaterThanOrEqual(expanded.minX, screen.visibleFrame.minX - 0.5)
        XCTAssertLessThanOrEqual(expanded.maxX, screen.visibleFrame.maxX + 0.5)
    }

    func testExpandedShelfUsesCompactIslandFootprint() {
        let screen = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            topSafeInset: 32,
            notchWidth: 180
        )
        let expanded = PanelGeometry.expandedFrame(on: screen)
        XCTAssertEqual(expanded.width, 660, accuracy: 0.5)
        XCTAssertEqual(expanded.height, 236, accuracy: 0.5)
        XCTAssertEqual(expanded.maxY, screen.frame.maxY, accuracy: 0.5)
    }

    func testShellLayoutMorphsFromCapIntoLocalizedBody() {
        let rect = CGRect(x: 0, y: 0, width: 596, height: 326)
        let compact = PanelGeometry.shellLayout(
            in: rect,
            capWidth: 180,
            capHeight: 32,
            progress: 0
        )
        XCTAssertEqual(compact.shellRect, compact.capRect)
        XCTAssertEqual(compact.bodyRect.height, 0, accuracy: 0.001)
        XCTAssertEqual(compact.neckRadius, 0, accuracy: 0.001)

        let expanded = PanelGeometry.shellLayout(
            in: rect,
            capWidth: 180,
            capHeight: 32,
            progress: 1
        )
        XCTAssertEqual(expanded.shellRect, rect)
        XCTAssertEqual(expanded.bodyRect.width, rect.width, accuracy: 0.001)
        XCTAssertEqual(expanded.bodyRect.maxY, rect.maxY - 32, accuracy: 0.001)
        XCTAssertGreaterThan(expanded.neckRadius, 0)
        XCTAssertLessThanOrEqual(expanded.neckRadius, 22)
        XCTAssertGreaterThan(expanded.bodyCornerRadius, 20)
    }

    func testShellLayoutProgressIsContinuousAndClamped() {
        let rect = CGRect(x: 0, y: 0, width: 596, height: 326)
        let layouts = [0.0, 0.25, 0.5, 0.75, 1.0].map {
            PanelGeometry.shellLayout(
                in: rect,
                capWidth: 180,
                capHeight: 32,
                progress: $0
            )
        }

        for (previous, current) in zip(layouts, layouts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(current.bodyRect.width, previous.bodyRect.width)
            XCTAssertGreaterThanOrEqual(current.bodyRect.height, previous.bodyRect.height)
            XCTAssertGreaterThanOrEqual(current.neckRadius, previous.neckRadius)
            XCTAssertGreaterThanOrEqual(current.bodyCornerRadius, previous.bodyCornerRadius)
            XCTAssertEqual(current.capRect.maxY, rect.maxY, accuracy: 0.001)
            XCTAssertTrue(rect.contains(current.shellRect) || current.shellRect == rect)
        }

        let belowZero = PanelGeometry.shellLayout(
            in: rect,
            capWidth: 180,
            capHeight: 32,
            progress: -1
        )
        let aboveOne = PanelGeometry.shellLayout(
            in: rect,
            capWidth: 180,
            capHeight: 32,
            progress: 2
        )
        XCTAssertEqual(belowZero.progress, 0)
        XCTAssertEqual(aboveOne.progress, 1)
    }

    func testShellRadiiFollowInterpolatedBodyWithoutDoubleEasing() {
        let rect = CGRect(x: 0, y: 0, width: 620, height: 236)
        let midpoint = PanelGeometry.shellLayout(
            in: rect,
            capWidth: 180,
            capHeight: 32,
            progress: 0.5
        )

        XCTAssertEqual(midpoint.bodyCornerRadius, 24, accuracy: 0.5)
        XCTAssertEqual(midpoint.neckRadius, 18, accuracy: 0.5)
        XCTAssertGreaterThan(midpoint.bodyRect.height, 90)
        XCTAssertGreaterThan(midpoint.bodyRect.width, 500)
    }

    func testNegativeOriginScreen() {
        // Secondary display to the left of primary.
        let screen = ScreenMetrics(
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055),
            topSafeInset: 0
        )
        let compact = PanelGeometry.compactFrame(on: screen)
        XCTAssertGreaterThanOrEqual(compact.minX, screen.frame.minX - 0.5)
        XCTAssertLessThanOrEqual(compact.maxX, screen.frame.maxX + 0.5)
        XCTAssertEqual(compact.midX, screen.frame.midX, accuracy: 2.0)

        let expanded = PanelGeometry.expandedFrame(on: screen)
        XCTAssertGreaterThanOrEqual(expanded.minX, screen.visibleFrame.minX - 1)
        XCTAssertEqual(expanded.midX, compact.midX, accuracy: 2.0)
    }

    func testScreenSelectionByMouse() {
        let left = ScreenMetrics(
            frame: CGRect(x: -1000, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: -1000, y: 0, width: 1000, height: 780)
        )
        let right = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 880)
        )
        let hit = PanelGeometry.screen(
            containing: CGPoint(x: -100, y: 400),
            candidates: [left, right],
            fallback: right
        )
        XCTAssertEqual(hit, left)
    }
}

final class DismissPolicyTests: XCTestCase {
    func testRestoreAppPolicy() {
        XCTAssertTrue(DismissPolicy.shouldRestorePreviousApp(.selection))
        XCTAssertTrue(DismissPolicy.shouldRestorePreviousApp(.escape))
        XCTAssertTrue(DismissPolicy.shouldRestorePreviousApp(.hotkeyToggle))
        XCTAssertFalse(DismissPolicy.shouldRestorePreviousApp(.outsideClick))
        XCTAssertFalse(DismissPolicy.shouldRestorePreviousApp(.dragCompleted))
        XCTAssertFalse(DismissPolicy.shouldRestorePreviousApp(.openLibrary))
    }

    func testDraggingSuppressesOutside() {
        XCTAssertTrue(DismissPolicy.shouldSuppressOutsideDismiss(isDragging: true))
        XCTAssertFalse(DismissPolicy.shouldSuppressOutsideDismiss(isDragging: false))
    }

    func testEscapeOnlyWhenKey() {
        XCTAssertTrue(DismissPolicy.shouldConsumeEscape(panelIsKey: true))
        XCTAssertFalse(DismissPolicy.shouldConsumeEscape(panelIsKey: false))
    }

    func testRapidToggleStaleCompletion() {
        var gen = PresentationGeneration()
        let first = gen.beginPresentation()
        XCTAssertFalse(DismissPolicy.isStaleCompletion(token: first, current: gen))
        let second = gen.beginPresentation()
        XCTAssertTrue(DismissPolicy.isStaleCompletion(token: first, current: gen))
        XCTAssertFalse(DismissPolicy.isStaleCompletion(token: second, current: gen))
        XCTAssertFalse(DismissPolicy.shouldOrderOut(token: first, current: gen, isVisible: true))
        XCTAssertTrue(DismissPolicy.shouldOrderOut(token: second, current: gen, isVisible: true))
    }
}

final class HotKeySeamTests: XCTestCase {
    func testDefaultShortcutIdentityIsControlVOnly() {
        XCTAssertEqual(NotchClipHotKey.key, "v")
        XCTAssertEqual(NotchClipHotKey.modifiers, [.control])
        XCTAssertEqual(NotchClipHotKey.displayName, "⌃V")
        XCTAssertEqual(NotchClipHotKey.accessibilityName, "Control-V")
    }

    func testFakeRegisterUnregisterAndToggle() {
        let fake = FakeHotKeyRegistrar()
        var toggles = 0
        fake.onToggle = { toggles += 1 }
        XCTAssertTrue(fake.register())
        XCTAssertTrue(fake.isRegistered)
        XCTAssertNil(fake.registrationError)
        fake.simulateKeyDown()
        fake.simulateKeyDown()
        XCTAssertEqual(toggles, 2)
        fake.unregister()
        XCTAssertFalse(fake.isRegistered)
        fake.simulateKeyDown()
        XCTAssertEqual(toggles, 2)
        XCTAssertEqual(fake.unregisterCallCount, 1)
    }

    func testFakeRegistrationFailureSurfaced() {
        let fake = FakeHotKeyRegistrar()
        fake.shouldFailRegistration = true
        XCTAssertFalse(fake.register())
        XCTAssertFalse(fake.isRegistered)
        XCTAssertEqual(
            fake.registrationError,
            "Hotkey Control–V is already in use by another application."
        )
    }
}

/// ClipProjection replaced HistoryQuery when the two surfaces merged into one
/// panel. These carry over the original filtering / navigation coverage and add
/// the scope filter the sidebar used to provide.
final class ClipProjectionTests: XCTestCase {
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

    func testFilteringAndPinnedSections() {
        let pinned = entry("Pinned Swift", pinned: true)
        let recent = entry("Recent notes")
        let other = entry("https://example.com", kind: .url)

        let projection = ClipProjection.make(
            entries: [recent, other, pinned],
            query: "swift",
            scope: .all
        )

        XCTAssertEqual(projection.visibleEntries.map(\.id), [pinned.id])
        XCTAssertEqual(projection.sections.map(\.title), ["Pinned"])
        XCTAssertTrue(projection.contains(id: pinned.id))
        XCTAssertFalse(projection.contains(id: recent.id))
    }

    func testScopeNarrowsToOneKind() {
        let text = entry("plain note")
        let link = entry("https://example.com", kind: .url)

        let links = ClipProjection.make(entries: [text, link], query: "", scope: .links)
        XCTAssertEqual(links.visibleEntries.map(\.id), [link.id])

        let all = ClipProjection.make(entries: [text, link], query: "", scope: .all)
        XCTAssertEqual(all.visibleEntries.count, 2)
    }

    func testScopeShortcutNumbersRoundTrip() {
        for scope in ClipScope.allCases {
            XCTAssertEqual(ClipScope.scope(forShortcutNumber: scope.shortcutNumber), scope)
        }
        XCTAssertNil(ClipScope.scope(forShortcutNumber: 0))
        XCTAssertNil(ClipScope.scope(forShortcutNumber: ClipScope.allCases.count + 1))
    }

    func testSelectionNavigationClampsAtBothEnds() {
        let newer = entry("a", updatedAt: Date(timeIntervalSinceReferenceDate: 200))
        let older = entry("b", updatedAt: Date(timeIntervalSinceReferenceDate: 100))
        let projection = ClipProjection.make(entries: [older, newer], query: "", scope: .all)

        // Recency ordering puts the newer entry first.
        XCTAssertEqual(projection.visibleEntries.map(\.id), [newer.id, older.id])

        XCTAssertEqual(projection.moveSelection(from: nil, delta: 1), newer.id)
        XCTAssertEqual(projection.moveSelection(from: newer.id, delta: 1), older.id)
        XCTAssertEqual(projection.moveSelection(from: older.id, delta: 1), older.id)
        XCTAssertEqual(projection.moveSelection(from: newer.id, delta: -1), newer.id)
        // A page-sized jump past the end clamps rather than wrapping.
        XCTAssertEqual(projection.moveSelection(from: newer.id, delta: 8), older.id)
    }

    func testEmptyProjectionHasNoSelection() {
        let projection = ClipProjection.make(entries: [], query: "", scope: .all)
        XCTAssertTrue(projection.visibleEntries.isEmpty)
        XCTAssertTrue(projection.sections.isEmpty)
        XCTAssertNil(projection.moveSelection(from: nil, delta: 1))
    }
}

final class AnimationPlannerTests: XCTestCase {
    func testReduceMotionIsFadeOnly() {
        let plan = AnimationPlanner.plan(reduceMotion: true, reduceTransparency: false)
        XCTAssertFalse(plan.allowsGeometryAnimation)
        XCTAssertFalse(plan.contentScaleEnabled)
        XCTAssertLessThan(plan.openDuration, 0.2)
        XCTAssertLessThan(plan.closeDuration, 0.2)
        XCTAssertEqual(MotionPolicy.behavior(reduceMotion: true), .fadeOnly)
    }

    func testFullMotionAllowsGeometry() {
        let plan = AnimationPlanner.plan(reduceMotion: false, reduceTransparency: false)
        XCTAssertTrue(plan.allowsGeometryAnimation)
        XCTAssertFalse(plan.contentScaleEnabled)
        XCTAssertGreaterThanOrEqual(plan.openDuration, 0.30)
        XCTAssertLessThanOrEqual(plan.openDuration, 0.38)
        XCTAssertGreaterThanOrEqual(plan.closeDuration, 0.22)
        XCTAssertLessThanOrEqual(plan.closeDuration, plan.openDuration)
    }

    func testReduceTransparencyPrefersOpaque() {
        let plan = AnimationPlanner.plan(reduceMotion: false, reduceTransparency: true)
        XCTAssertTrue(plan.preferOpaqueChrome)
    }
}

final class PanelPhasePolicyTests: XCTestCase {
    func testTogglePhaseMatrix() {
        XCTAssertEqual(PanelPhasePolicy.toggleAction(for: .hidden), .show)
        XCTAssertEqual(PanelPhasePolicy.toggleAction(for: .compact), .dismiss)
        XCTAssertEqual(PanelPhasePolicy.toggleAction(for: .expanding), .dismiss)
        XCTAssertEqual(PanelPhasePolicy.toggleAction(for: .expanded), .dismiss)
        XCTAssertEqual(PanelPhasePolicy.toggleAction(for: .collapsing), .reopen)
    }

    func testCollapsingReopenDoesNotOrderOutNewGeneration() {
        var gen = PresentationGeneration()
        let collapsingToken = gen.beginPresentation()
        // Simulate rapid re-show: new generation while old close still completing.
        let reopenToken = gen.beginPresentation()
        XCTAssertTrue(DismissPolicy.isStaleCompletion(token: collapsingToken, current: gen))
        XCTAssertFalse(DismissPolicy.shouldOrderOut(token: collapsingToken, current: gen, isVisible: true))
        XCTAssertTrue(DismissPolicy.shouldOrderOut(token: reopenToken, current: gen, isVisible: true))
    }
}

final class CaptureCoalescingTests: XCTestCase {
    func testDoesNotStartWhileInFlight() {
        XCTAssertFalse(
            CaptureCoalescing.shouldStartCapture(
                changeCount: 5,
                lastProcessed: 4,
                isPaused: false,
                isInFlight: true
            )
        )
    }

    func testStartsWhenBoardAdvancedAndIdle() {
        XCTAssertTrue(
            CaptureCoalescing.shouldStartCapture(
                changeCount: 5,
                lastProcessed: 4,
                isPaused: false,
                isInFlight: false
            )
        )
    }

    func testPendingWhenBoardMovesDuringFlight() {
        let pending = CaptureCoalescing.pendingAfterObservation(
            changeCount: 9,
            inFlightTarget: 7,
            isInFlight: true
        )
        XCTAssertEqual(pending, 9)
        XCTAssertNil(
            CaptureCoalescing.pendingAfterObservation(
                changeCount: 7,
                inFlightTarget: 7,
                isInFlight: true
            )
        )
    }

    func testRecaptureWhenPendingDiffers() {
        XCTAssertTrue(CaptureCoalescing.shouldRecapture(pending: 10, completedTarget: 8))
        XCTAssertFalse(CaptureCoalescing.shouldRecapture(pending: 8, completedTarget: 8))
        XCTAssertFalse(CaptureCoalescing.shouldRecapture(pending: nil, completedTarget: 8))
    }
}

final class NotchWidthInferenceTests: XCTestCase {
    func testInferredFromAuxiliaryTopAreas() {
        // 1512-wide screen with left/right menu areas leaving ~180pt center gap.
        let width = PanelGeometry.inferredNotchWidth(
            screenWidth: 1512,
            auxiliaryTopLeftWidth: 666,
            auxiliaryTopRightWidth: 666,
            fallback: 140
        )
        XCTAssertEqual(width, 180, accuracy: 1)
    }

    func testFallbackWhenAuxiliaryMissing() {
        let width = PanelGeometry.inferredNotchWidth(
            screenWidth: 1512,
            auxiliaryTopLeftWidth: 0,
            auxiliaryTopRightWidth: 0,
            fallback: 155
        )
        XCTAssertEqual(width, 155, accuracy: 0.5)
    }
}

final class RestoreOncePolicyTests: XCTestCase {
    func testRestoreOnlyOncePerPresentation() {
        XCTAssertTrue(DismissPolicy.shouldPerformRestore(reason: .selection, alreadyRestored: false))
        XCTAssertFalse(DismissPolicy.shouldPerformRestore(reason: .selection, alreadyRestored: true))
        XCTAssertFalse(DismissPolicy.shouldPerformRestore(reason: .outsideClick, alreadyRestored: false))
    }
}

final class FocusRequestTokenTests: XCTestCase {
    /// Pure stand-in for `PanelVisualState.focusRequestID` increments.
    func testFocusRequestIncrementsMonotonically() {
        var token: UInt64 = 0
        token &+= 1
        let first = token
        token &+= 1
        let second = token
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertNotEqual(first, second)
    }
}

final class PasteboardSnapshotStabilityTests: XCTestCase {
    func testSnapshotRemainsStableAfterSourcePasteboardMutates() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("NotchClipSnap.\(UUID().uuidString)"))
        let type = ClipboardTypeIdentifiers.utf8PlainText
        let original = Data("snapshot-stable-payload".utf8)
        let item = NSPasteboardItem()
        item.setData(original, forType: NSPasteboard.PasteboardType(type))
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([item]))

        let source = SourceMetadata(bundleIdentifier: "com.example.Snap", applicationName: "Snap")
        let snap = PasteboardSnapshotter.snapshot(
            pasteboard: pb,
            source: source,
            maxRepresentationBytes: 64 * 1024 * 1024
        )
        XCTAssertEqual(snap.items.count, 1)
        XCTAssertEqual(snap.items[0].dataByType[type], original)
        XCTAssertEqual(snap.source, source)

        // Mutate the live board after snapshotting.
        pb.clearContents()
        let item2 = NSPasteboardItem()
        item2.setData(Data("mutated-away".utf8), forType: NSPasteboard.PasteboardType(type))
        XCTAssertTrue(pb.writeObjects([item2]))

        // Snapshot must still parse the original content.
        let parser = PasteboardParser()
        guard let parsed = parser.parse(snapshot: snap) else {
            return XCTFail("parse snapshot")
        }
        XCTAssertEqual(parsed.representations.first?.data, original)
        XCTAssertEqual(parsed.source, source)

        let engine = ClipboardEngine(
            repository: InMemoryClipboardRepository(),
            payloadStore: InMemoryPayloadStore(),
            sourceProvider: { SourceMetadata() }
        )
        guard case .inserted(let entry) = engine.ingest(snapshot: snap) else {
            return XCTFail("ingest snapshot")
        }
        XCTAssertEqual(entry.previewText.contains("snapshot-stable") || entry.searchText.contains("snapshot-stable"), true)
    }

    func testPlainTextFromHTMLIsBackgroundSafe() {
        let html = Data("<p>Hello&nbsp;<b>World</b></p>".utf8)
        let plain = PasteboardParser.plainTextFromHTML(html)
        XCTAssertEqual(plain, "Hello World")
    }
}
