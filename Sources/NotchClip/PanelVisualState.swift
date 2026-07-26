import Foundation
import CoreGraphics
import NotchClipCore

/// Retained observable visual/focus state for the notch shell (shared with SwiftUI root).
@MainActor
@Observable
final class PanelVisualState {
    /// 0 = compact shell, 1 = fully expanded shell.
    var shellProgress: CGFloat = 0
    /// Content layer opacity (fades in after shell growth begins).
    var contentOpacity: Double = 0
    /// Subtle content scale; disabled under Reduce Motion.
    var contentScale: CGFloat = 1
    /// Cap width used by the notch mask (compact top band).
    var capWidth: CGFloat = PanelGeometry.compactDefaultWidth
    var capHeight: CGFloat = PanelGeometry.compactMinHeight
    /// Incremented on every presentation after the panel becomes key — drives the
    /// `@FocusState` on the panel's search field.
    private(set) var focusRequestID: UInt64 = 0
    var reduceMotion: Bool = false
    var reduceTransparency: Bool = false

    func requestSearchFocus() {
        focusRequestID &+= 1
    }

    func resetForCompact() {
        shellProgress = 0
        contentOpacity = 0
        contentScale = 1
    }

    func applyExpandedAppearance() {
        shellProgress = 1
        contentOpacity = 1
        contentScale = 1
    }

    func applyCollapsedAppearance() {
        contentOpacity = 0
        contentScale = 1
        shellProgress = 0
    }
}
