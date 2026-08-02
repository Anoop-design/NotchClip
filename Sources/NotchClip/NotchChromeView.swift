import AppKit
import NotchClipCore

/// Derives a channel's speed from the per-frame values AppKit writes while an
/// animation is running.
///
/// Measured rather than assumed: driving a custom `@objc dynamic` NSView
/// property through `animations` makes AppKit write the interpolated value via
/// KVC every frame (~8.3 ms on a 120 Hz display), so consecutive `didSet` calls
/// are a real sample stream. Frame timestamps jitter by a millisecond or so, and
/// a single-frame difference inherits all of it, so the estimate is smoothed
/// over a couple of frames.
struct ProgressVelocitySampler {
    /// Speed in progress-units per second.
    private var estimate: CGFloat = 0
    private var lastValue: CGFloat = 0
    private var lastTime: CFTimeInterval = 0

    /// Intervals outside this band are not animation frames: too short means two
    /// writes in one frame, too long means the animation already ended and this
    /// is a direct assignment, whose implied "velocity" is meaningless.
    private static let minInterval: CFTimeInterval = 0.0005
    private static let maxInterval: CFTimeInterval = 0.06
    private static let smoothing: CGFloat = 0.5

    mutating func record(_ value: CGFloat) {
        let now = CACurrentMediaTime()
        let dt = now - lastTime
        if dt > Self.minInterval, dt < Self.maxInterval {
            let sample = (value - lastValue) / CGFloat(dt)
            estimate += (sample - estimate) * Self.smoothing
        } else {
            estimate = 0
        }
        lastValue = value
        lastTime = now
    }

    mutating func reset(to value: CGFloat) {
        estimate = 0
        lastValue = value
        lastTime = CACurrentMediaTime()
    }

    /// Zero once the samples are stale — a shell that stopped moving a while ago
    /// is at rest, however fast it was travelling when it stopped.
    func velocity() -> CGFloat {
        (CACurrentMediaTime() - lastTime) > Self.maxInterval ? 0 : estimate
    }
}

/// Solid-black island chrome whose mask grows down and out from the physical notch.
final class NotchChromeView: NSView {
    var capWidth: CGFloat = PanelGeometry.compactDefaultWidth
    var capHeight: CGFloat = PanelGeometry.compactMinHeight
    var attachesToNotch = true

    /// Horizontal channel. Measured: AppKit drives a custom `@objc dynamic`
    /// property through the `animations` dictionary by writing the interpolated
    /// value via KVC once per frame, so `didSet` fires ~120×/s and is a valid
    /// place to sample velocity from.
    @objc dynamic var shellProgressX: CGFloat = 0 {
        didSet {
            shellProgressX = min(max(shellProgressX, 0), PanelGeometry.maxShellProgressX)
            // Clamp first: velocity must describe what the eye sees, not the
            // uncapped value the spring wanted.
            widthSampler.record(shellProgressX)
            needsLayout = true
        }
    }

    /// Vertical channel. Ceiling above 1 leaves room for the spring's overshoot.
    @objc dynamic var shellProgressY: CGFloat = 0 {
        didSet {
            shellProgressY = min(max(shellProgressY, 0), PanelGeometry.maxShellProgressY)
            heightSampler.record(shellProgressY)
            needsLayout = true
        }
    }

    /// Single-channel view of the shell, for callers with no interest in the
    /// axis bloom (the capture pulse's lip, the onboarding preview). Animating
    /// this through `animator()` works exactly as it did when it was stored:
    /// AppKit interpolates it and writes through this setter each frame.
    @objc dynamic var shellProgress: CGFloat {
        get { shellProgressY }
        set {
            shellProgressX = newValue
            shellProgressY = newValue
        }
    }

    /// Current speed of each channel in progress-units per second, or 0 once the
    /// samples are stale. Feeds `CASpringAnimation.initialVelocity` so a
    /// transition interrupted mid-flight keeps its momentum instead of stopping
    /// dead and reversing.
    var widthVelocity: CGFloat { widthSampler.velocity() }
    var heightVelocity: CGFloat { heightSampler.velocity() }

    /// Set both channels without animating, discarding sampled velocity — the
    /// shell teleported, it did not travel.
    func setShellProgress(x: CGFloat, y: CGFloat) {
        shellProgressX = x
        shellProgressY = y
        widthSampler.reset(to: shellProgressX)
        heightSampler.reset(to: shellProgressY)
    }

