import Foundation
import CoreGraphics

/// Pure screen metrics used for panel placement (no AppKit types — unit-testable).
public struct ScreenMetrics: Equatable, Sendable {
    /// Full screen frame in global coordinates (may have negative origin).
    public var frame: CGRect
    /// Visible frame excluding menu bar / dock.
    public var visibleFrame: CGRect
    /// Top safe-area inset (notch / camera housing); 0 on non-notched displays.
    public var topSafeInset: CGFloat
    /// Optional measured notch width; when nil a default is derived.
    public var notchWidth: CGFloat?

    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        topSafeInset: CGFloat = 0,
        notchWidth: CGFloat? = nil
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.topSafeInset = topSafeInset
        self.notchWidth = notchWidth
    }

    public var hasNotch: Bool { topSafeInset > 0.5 }

    /// Screen for geometry: `true` when the mouse point lies within `frame`.
    public func contains(point: CGPoint) -> Bool {
        frame.contains(point)
    }
}

/// Interpolated shell measurements shared by AppKit rendering and pure geometry tests.
public struct PanelShellLayout: Equatable, Sendable {
    public var capRect: CGRect
    public var bodyRect: CGRect
    public var shellRect: CGRect
    public var neckRadius: CGFloat
    public var bodyCornerRadius: CGFloat
    public var progress: CGFloat

    public init(
        capRect: CGRect,
        bodyRect: CGRect,
        shellRect: CGRect,
        neckRadius: CGFloat,
        bodyCornerRadius: CGFloat,
        progress: CGFloat
    ) {
        self.capRect = capRect
        self.bodyRect = bodyRect
        self.shellRect = shellRect
        self.neckRadius = neckRadius
        self.bodyCornerRadius = bodyCornerRadius
        self.progress = progress
    }
}

/// Compact / expanded frames for the retained notch panel (top-center anchored).
public enum PanelGeometry {
    public static let compactDefaultWidth: CGFloat = 180
    public static let compactMinHeight: CGFloat = 28
    // The panel holds the entire searchable history: search header, sectioned
    // list, preview pane, and action footer. Deliberately compact — a 780x620
    // version was tried and read as a slab hanging off the notch; ~620x420
    // keeps it feeling like the notch opened, not like a window appeared.
    public static let expandedDefaultWidth: CGFloat = 620
    public static let expandedDefaultHeight: CGFloat = 420
    public static let expandedMinWidth: CGFloat = 560
    public static let expandedMaxWidth: CGFloat = 700
    public static let expandedMinHeight: CGFloat = 380
    public static let expandedMaxHeight: CGFloat = 480
    public static let edgePadding: CGFloat = 8
    public static let shoulderRadius: CGFloat = 28

    /// A single source of truth for the shell's compact-to-expanded geometry.
    /// The body grows down and out from the cap rather than appearing as a resized window.
    public static func shellLayout(
        in rect: CGRect,
        capWidth: CGFloat,
        capHeight: CGFloat,
        progress: CGFloat
    ) -> PanelShellLayout {
        let p = min(max(progress, 0), 1)
        let capW = min(max(1, capWidth), rect.width)
        let capH = min(max(capHeight, 12), max(12, rect.height * 0.42))
        let bodyTop = rect.maxY - capH
        let availableBodyHeight = max(0, bodyTop - rect.minY)
        // Dynamic-Island inflation: both dimensions are strong ease-outs, so the
        // shape balloons from the housing in every direction at once and then
        // settles. The earlier smoothstep vertical made width race ahead and
        // height lag, which read as a sheet unfurling *below* the notch instead
        // of the notch itself opening.
        let horizontalProgress = 1 - CGFloat(pow(Double(1 - p), 2.2))
        let verticalProgress = 1 - CGFloat(pow(Double(1 - p), 1.9))
        let bodyHeight = availableBodyHeight * verticalProgress
        let bodyWidth = capW + max(0, rect.width - capW) * horizontalProgress
        let bodyRect = CGRect(
            x: rect.midX - bodyWidth / 2,
            y: bodyTop - bodyHeight,
            width: bodyWidth,
            height: bodyHeight
        )
        let capRect = CGRect(
            x: rect.midX - capW / 2,
            y: bodyTop,
            width: capW,
            height: capH
        )
        let shellRect = CGRect(
            x: min(bodyRect.minX, capRect.minX),
            y: bodyRect.minY,
            width: max(bodyRect.maxX, capRect.maxX) - min(bodyRect.minX, capRect.minX),
            height: rect.maxY - bodyRect.minY
        )
        let horizontalRoom = max(0, (bodyWidth - capW) / 2)
        // bodyWidth/bodyHeight are already interpolated. Multiplying these
        // radii by progress again made their early motion effectively quadratic.
        let neck = min(18, horizontalRoom * 0.38, max(0, capH - 8))
        let corner = min(24, bodyWidth / 2, bodyHeight / 2)

        return PanelShellLayout(
            capRect: capRect,
            bodyRect: bodyRect,
            shellRect: shellRect,
            neckRadius: neck,
            bodyCornerRadius: corner,
            progress: p
        )
    }

