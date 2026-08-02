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

    func testExpandedPanelUsesCompactFootprintAtNotch() {
        let screen = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            topSafeInset: 32,
            notchWidth: 180
        )
        let expanded = PanelGeometry.expandedFrame(on: screen)
        XCTAssertEqual(expanded.width, PanelGeometry.expandedDefaultWidth, accuracy: 0.5)
        XCTAssertEqual(expanded.height, PanelGeometry.expandedDefaultHeight, accuracy: 0.5)
        // Deliberately compact: the panel must read as the notch opening,
        // not a window — cap the footprint it may claim on a large display.
        XCTAssertLessThanOrEqual(PanelGeometry.expandedDefaultWidth, 700)
        XCTAssertLessThanOrEqual(PanelGeometry.expandedDefaultHeight, 480)
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
        XCTAssertEqual(belowZero.progress, ShellProgress.zero)
        // Values above 1 are the open spring's overshoot and are allowed up to
        // each axis's own ceiling; the window carries headroom so they aren't
        // clipped.
        XCTAssertEqual(aboveOne.progress.x, PanelGeometry.maxShellProgressX)
        XCTAssertEqual(aboveOne.progress.y, PanelGeometry.maxShellProgressY)
        XCTAssertGreaterThan(PanelGeometry.maxShellProgressY, 1)

        // Overshoot must stay inside the headroom the window actually reserves.
        let overshot = PanelGeometry.shellLayout(
            in: rect,
            capWidth: 180,
            capHeight: 32,
            progress: PanelGeometry.maxShellProgress
        )
        XCTAssertGreaterThan(overshot.bodyRect.width, rect.width)
        XCTAssertLessThanOrEqual(
            (overshot.bodyRect.width - rect.width) / 2,
            PanelGeometry.overshootHeadroomX
        )
        XCTAssertLessThanOrEqual(
            rect.minY - overshot.bodyRect.minY,
            PanelGeometry.overshootHeadroomBottom
        )
    }

    /// Width and height ride separate springs, so they clamp separately. The
    /// width spring is all but critically damped and has nowhere near 6 % of
    /// swell in it; letting the width reach the height's ceiling would only
    /// allow a shape that reads as elastic, which was rejected.
    func testEachAxisClampsAtItsOwnOvershootCeiling() {
        let rect = CGRect(x: 0, y: 0, width: 620, height: 420)
        let capW: CGFloat = 180
        let capH: CGFloat = 32

        XCTAssertLessThan(PanelGeometry.maxShellProgressX, PanelGeometry.maxShellProgressY)
        XCTAssertGreaterThan(PanelGeometry.maxShellProgressX, 1)
        // The single-channel ceiling stays the height's, so existing callers
        // keep the same headroom budget.
        XCTAssertEqual(PanelGeometry.maxShellProgress, PanelGeometry.maxShellProgressY)

        let pinned = PanelGeometry.shellLayout(
            in: rect,
            capWidth: capW,
            capHeight: capH,
            progress: ShellProgress(x: 5, y: 5)
        )
        XCTAssertEqual(pinned.progress.x, PanelGeometry.maxShellProgressX)
        XCTAssertEqual(pinned.progress.y, PanelGeometry.maxShellProgressY)

        let growable = rect.width - capW
        XCTAssertEqual(
            pinned.bodyRect.width,
            capW + growable * PanelGeometry.maxShellProgressX,
            accuracy: 0.01
        )
        let availableHeight = rect.height - capH
        XCTAssertEqual(
            pinned.bodyRect.height,
            availableHeight * PanelGeometry.maxShellProgressY,
            accuracy: 0.01
        )

        // Both ceilings stay inside the transparent margin the window reserves.
        XCTAssertLessThanOrEqual(
            (pinned.bodyRect.width - rect.width) / 2,
            PanelGeometry.overshootHeadroomX
        )
        XCTAssertLessThanOrEqual(
            rect.minY - pinned.bodyRect.minY,
            PanelGeometry.overshootHeadroomBottom
        )

        // Negative values on one channel don't drag the other below zero.
        let mixed = PanelGeometry.shellLayout(
            in: rect,
            capWidth: capW,
            capHeight: capH,
            progress: ShellProgress(x: -3, y: 0.5)
        )
        XCTAssertEqual(mixed.bodyRect.width, capW, accuracy: 0.01)
        XCTAssertEqual(mixed.bodyRect.height, availableHeight * 0.5, accuracy: 0.01)
    }

    /// Width leads, height follows: each channel must move only its own axis,
    /// or the two springs would smear into each other and there would be no
    /// bloom to see.
    func testAxisChannelsAreIndependentAndEachIsLinear() {
        let rect = CGRect(x: 0, y: 0, width: 620, height: 420)
        let capW: CGFloat = 180
        let capH: CGFloat = 32
        func layout(_ x: CGFloat, _ y: CGFloat) -> PanelShellLayout {
            PanelGeometry.shellLayout(
                in: rect,
                capWidth: capW,
                capHeight: capH,
                progress: ShellProgress(x: x, y: y)
            )
        }

        let availableHeight = rect.height - capH
        let growableWidth = rect.width - capW

        // Sweeping one channel leaves the other axis untouched.
        for p in stride(from: CGFloat(0), through: 1, by: 0.125) {
            let widthOnly = layout(p, 0.3)
            XCTAssertEqual(widthOnly.bodyRect.width, capW + growableWidth * p, accuracy: 0.01)
            XCTAssertEqual(widthOnly.bodyRect.height, availableHeight * 0.3, accuracy: 0.01)

            let heightOnly = layout(0.3, p)
            XCTAssertEqual(heightOnly.bodyRect.width, capW + growableWidth * 0.3, accuracy: 0.01)
            XCTAssertEqual(heightOnly.bodyRect.height, availableHeight * p, accuracy: 0.01)
        }

        // Equal steps in either channel produce equal steps in its own axis —
        // strictly linear, so the springs remain the only motion curves.
        let quarter = layout(0.25, 0.25).bodyRect
        let half = layout(0.5, 0.5).bodyRect
        let threeQuarters = layout(0.75, 0.75).bodyRect
        XCTAssertEqual(half.width - quarter.width, threeQuarters.width - half.width, accuracy: 0.01)
        XCTAssertEqual(half.height - quarter.height, threeQuarters.height - half.height, accuracy: 0.01)

        // A width that has arrived while the height is still filling is the
        // whole point: the shape is wide and short, not diagonal.
        let blooming = layout(1, 0.4)
        XCTAssertEqual(blooming.bodyRect.width, rect.width, accuracy: 0.01)
        XCTAssertEqual(blooming.bodyRect.height, availableHeight * 0.4, accuracy: 0.01)
        XCTAssertEqual(blooming.bodyRect.midX, rect.midX, accuracy: 0.01)
        // Still hanging from the cap, whatever the two channels are doing.
        XCTAssertEqual(blooming.capRect.maxY, rect.maxY, accuracy: 0.001)
        XCTAssertEqual(blooming.bodyRect.maxY, rect.maxY - capH, accuracy: 0.001)

        // The single-CGFloat convenience is exactly both channels together.
        let uniform = PanelGeometry.shellLayout(
            in: rect,
            capWidth: capW,
            capHeight: capH,
            progress: 0.6
        )
        XCTAssertEqual(uniform.bodyRect, layout(0.6, 0.6).bodyRect)
    }

    func testWindowFrameReservesOvershootHeadroomWithoutMovingTheCap() {
        let screen = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            topSafeInset: 32,
            notchWidth: 180
        )
        let resting = PanelGeometry.expandedFrame(on: screen)
        let window = PanelGeometry.windowFrame(on: screen)

        // Headroom on the sides and below only — the top stays pinned to the notch.
        XCTAssertEqual(window.maxY, resting.maxY, accuracy: 0.5)
        XCTAssertEqual(window.midX, resting.midX, accuracy: 0.5)
        XCTAssertEqual(window.width - resting.width, PanelGeometry.overshootHeadroomX * 2, accuracy: 0.5)
        XCTAssertEqual(window.height - resting.height, PanelGeometry.overshootHeadroomBottom, accuracy: 0.5)

        // The resting rect maps back to the same size inside the window.
        let inner = PanelGeometry.restingRect(inWindowSized: window.size)
        XCTAssertEqual(inner.width, resting.width, accuracy: 0.5)
        XCTAssertEqual(inner.height, resting.height, accuracy: 0.5)
        XCTAssertEqual(inner.maxY, window.height, accuracy: 0.5)
    }

    /// The spring driving `shellProgress` must be the only motion curve.
    ///
    /// The geometry used to apply its own ease-outs on top, whose slope reached
    /// zero at p = 1 while the overshoot region above 1 passed through at slope
    /// 1 — a derivative discontinuity that made the shape stall and then lurch
    /// into the overshoot. Linear geometry is what keeps that seam smooth.
    func testShellGeometryIsLinearInProgressSoTheSpringIsTheOnlyCurve() {
        let rect = CGRect(x: 0, y: 0, width: 620, height: 236)
        let capW: CGFloat = 180
        let capH: CGFloat = 32
        func layout(_ p: CGFloat) -> PanelShellLayout {
            PanelGeometry.shellLayout(in: rect, capWidth: capW, capHeight: capH, progress: p)
        }

        let full = layout(1)
        let availableHeight = full.bodyRect.height
        let growableWidth = rect.width - capW

        for p in stride(from: CGFloat(0), through: 1, by: 0.125) {
            let l = layout(p)
            XCTAssertEqual(l.bodyRect.height, availableHeight * p, accuracy: 0.01)
            XCTAssertEqual(l.bodyRect.width, capW + growableWidth * p, accuracy: 0.01)
        }

        // Equal steps in progress produce equal steps in size — no front-loading.
        let quarter = layout(0.25).bodyRect
        let half = layout(0.5).bodyRect
        let threeQuarters = layout(0.75).bodyRect
        XCTAssertEqual(half.width - quarter.width, threeQuarters.width - half.width, accuracy: 0.01)
        XCTAssertEqual(half.height - quarter.height, threeQuarters.height - half.height, accuracy: 0.01)

        // Radii track the interpolated body and are never re-multiplied by progress.
        let midpoint = layout(0.5)
        XCTAssertEqual(midpoint.bodyCornerRadius, 24, accuracy: 0.5)
        XCTAssertEqual(midpoint.neckRadius, 18, accuracy: 0.5)
    }

    /// On a display with no notch there is no housing to grow out of, so the
    /// shell scales instead of inflating from a phantom cap — but it scales from
    /// its *top edge*, not its centre.
    ///
    /// The concentric 0.86 → 1 version this replaced moved the top edge down and
    /// then back up, so the panel read as floating in front of the display
    /// rather than hanging off the top of it. Pinning the top and adding a short
    /// downward settle tells the same story the notched version tells with real
    /// hardware.
    func testDetachedShellHangsFromTheTopEdgeAndSettlesDown() {
        let rect = CGRect(x: 0, y: 0, width: 620, height: 420)
        let settle = PanelGeometry.detachedSettleOffset
        func detached(_ p: CGFloat) -> PanelShellLayout {
            PanelGeometry.shellLayout(
                in: rect,
                capWidth: 180,
                capHeight: 32,
                progress: p,
                presentation: .detached
            )
        }

        let closed = detached(0)
        XCTAssertEqual(closed.capRect.width, 0, accuracy: 0.001)
        XCTAssertEqual(closed.neckRadius, 0, accuracy: 0.001)
        // Close enough to full size that it materializes rather than zooming.
        XCTAssertEqual(
            closed.bodyRect.width,
            rect.width * PanelGeometry.detachedMinimumScale,
            accuracy: 0.01
        )
        XCTAssertGreaterThanOrEqual(PanelGeometry.detachedMinimumScale, 0.94)
        // Starts above its resting top and slides down into place.
        XCTAssertEqual(closed.bodyRect.maxY, rect.maxY + settle, accuracy: 0.01)

        let open = detached(1)
        XCTAssertEqual(open.bodyRect, rect)
        XCTAssertEqual(open.shellRect, rect)

        // The top edge only ever moves by the settle, and only downward — it
        // never dips below the rest and comes back up.
        var previousTop = closed.bodyRect.maxY
        for p in stride(from: CGFloat(0), through: 1, by: 0.125) {
            let l = detached(p)
            XCTAssertEqual(l.bodyRect.midX, rect.midX, accuracy: 0.01)
            XCTAssertEqual(l.shellRect, l.bodyRect)
            XCTAssertEqual(l.bodyRect.maxY, rect.maxY + settle * (1 - p), accuracy: 0.01)
            XCTAssertLessThanOrEqual(l.bodyRect.maxY, previousTop + 0.001)
            XCTAssertGreaterThanOrEqual(l.bodyRect.maxY, rect.maxY - 0.001)
            previousTop = l.bodyRect.maxY
        }

        // Linear in both the scale and the settle, so the spring's overshoot
        // passes through without a kink here too.
        let quarter = detached(0.25)
        let half = detached(0.5)
        let threeQuarters = detached(0.75)
        XCTAssertEqual(
            half.bodyRect.width - quarter.bodyRect.width,
            threeQuarters.bodyRect.width - half.bodyRect.width,
            accuracy: 0.01
        )
        XCTAssertEqual(
            quarter.bodyRect.maxY - half.bodyRect.maxY,
            half.bodyRect.maxY - threeQuarters.bodyRect.maxY,
            accuracy: 0.01
        )
        XCTAssertGreaterThan(detached(PanelGeometry.maxShellProgress).bodyRect.width, rect.width)

        // Uniform scale, so the width channel is ignored: routing the two
        // channels through a mean would be nonlinear above the width ceiling,
        // where they clamp differently.
        let splitChannels = PanelGeometry.shellLayout(
            in: rect,
            capWidth: 180,
            capHeight: 32,
            progress: ShellProgress(x: 0.1, y: 0.5),
            presentation: .detached
        )
        XCTAssertEqual(splitChannels.bodyRect, detached(0.5).bodyRect)

        // Callers whose window reserves no room above the shell opt out of the
        // settle rather than having its first frames clipped.
        let noRoom = PanelGeometry.shellLayout(
            in: rect,
            capWidth: 180,
            capHeight: 32,
            progress: 0,
            presentation: .detached,
            detachedSettle: 0
        )
        XCTAssertEqual(noRoom.bodyRect.maxY, rect.maxY, accuracy: 0.01)
    }

    /// The settle needs somewhere to travel from, and only the notch-less path
    /// reserves it — the notched shell's top edge is pinned to real hardware and
    /// must never move.
    func testDetachedWindowReservesTopHeadroomAndNotchedDoesNot() {
        let external = ScreenMetrics(
            frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055),
            topSafeInset: 0
        )
        let builtIn = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            topSafeInset: 32,
            notchWidth: 180
        )

        XCTAssertEqual(PanelGeometry.topHeadroom(hasNotch: true), 0)
        XCTAssertEqual(
            PanelGeometry.topHeadroom(hasNotch: false),
            PanelGeometry.detachedTopHeadroom
        )
        // Enough room for the whole settle.
        XCTAssertGreaterThanOrEqual(
            PanelGeometry.detachedTopHeadroom,
            PanelGeometry.detachedSettleOffset
        )

        let notchedWindow = PanelGeometry.windowFrame(on: builtIn)
        let notchedResting = PanelGeometry.expandedFrame(on: builtIn)
        XCTAssertEqual(notchedWindow.maxY, notchedResting.maxY, accuracy: 0.5)

        let detachedWindow = PanelGeometry.windowFrame(on: external)
        let detachedResting = PanelGeometry.expandedFrame(on: external)
        XCTAssertEqual(
            detachedWindow.maxY - detachedResting.maxY,
            PanelGeometry.detachedTopHeadroom,
            accuracy: 0.5
        )
        // The headroom is transparent margin, not extra panel: the resting rect
        // inside it is still exactly the panel, so content placement and
        // hit-testing are unchanged.
        let inner = PanelGeometry.restingRect(
            inWindowSized: detachedWindow.size,
            topHeadroom: PanelGeometry.detachedTopHeadroom
        )
        XCTAssertEqual(inner.width, detachedResting.width, accuracy: 0.5)
        XCTAssertEqual(inner.height, detachedResting.height, accuracy: 0.5)
        XCTAssertEqual(
            inner.maxY,
            detachedWindow.height - PanelGeometry.detachedTopHeadroom,
            accuracy: 0.5
        )
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
    func testFactoryShortcutIdentityIsControlV() {
        XCTAssertEqual(NotchClipHotKey.key, "v")
        XCTAssertEqual(NotchClipHotKey.modifiers, [.control])
        XCTAssertEqual(NotchClipHotKey.displayName, "⌃V")
        XCTAssertEqual(NotchClipHotKey.accessibilityName, "Control-V")
        XCTAssertEqual(NotchClipHotKey.defaultBinding.keyCode, NotchClipHotKey.defaultKeyCode)
        XCTAssertEqual(NotchClipHotKey.defaultBinding.modifiers, NotchClipHotKey.modifiers)
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
        XCTAssertEqual(fake.registrationError, "That shortcut is in use by another app.")
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
