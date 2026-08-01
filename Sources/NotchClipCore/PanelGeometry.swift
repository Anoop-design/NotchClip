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

    /// Ceiling for `shellProgress`. Values above 1 are the spring's overshoot —
    /// the shape briefly swells past its resting size before settling, which is
    /// what makes the Dynamic Island read as physical rather than eased.
    public static let maxShellProgress: CGFloat = 1.06
    /// Transparent margin the window carries beyond the resting shell so that
    /// overshoot has somewhere to go instead of being clipped at the frame.
    public static let overshootHeadroomX: CGFloat = 16
    public static let overshootHeadroomBottom: CGFloat = 26

    /// The window's frame: the resting panel plus overshoot headroom on the
    /// sides and bottom. The top stays pinned to the physical notch.
    public static func windowFrame(on screen: ScreenMetrics) -> CGRect {
        let resting = expandedFrame(on: screen)
        return CGRect(
            x: resting.minX - overshootHeadroomX,
            y: resting.minY - overshootHeadroomBottom,
            width: resting.width + overshootHeadroomX * 2,
            height: resting.height + overshootHeadroomBottom
        )
    }

    /// The resting shell rect inside a window frame that includes headroom.
    public static func restingRect(inWindowSized size: CGSize) -> CGRect {
        CGRect(
            x: overshootHeadroomX,
            y: overshootHeadroomBottom,
            width: max(0, size.width - overshootHeadroomX * 2),
            height: max(0, size.height - overshootHeadroomBottom)
        )
    }

    /// How the shell should open, which depends on whether there is actually a
    /// camera housing to grow out of.
    public enum ShellPresentation: Equatable, Sendable {
        /// Built-in notched display: the body inflates out of the physical cap.
        case notch
        /// External display with no notch. Growing from a cap would be growing
        /// from a shape the hardware doesn't have, so the panel scales up in
        /// place like any other HUD instead.
        case detached
    }

    /// Scale of the detached shell at progress 0. Close enough to full size that
    /// it reads as materializing rather than zooming.
    public static let detachedMinimumScale: CGFloat = 0.86

    /// A single source of truth for the shell's compact-to-expanded geometry.
    /// The body grows down and out from the cap rather than appearing as a resized window.
    public static func shellLayout(
        in rect: CGRect,
        capWidth: CGFloat,
        capHeight: CGFloat,
        progress: CGFloat,
        presentation: ShellPresentation = .notch
    ) -> PanelShellLayout {
        if presentation == .detached {
            return detachedLayout(in: rect, progress: progress)
        }
        let p = min(max(progress, 0), maxShellProgress)
        let capW = min(max(1, capWidth), rect.width)
        let capH = min(max(capHeight, 12), max(12, rect.height * 0.42))
        let bodyTop = rect.maxY - capH
        let availableBodyHeight = max(0, bodyTop - rect.minY)
        // Geometry is strictly linear in progress: the spring driving
        // `shellProgress` is the only motion curve.
        //
        // This previously applied its own ease-outs (1 - (1-p)^2.2 and ^1.9) on
        // top of the spring. Those curves have slope → 0 at p = 1 while the
        // overshoot region above 1 passes through at slope 1, so the shape
        // decelerated almost to a stop and then lurched into the overshoot — a
        // kink exactly where the eye is looking. Easing the value and easing the
        // geometry are the same job; doing both is what made it feel unnatural.
        let bodyHeight = availableBodyHeight * p
        let bodyWidth = capW + max(0, rect.width - capW) * p
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

    /// Uniform scale about the rect's centre, for displays without a notch.
    ///
    /// Linear in progress like the notch path, so the spring stays the only
    /// motion curve and its overshoot passes through without a kink. There is no
    /// cap: the caller pairs this with an opacity fade so the panel appears
    /// rather than unfurling from a housing that isn't there.
    private static func detachedLayout(in rect: CGRect, progress: CGFloat) -> PanelShellLayout {
        let p = min(max(progress, 0), maxShellProgress)
        let scale = detachedMinimumScale + (1 - detachedMinimumScale) * p
        let width = rect.width * scale
        let height = rect.height * scale
        let body = CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
        // Zero-width cap at the top centre: nothing to draw, but it keeps
        // `capRect` meaningful for callers that read it.
        let cap = CGRect(x: rect.midX, y: body.maxY, width: 0, height: 0)
        return PanelShellLayout(
            capRect: cap,
            bodyRect: body,
            shellRect: body,
            neckRadius: 0,
            bodyCornerRadius: min(24, width / 2, height / 2),
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