    /// Infer notch/cap width from public auxiliary top areas (menu-bar free regions).
    /// `leftWidth`/`rightWidth` are the widths of `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`.
    public static func inferredNotchWidth(
        screenWidth: CGFloat,
        auxiliaryTopLeftWidth: CGFloat,
        auxiliaryTopRightWidth: CGFloat,
        fallback: CGFloat
    ) -> CGFloat {
        guard auxiliaryTopLeftWidth > 1 || auxiliaryTopRightWidth > 1 else {
            return fallback
        }
        let gap = screenWidth - auxiliaryTopLeftWidth - auxiliaryTopRightWidth
        // Clamp to a plausible camera-housing band.
        return min(max(gap, 100), min(220, screenWidth * 0.25))
    }

    /// Resolved compact cap width for metrics.
    public static func capWidth(on screen: ScreenMetrics) -> CGFloat {
        let maxWidth = max(40, screen.visibleFrame.width - edgePadding * 2)
        if screen.hasNotch {
            return min(
                maxWidth,
                screen.notchWidth ?? min(compactDefaultWidth, max(120, screen.frame.width * 0.14))
            )
        }
        return min(compactDefaultWidth, maxWidth)
    }

    /// Compact black shell: notch-sized on notched built-in, top-edge pill on external screens.
    public static func compactFrame(on screen: ScreenMetrics) -> CGRect {
        let visible = screen.visibleFrame
        let width = capWidth(on: screen)

        if screen.hasNotch {
            let height = max(compactMinHeight, screen.topSafeInset)
            // Attach to physical top of the screen (notch region), centered.
            let x = screen.frame.midX - width / 2
            let y = screen.frame.maxY - height
            return clamp(CGRect(x: x, y: y, width: width, height: height), to: screen, preferTop: true)
        }

        // External / non-notch: pill just below the menu bar (top of visible frame).
        let height = compactMinHeight
        let x = visible.midX - width / 2
        let y = visible.maxY - height - 2
        return clamp(CGRect(x: x, y: y, width: width, height: height), to: screen, preferTop: true)
    }

