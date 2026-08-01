import SwiftUI
import AppKit
import NotchClipCore

/// Click the keycap, press a shortcut. The local monitor swallows every keydown
/// while recording, so it is torn down on commit, on cancel, on disappear, and
/// whenever the Settings window stops being key — otherwise it would eat the
/// panel's own ⌘1–9 and Escape handling. `onBeginRecording` stands the global
/// registration down so the shortcut in use can itself be re-recorded.
struct HotKeyRecorderField: View {
    let binding: NotchClipHotKeyBinding
    let onRecord: (NotchClipHotKeyBinding) -> Void
    let onBeginRecording: () -> Void
    let onEndRecording: () -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                NotchClipKeycap(isRecording ? "Type shortcut…" : description.symbolic)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: isRecording ? 1.5 : 0)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press the keys you want, or Escape to cancel" : "Click to record a new shortcut")
            .accessibilityLabel(isRecording ? "Recording shortcut" : description.spoken)
            .accessibilityHint("Click, then press the keys you want to use")

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(NotchClipDesign.warning)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 300, alignment: .trailing)
            }
        }
        .onChange(of: binding) {
            validationMessage = nil
        }
        .onDisappear {
            stopRecording()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
        ) { _ in
            stopRecording()
        }
    }

    private var description: HotKeyDescription {
        HotKeyKeyLabels.description(for: binding)
    }

    private func startRecording() {
        guard monitor == nil else { return }
        validationMessage = nil
        isRecording = true
        onBeginRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        guard monitor != nil else {
            isRecording = false
            return
        }
        finishRecording()
        onEndRecording()
    }

    /// Tears the monitor down without restoring the suspended shortcut. The
    /// commit path hands ownership of the registration to `onRecord`, so the
    /// hotkey changes state once instead of twice.
    private func finishRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.notchClipHotKeyModifiers
        // Bare Escape cancels; a modified Escape is still rejected by validation.
        if event.keyCode == NotchClipHotKeyValidation.escapeKeyCode, modifiers.isEmpty {
            stopRecording()
            return
        }
        let candidate = NotchClipHotKeyBinding(keyCode: event.keyCode, modifiers: modifiers)
        if let failure = NotchClipHotKeyValidation.failure(for: candidate) {
            // Stay in recording state so the next attempt does not need another click.
            validationMessage = NotchClipHotKeyValidation.message(for: failure)
            return
        }
        finishRecording()
        onRecord(candidate)
    }
}
