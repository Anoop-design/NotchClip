import AppKit
import NotchClipCore

/// Solid-black island chrome whose mask grows down and out from the physical notch.
final class NotchChromeView: NSView {
    var capWidth: CGFloat = PanelGeometry.compactDefaultWidth
    var capHeight: CGFloat = PanelGeometry.compactMinHeight
    var attachesToNotch = true

    @objc dynamic var shellProgress: CGFloat = 0 {
        didSet {
            // Ceiling above 1 leaves room for the spring's overshoot.
            shellProgress = min(max(shellProgress, 0), PanelGeometry.maxShellProgress)
            needsLayout = true
        }
    }

    /// Content that should track the *resting* shell rect, not the window
    /// bounds — the window is larger to give overshoot somewhere to go.
    weak var contentHost: NSView?

    /// The resting shell rect within `bounds`, excluding overshoot headroom.
    var restingRect: CGRect {
        PanelGeometry.restingRect(inWindowSized: bounds.size)
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
        if key == "shellProgress" {
            // Fallback only. The controller installs a direction-specific
            // CASpringAnimation via `animations` before each transition.
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
            progress: shellProgress,
            presentation: attachesToNotch ? .notch : .detached
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

        guard layout.progress > 0.001, layout.bodyRect.height > 0.5 else {
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
        guard layout.progress > 0.001, layout.bodyRect.height > 0.5 else { return nil }

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