    /// Unit-testable outline for the notch shell inside an expanded window frame.
    /// Coordinates are local to `rect` (origin bottom-left, matching AppKit views).
    public static func shellOutlinePoints(
        in rect: CGRect,
        capWidth: CGFloat,
        capHeight: CGFloat,
        shoulder: CGFloat = shoulderRadius,
        progress: CGFloat = 1
    ) -> [CGPoint] {
        let layout = shellLayout(
            in: rect,
            capWidth: capWidth,
            capHeight: capHeight,
            progress: progress
        )
        let capLeft = layout.capRect.minX
        let capRight = layout.capRect.maxX
        let bodyTop = layout.bodyRect.maxY
        let bodyBottom = layout.bodyRect.minY
        let left = layout.bodyRect.minX
        let right = layout.bodyRect.maxX
        let radius = layout.bodyCornerRadius
        let s = min(shoulder, layout.neckRadius)

        // Key points mirror the renderer's localized neck and rounded body.
        return [
            CGPoint(x: left + radius, y: bodyBottom),
            CGPoint(x: right - radius, y: bodyBottom),
            CGPoint(x: right, y: bodyBottom + radius),
            CGPoint(x: right, y: bodyTop - radius),
            CGPoint(x: capRight + s, y: bodyTop),
            CGPoint(x: capRight, y: layout.capRect.maxY),
            CGPoint(x: capLeft, y: layout.capRect.maxY),
            CGPoint(x: capLeft - s, y: bodyTop),
            CGPoint(x: left, y: bodyTop - radius),
            CGPoint(x: left, y: bodyBottom + radius)
        ]
    }

    /// Compact horizontal clip shelf, grown down/out from the same top-center anchor.
    public static func expandedFrame(on screen: ScreenMetrics) -> CGRect {
        let visible = screen.visibleFrame
        let maxW = max(200, visible.width - edgePadding * 2)
        let maxH = max(200, visible.height - edgePadding * 2)

        var width = min(expandedMaxWidth, max(expandedMinWidth, expandedDefaultWidth))
        width = min(width, maxW)
        var height = min(expandedMaxHeight, max(expandedMinHeight, expandedDefaultHeight))
        height = min(height, maxH)

        let compact = compactFrame(on: screen)
        let topY = compact.maxY
        let x = compact.midX - width / 2
        let y = topY - height
        return clamp(CGRect(x: x, y: y, width: width, height: height), to: screen, preferTop: true)
    }

    /// Pick the screen metrics whose frame contains the mouse; fall back to first / primary.
    public static func screen(
        containing point: CGPoint,
        candidates: [ScreenMetrics],
        fallback: ScreenMetrics?
    ) -> ScreenMetrics? {
        if let hit = candidates.first(where: { $0.contains(point: point) }) {
            return hit
        }
        return fallback ?? candidates.first
    }

    /// Keeps the frame inside `visibleFrame` (and physical frame), preserving top-center when possible.
    public static func clamp(_ rect: CGRect, to screen: ScreenMetrics, preferTop: Bool) -> CGRect {
        let bounds = screen.visibleFrame.intersection(
            CGRect(
                x: screen.frame.minX,
                y: screen.frame.minY,
                width: screen.frame.width,
                height: screen.frame.height
            )
        )
        guard !bounds.isNull, bounds.width > 1, bounds.height > 1 else { return rect }

        var r = rect
        r.size.width = min(r.width, bounds.width - edgePadding)
        r.size.height = min(r.height, bounds.height - edgePadding)

        if r.maxX > bounds.maxX - edgePadding / 2 {
            r.origin.x = bounds.maxX - r.width - edgePadding / 2
        }
        if r.minX < bounds.minX + edgePadding / 2 {
            r.origin.x = bounds.minX + edgePadding / 2
        }
        if preferTop {
            if r.maxY > screen.frame.maxY {
                r.origin.y = screen.frame.maxY - r.height
            }
            if r.minY < bounds.minY + edgePadding / 2 {
                r.origin.y = bounds.minY + edgePadding / 2
            }
            // Re-assert top attachment when room allows.
            if r.height <= (screen.frame.maxY - bounds.minY) {
                let desiredTop = min(screen.frame.maxY, max(bounds.maxY, screen.frame.maxY))
                if screen.hasNotch {
                    r.origin.y = screen.frame.maxY - r.height
                } else {
                    r.origin.y = min(desiredTop, bounds.maxY) - r.height
                    if r.origin.y < bounds.minY {
                        r.origin.y = bounds.minY
                    }
                }
            }
        } else {
            if r.minY < bounds.minY {
                r.origin.y = bounds.minY
            }
            if r.maxY > bounds.maxY {
                r.origin.y = bounds.maxY - r.height
            }
        }
        return r
    }
}