    private var widthSampler = ProgressVelocitySampler()
    private var heightSampler = ProgressVelocitySampler()

    /// Content that should track the *resting* shell rect, not the window
    /// bounds — the window is larger to give overshoot somewhere to go.
    weak var contentHost: NSView?

    /// Transparent room this view's window reserves *above* the resting shell.
    /// Only the detached presentation uses it (for the downward settle); the
    /// capture pulse's window has none, so it leaves this at 0.
    var detachedTopHeadroom: CGFloat = 0

    /// The resting shell rect within `bounds`, excluding overshoot headroom.
    var restingRect: CGRect {
        PanelGeometry.restingRect(
            inWindowSized: bounds.size,
            topHeadroom: attachesToNotch ? 0 : detachedTopHeadroom
        )
    }

    var preferOpaque: Bool = false {
        didSet { applyMaterial() }
    }

    private let effectView = NSVisualEffectView()
    private let shellTint = NSView()
    private let capTint = NSView()
    private let maskLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if key == "shellProgress" || key == "shellProgressX" || key == "shellProgressY" {
            // Fallback only. The panel controller installs per-axis, per-
            // direction CASpringAnimations via `animations` before each
            // transition; the capture pulse and onboarding preview animate
            // `shellProgress` with their own context timing and rely on this.
            return CABasicAnimation()
        }
        return super.defaultAnimation(forKey: key)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.mask = maskLayer

        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.material = .hudWindow
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.autoresizingMask = [.width, .height]
        addSubview(effectView)

        shellTint.wantsLayer = true
        shellTint.autoresizingMask = [.width, .height]
        addSubview(shellTint)

        // The cap and expanded body deliberately share one solid-black finish,
        // matching the visual continuity of the physical camera housing.
        capTint.wantsLayer = true
        addSubview(capTint)

        highlightLayer.fillColor = NSColor.clear.cgColor
        highlightLayer.strokeColor = NSColor.clear.cgColor
        highlightLayer.lineWidth = 0.5
        highlightLayer.lineJoin = .round
        highlightLayer.lineCap = .round
        layer?.addSublayer(highlightLayer)

        applyMaterial()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // During the morph only the path changes. Avoid re-laying out the blur,
        // tint, and layers when their stable expanded bounds are unchanged.
        if effectView.frame != bounds { effectView.frame = bounds }
        if shellTint.frame != bounds { shellTint.frame = bounds }
        if maskLayer.frame != bounds { maskLayer.frame = bounds }
        if highlightLayer.frame != bounds { highlightLayer.frame = bounds }

        // Content sits in the resting rect and never moves; only the shell
        // around it overshoots into the headroom.
        let resting = restingRect
        if let contentHost, contentHost.frame != resting {
            contentHost.frame = resting
        }

        let layout = PanelGeometry.shellLayout(
            in: resting,
            capWidth: capWidth,
            capHeight: capHeight,
            progress: ShellProgress(x: shellProgressX, y: shellProgressY),
            presentation: attachesToNotch ? .notch : .detached,
            // The settle can only be as tall as the transparent room above the
            // shell, or its first frames would be clipped at the window edge.
            detachedSettle: min(PanelGeometry.detachedSettleOffset, detachedTopHeadroom)
        )
        let path = shellCGPath(layout: layout, attachesToNotch: attachesToNotch)
        let highlightPath = attachesToNotch
            ? bodyHighlightCGPath(layout: layout)
            : path

        capTint.isHidden = !attachesToNotch
        if attachesToNotch, capTint.frame != layout.capRect {
            capTint.frame = layout.capRect
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.path = path
        highlightLayer.path = highlightPath
        CATransaction.commit()
    }

    func updateShell(width: CGFloat, height: CGFloat, attachesToNotch: Bool) {
        capWidth = width
        capHeight = height
        self.attachesToNotch = attachesToNotch
        needsLayout = true
    }

    private func applyMaterial() {
        // The whole shell is true black — one continuous piece of material with
        // the physical camera housing, like the hardware grew downward. Blur
        // was tried and rejected: it made the panel read as "a window near the
        // notch" instead of "the notch, open". Depth comes from hairlines and
        // surface tints in the content layer, not from translucency.
        effectView.isHidden = true
        shellTint.layer?.backgroundColor = NSColor.black.cgColor
        capTint.layer?.backgroundColor = NSColor.black.cgColor
    }

