import SwiftUI
import AppKit
import NotchClipCore

struct SettingsView: View {
    @Bindable var history: HistoryModel
    @Bindable var accessibility: AccessibilityPermissionState
    var hotKeyError: String?
    var isHotKeyRegistered: Bool
    var isPaused: Bool
    var onTogglePause: () -> Void
    var onSetUpAccessibility: () -> Void

    @State private var confirmClearUnpinned = false
    @State private var confirmClearAll = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            storageTab
                .tabItem { Label("History & Storage", systemImage: "internaldrive") }
            privacyTab
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 580, height: 430)
        .onAppear {
            history.refreshStorageStats()
            accessibility.refresh()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didActivateApplicationNotification
            )
        ) { _ in
            accessibility.refresh()
        }
        .confirmationDialog(
            "Clear unpinned history?",
            isPresented: $confirmClearUnpinned,
            titleVisibility: .visible
        ) {
            Button("Clear Unpinned", role: .destructive) {
                history.clearUnpinned()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned items are kept. Retained clipboard bytes for unpinned items are removed. Source files on disk are not deleted.")
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $confirmClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                history.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every history entry and all retained payload bytes under NotchClip storage, including orphans. Original source files are never deleted.")
        }
    }

    private var generalTab: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Show Clipboard") {
                    NotchClipKeycap("⌃V")
                        .accessibilityLabel(NotchClipHotKey.displayName)
                }
                if let hotKeyError {
                    Label(hotKeyError, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(NotchClipDesign.warning)
                        .font(.caption)
                } else if isHotKeyRegistered {
                    Label("Shortcut is active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            Section("Automatic Paste") {
                LabeledContent(
                    "Accessibility",
                    value: accessibility.isGranted ? "Allowed" : "Required"
                )
                Text("NotchClip uses Accessibility only to send Command–V to the app you were using after you choose a clipboard item.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !accessibility.isGranted {
                    Button("Set Up Automatic Paste…") {
                        onSetUpAccessibility()
                    }
                }
            }
            Section("Capture") {
                Toggle(isOn: Binding(
                    get: { !isPaused },
                    set: { _ in onTogglePause() }
                )) {
                    Text(isPaused ? "Paused" : "Monitoring clipboard")
                }
            }
        }
        .settingsFormChrome()
    }

    private var storageTab: some View {
        Form {
            Section("Usage") {
                LabeledContent("Items", value: "\(history.storageStats?.itemCount ?? history.entries.count)")
                LabeledContent("Retained payloads", value: history.storageStats?.formattedBytes ?? "—")
                if let path = history.storageStats?.applicationSupportPath, !path.isEmpty {
                    HStack {
                        Text(path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                }
            }
            Section("History Cleanup") {
                Button("Clear Unpinned…", role: .destructive) {
                    confirmClearUnpinned = true
                }
                Button("Clear All…", role: .destructive) {
                    confirmClearAll = true
                }
            }
            if let captureError = history.captureError {
                Section("Last Error") {
                    Label(captureError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(NotchClipDesign.destructive)
                        .font(.caption)
                    Button("Dismiss") { history.clearCaptureError() }
                }
            }
        }
        .settingsFormChrome()
    }

    private var privacyTab: some View {
        Form {
            Section("Local Only") {
                Text("NotchClip stores clipboard history only on this Mac under Application Support. There is no telemetry, account, or cloud sync.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("What Is Skipped") {
                Text("Concealed, transient, and auto-generated pasteboard markers are never retained. Representations larger than 64 MiB are skipped whole (never truncated).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Files") {
                Text("When you copy files, NotchClip keeps pasteboard file-URL representations and paths for missing-file checks. It does not copy your original source files into its storage.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Link Previews") {
                Toggle("Fetch link previews", isOn: Binding(
                    get: { history.preferences.fetchLinkPreviews },
                    set: { history.setFetchLinkPreviews($0) }
                ))
                Text("When enabled, NotchClip may request page metadata for HTTP/HTTPS links you copy. The destination site (or its metadata host) may learn your Mac’s IP address and similar request details. Previews are cached only on this Mac. When disabled, no metadata requests are made and rows show the local host or raw URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear Link Preview Cache") {
                    history.clearLinkPreviewCache()
                }
            }
        }
        .settingsFormChrome()
    }

    private var aboutTab: some View {
        Form {
            Section {
                LabeledContent("App", value: "NotchClip")
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: appBuild)
                LabeledContent("Requires", value: "macOS 14+")
            }
        }
        .settingsFormChrome()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.4.0-dev"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    }
}

private extension View {
    func settingsFormChrome() -> some View {
        formStyle(.grouped)
            .scrollIndicators(.never)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
    }
}
