import SwiftUI
import AppKit
import NotchClipCore

@main
struct NotchClipApp: App {
    @NSApplicationDelegateAdaptor(NotchClipAppDelegate.self) private var appDelegate

    private var coordinator: AppCoordinator {
        appDelegate.coordinator
    }

    var body: some Scene {
        MenuBarExtra("NotchClip", systemImage: coordinator.menuBarSymbol) {
            menuContent
        }

        Settings {
            SettingsView(
                history: coordinator.history,
                accessibility: coordinator.accessibility,
                launchAtLogin: coordinator.launchAtLogin,
                hotKeyError: coordinator.hotKeyError,
                isHotKeyRegistered: coordinator.hotKey.isRegistered,
                isPaused: coordinator.isPaused,
                onTogglePause: { coordinator.togglePause() },
                onSetUpAccessibility: { coordinator.presentAccessibilitySetup() }
            )
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if let storageError = coordinator.storageError {
            Text("Storage unavailable")
                .font(.headline)
            Text(storageError)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Divider()
        }

        if let hotKeyError = coordinator.hotKeyError {
            Text(hotKeyError)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
            Text("Menu Show Clipboard still works.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Divider()
        }

        if coordinator.isPaused {
            Text("Capture paused")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button("Show Clipboard") {
            coordinator.toggleClipboardPanel()
        }
        .keyboardShortcut(
            KeyEquivalent(NotchClipHotKey.key),
            modifiers: menuShortcutModifiers
        )
        .disabled(coordinator.storageError != nil)

        Button("All Clips…") {
            coordinator.openClipboardLibrary()
        }
        .keyboardShortcut("o", modifiers: [.command])
        .disabled(coordinator.storageError != nil)

        Button(coordinator.isPaused ? "Resume" : "Pause") {
            coordinator.togglePause()
        }
        .disabled(coordinator.monitor == nil)

        if !coordinator.accessibility.isGranted {
            Divider()

            Button("Set Up Automatic Paste…") {
                coordinator.presentAccessibilitySetup()
            }
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button("Quit NotchClip") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    private var menuShortcutModifiers: EventModifiers {
        NotchClipHotKey.modifiers.reduce(into: EventModifiers()) { modifiers, modifier in
            switch modifier {
            case .command:
                modifiers.insert(.command)
            case .control:
                modifiers.insert(.control)
            case .option:
                modifiers.insert(.option)
            case .shift:
                modifiers.insert(.shift)
            }
        }
    }
}
