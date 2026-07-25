import AppKit
import SwiftUI

/// Shared visual language for NotchClip's transient surfaces.
///
/// The palette is intentionally neutral. Glass supplies depth; color is kept for
/// semantic states such as success, warning, and destructive actions.
enum NotchClipDesign {
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.38)

    static let surface = Color.white.opacity(0.040)
    static let surfaceHover = Color.white.opacity(0.064)
    static let surfacePressed = Color.white.opacity(0.095)
    static let surfaceSelected = Color.white.opacity(0.115)
    static let surfaceStrong = Color.white.opacity(0.085)

    static let border = Color.white.opacity(0.075)
    static let borderHover = Color.white.opacity(0.12)
    static let borderSelected = Color.white.opacity(0.24)
    static let hairline = Color.white.opacity(0.065)

    static let shellTint = Color.black.opacity(0.70)
    static let deepSurface = Color.black.opacity(0.30)

    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let destructive = Color(nsColor: .systemRed)
}

/// AppKit material bridge shared by the onboarding and library windows.
struct NotchClipMaterialBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
    }
}

/// Raycast-style shortcut label: quiet until it is useful, but always legible.
struct NotchClipKeycap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(NotchClipDesign.secondaryText)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(NotchClipDesign.surfaceStrong)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(NotchClipDesign.border, lineWidth: 1)
            }
            .accessibilityLabel(text)
    }
}

struct NotchClipSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isSelected: Bool
    let isHovering: Bool
    let castsShadow: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                shape.fill(
                    isSelected
                        ? NotchClipDesign.surfaceSelected
                        : (isHovering ? NotchClipDesign.surfaceHover : NotchClipDesign.surface)
                )
            )
            .overlay {
                shape.strokeBorder(
                    isSelected
                        ? NotchClipDesign.borderSelected
                        : (isHovering ? NotchClipDesign.borderHover : NotchClipDesign.border),
                    lineWidth: 1
                )
            }
            .shadow(
                color: castsShadow ? Color.black.opacity(0.20) : .clear,
                radius: castsShadow ? 12 : 0,
                y: castsShadow ? 6 : 0
            )
    }
}

extension View {
    func notchClipSurface(
        cornerRadius: CGFloat,
        isSelected: Bool = false,
        isHovering: Bool = false,
        castsShadow: Bool = false
    ) -> some View {
        modifier(
            NotchClipSurfaceModifier(
                cornerRadius: cornerRadius,
                isSelected: isSelected,
                isHovering: isHovering,
                castsShadow: castsShadow
            )
        )
    }
}