    private func shellCGPath(
        layout: PanelShellLayout,
        attachesToNotch: Bool
    ) -> CGPath {

        if !attachesToNotch {
            // Detached: a plain rounded rect that scales in place. The radius is
            // fixed rather than progress-driven so the corners don't visibly
            // tighten during the scale.
            let radius = min(layout.bodyCornerRadius, layout.shellRect.height / 2)
            return CGPath(
                roundedRect: layout.shellRect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
        }

        guard layout.progress.y > 0.001, layout.bodyRect.height > 0.5 else {
            let radius = min(9, layout.capRect.height / 2)
            return CGPath(
                roundedRect: layout.capRect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
        }

        let body = layout.bodyRect
        let cap = layout.capRect
        let corner = layout.bodyCornerRadius
        let neck = layout.neckRadius
        let path = CGMutablePath()

        path.move(to: CGPoint(x: body.minX + corner, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - corner, y: body.minY))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX, y: body.minY + corner),
            control: CGPoint(x: body.maxX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - corner))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX - corner, y: body.maxY),
            control: CGPoint(x: body.maxX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: cap.maxX + neck, y: body.maxY))
        path.addCurve(
            to: CGPoint(x: cap.maxX, y: body.maxY + neck),
            control1: CGPoint(x: cap.maxX + neck * 0.45, y: body.maxY),
            control2: CGPoint(x: cap.maxX, y: body.maxY + neck * 0.45)
        )
        path.addLine(to: CGPoint(x: cap.maxX, y: cap.maxY))
        path.addLine(to: CGPoint(x: cap.minX, y: cap.maxY))
        path.addLine(to: CGPoint(x: cap.minX, y: body.maxY + neck))
        path.addCurve(
            to: CGPoint(x: cap.minX - neck, y: body.maxY),
            control1: CGPoint(x: cap.minX, y: body.maxY + neck * 0.45),
            control2: CGPoint(x: cap.minX - neck * 0.45, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.minX + corner, y: body.maxY))
        path.addQuadCurve(
            to: CGPoint(x: body.minX, y: body.maxY - corner),
            control: CGPoint(x: body.minX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + corner))
        path.addQuadCurve(
            to: CGPoint(x: body.minX + corner, y: body.minY),
            control: CGPoint(x: body.minX, y: body.minY)
        )
        path.closeSubpath()
        return path
    }

    /// A restrained hairline around the glass body and shoulders. The camera
    /// cap itself is intentionally excluded so no bright outline appears around
    /// the physical notch.
    private func bodyHighlightCGPath(layout: PanelShellLayout) -> CGPath? {
        guard layout.progress.y > 0.001, layout.bodyRect.height > 0.5 else { return nil }

        let body = layout.bodyRect
        let cap = layout.capRect
        let corner = layout.bodyCornerRadius
        let neck = layout.neckRadius
        let path = CGMutablePath()

        path.move(to: CGPoint(x: cap.maxX, y: body.maxY + neck))
        path.addCurve(
            to: CGPoint(x: cap.maxX + neck, y: body.maxY),
            control1: CGPoint(x: cap.maxX, y: body.maxY + neck * 0.45),
            control2: CGPoint(x: cap.maxX + neck * 0.45, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.maxX - corner, y: body.maxY))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX, y: body.maxY - corner),
            control: CGPoint(x: body.maxX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: body.maxX, y: body.minY + corner))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX - corner, y: body.minY),
            control: CGPoint(x: body.maxX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: body.minX + corner, y: body.minY))
        path.addQuadCurve(
            to: CGPoint(x: body.minX, y: body.minY + corner),
            control: CGPoint(x: body.minX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: body.minX, y: body.maxY - corner))
        path.addQuadCurve(
            to: CGPoint(x: body.minX + corner, y: body.maxY),
            control: CGPoint(x: body.minX, y: body.maxY)
        )
        path.addLine(to: CGPoint(x: cap.minX - neck, y: body.maxY))
        path.addCurve(
            to: CGPoint(x: cap.minX, y: body.maxY + neck),
            control1: CGPoint(x: cap.minX - neck * 0.45, y: body.maxY),
            control2: CGPoint(x: cap.minX, y: body.maxY + neck * 0.45)
        )
        return path
    }
}
