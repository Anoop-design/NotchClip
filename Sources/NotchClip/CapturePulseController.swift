import AppKit
import SwiftUI
import NotchClipCore

/// The copy acknowledgment: when a clip is captured while the panel is closed,
/// the notch briefly swells into a small black lip — "Copied · Terminal" — then
/// retracts.
///
/// The window is never key and ignores mouse events entirely, so it can never
/// steal focus from the app the user is copying in, and clicks pass straight
/// through to whatever is beneath it. It reuses `NotchChromeView`, so the lip
/// is the same continuous black material as the panel shell.
@MainActor
final class CapturePulseController {
    private var window: NSPanel?
    private var chrome: NotchChromeView?
    private var label: NSHostingView<PulseLabel>?

    /// Monotonic token; delayed retract/order-out closures must match it.
    private var generation: UInt64 = 0
    private var isShowing = false

    /// Show (or refresh) the pulse for a captured entry.
    func show(for entry: ClipboardEntry) {
        generation &+= 1
        let token = generation
        let text = CapturePulsePolicy.label(for: entry)
        let symbol = NotchClipSymbols.symbol(for: entry.primaryKind)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        guard let metrics = Self.notchScreenMetrics() else { return }
        buildWindowIfNeeded()
        guard let window, let chrome, let label else { return }

        let capWidth = PanelGeometry.capWidth(on: metrics)
        let capHeight = max(
            PanelGeometry.compactMinHeight,
            metrics.hasNotch ? metrics.topSafeInset : PanelGeometry.compactMinHeight
        )
        let width = min(capWidth + CapturePulsePolicy.widthBeyondCap, metrics.frame.width - 16)
        let height = capHeight + CapturePulsePolicy.lipHeight
        let frame = NSRect(
            x: metrics.frame.midX - width / 2,
            y: metrics.frame.maxY - height,
            width: width,
            height: height
        )

        chrome.updateShell(width: capWidth, height: capHeight, attachesToNotch: metrics.hasNotch)
        label.rootView = PulseLabel(text: text, systemImage: symbol)
        label.frame = NSRect(x: 0, y: 0, width: width, height: CapturePulsePolicy.lipHeight)

        // A capture landing while the lip is already up just swaps the text and
        // restarts the hold — the lip stays open rather than stuttering.
        if isShowing {
            window.setFrame(frame, display: true)
            scheduleRetract(token: token, reduceMotion: reduceMotion)
            return
        }
        isShowing = true

        window.setFrame(frame, display: true)
        if reduceMotion {
            chrome.shellProgress = 1
            label.alphaValue = 1
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                window.animator().alphaValue = 1
            }
        } else {
            chrome.shellProgress = 0
            label.alphaValue = 0
            window.alphaValue = 1
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = CapturePulsePolicy.expandDuration
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.12, 0.92, 0.20, 1.0)
                chrome.animator().shellProgress = 1
            }
            // Text fades in once the lip has most of its area.
            DispatchQueue.main.asyncAfter(
                deadline: .now() + CapturePulsePolicy.expandDuration * 0.4
            ) { [weak self] in
                guard let self, self.generation == token, self.isShowing else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.14
                    self.label?.animator().alphaValue = 1
                }
            }
        }
        scheduleRetract(token: token, reduceMotion: reduceMotion)
    }

    /// Immediate teardown — called when the real panel is about to present.
    func cancel() {
        generation &+= 1
        isShowing = false
        window?.orderOut(nil)
        chrome?.shellProgress = 0
        label?.alphaValue = 0
    }

    private func scheduleRetract(token: UInt64, reduceMotion: Bool) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CapturePulsePolicy.expandDuration + CapturePulsePolicy.holdDuration
        ) { [weak self] in
            guard let self, self.generation == token, self.isShowing else { return }
            self.retract(token: token, reduceMotion: reduceMotion)
        }
    }

    private func retract(token: UInt64, reduceMotion: Bool) {
        guard let window, let chrome, let label else { return }
        if reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.10
                window.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.finishRetract()
                }
            })
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            label.animator().alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = CapturePulsePolicy.retractDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0.0, 0.25, 1.0)
            chrome.animator().shellProgress = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.finishRetract()
            }
        })
    }

    private func finishRetract() {
        isShowing = false
        window?.orderOut(nil)
        window?.alphaValue = 1
        chrome?.shellProgress = 0
        label?.alphaValue = 0
    }

    // MARK: - Construction

    private func buildWindowIfNeeded() {
        if window != nil { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 68),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Never a focus or click target: acknowledgment only.
        panel.ignoresMouseEvents = true

        let chrome = NotchChromeView(frame: .zero)
        chrome.autoresizingMask = [.width, .height]
        panel.contentView = chrome

        let hosting = NSHostingView(rootView: PulseLabel(text: "", systemImage: "clipboard"))
        hosting.alphaValue = 0
        // Masked, so the label is clipped by the lip's outline while it grows —
        // deliberately not `contentHost`, which would also make it ride the
        // shell's scale. The pulse's label just fades.
        chrome.addMaskedSubview(hosting)

        self.window = panel
        self.chrome = chrome
        self.label = hosting
    }

    /// The pulse belongs to the notch. Prefer the notched display; on external
    /// setups without one, fall back to the main display's top edge.
    private static func notchScreenMetrics() -> ScreenMetrics? {
        let screens = NSScreen.screens
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0.5 }) {
            return NotchPanelController.metrics(from: notched)
        }
        return NSScreen.main.map { NotchPanelController.metrics(from: $0) }
    }
}

/// The lip's one line: kind icon + "Copied · Source".
private struct PulseLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(NotchClipDesign.secondaryText)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(NotchClipDesign.primaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
