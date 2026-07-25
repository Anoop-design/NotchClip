import AppKit
import SwiftUI
import NotchClipCore

private enum QuickShelfLayout {
    static let cardWidth: CGFloat = 100
    static let cardHeight: CGFloat = 108
    static let cardCornerRadius: CGFloat = 12
    static let previewWidth: CGFloat = 86
    static let previewHeight: CGFloat = 68
    static let previewCornerRadius: CGFloat = 9
    static let libraryWidth: CGFloat = 82
}

struct PanelRootView: View {
    @Bindable var history: HistoryModel
    @Bindable var visualState: PanelVisualState
    var dragController: HistoryDragController
    var onSelect: () -> Void
    var onOpenLibrary: () -> Void
    var onEscape: () -> Void
    var onBeginDrag: () -> Void
    var onEndDrag: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shelf: [ClipboardEntry] { history.quickShelf }
    private var motionReduced: Bool { reduceMotion || visualState.reduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            trayHeader

            content
                .frame(maxHeight: .infinity)
                .padding(.top, 6)
                .padding(.bottom, 4)

            commandBar
        }
        .padding(.horizontal, 14)
        .padding(.top, max(8, visualState.capHeight + 8))
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .environment(\.colorScheme, .dark)
        .opacity(visualState.contentOpacity)
        .offset(y: motionReduced ? 0 : CGFloat(1 - visualState.contentOpacity) * -4)
        .animation(
            motionReduced ? nil : .easeOut(duration: 0.14),
            value: history.captureError
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchClip clipboard shelf")
    }

    private var trayHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NotchClipDesign.secondaryText)
                .accessibilityHidden(true)

            Text("Clipboard")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(NotchClipDesign.primaryText)

            Spacer(minLength: 12)

            NotchClipKeycap("⌃V")
                .accessibilityLabel("Control V shortcut")

            TrayCloseButton(
                reduceMotion: motionReduced,
                action: onEscape
            )
        }
        .frame(height: 28)
    }

    @ViewBuilder
    private var content: some View {
        if let storageError = history.storageError {
            emptyState(
                title: "Storage unavailable",
                systemImage: "externaldrive.badge.exclamationmark",
                detail: storageError,
                tone: NotchClipDesign.warning
            )
        } else if history.isEmpty {
            emptyState(
                title: "Your clipboard is ready",
                systemImage: "rectangle.on.rectangle",
                detail: "Copy text, links, images, or files and they’ll appear here.",
                tone: NotchClipDesign.secondaryText
            )
        } else {
            clipboardShelf
        }
    }

    private var clipboardShelf: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 7) {
                        ForEach(shelf) { entry in
                            QuickShelfCard(
                                entry: entry,
                                row: EntryRowModel(
                                    entry: entry,
                                    linkTitle: history.previewCache[entry.id]?.linkTitle
                                        ?? history.linkPreviews?.results[entry.id]?.title
                                ),
                                preview: history.previewCache[entry.id],
                                isSelected: !visualState.libraryTileSelected
                                    && history.selectedID == entry.id,
                                dragController: dragController,
                                onActivate: {
                                    visualState.libraryTileSelected = false
                                    history.selectedID = entry.id
                                    onSelect()
                                },
                                onPin: { history.togglePin(id: entry.id) },
                                onAppear: { history.rowBecameVisible(entry) },
                                onDisappear: { history.rowDidDisappear(entry.id) }
                            )
                            .id(entry.id)
                        }
                    }
                    // Leave just enough room for the focus ring while exposing
                    // part of the next card as a quiet horizontal-scroll cue.
                    .padding(.horizontal, 3)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .frame(maxWidth: .infinity)
                .onChange(of: history.selectedID) { _, selectedID in
                    guard let selectedID,
                          shelf.contains(where: { $0.id == selectedID }) else { return }
                    withAnimation(motionReduced ? nil : .easeOut(duration: 0.20)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }
            .layoutPriority(1)

            Rectangle()
                .fill(NotchClipDesign.hairline)
                .frame(width: 1, height: 74)
                .accessibilityHidden(true)

            AllClipsTile(
                isSelected: visualState.libraryTileSelected,
                reduceMotion: motionReduced,
                action: onOpenLibrary
            )
        }
        .frame(height: 116)
    }

    private func emptyState(
        title: String,
        systemImage: String,
        detail: String,
        tone: Color
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(tone)
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.primaryText)

                Text(detail)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(NotchClipDesign.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var commandBar: some View {
        if let captureError = history.captureError {
            CaptureErrorBar(
                message: captureError,
                onDismiss: history.clearCaptureError
            )
            .transition(.opacity)
        } else {
            HStack(spacing: 10) {
                if history.isPaused {
                    Label("Capture paused", systemImage: "pause.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NotchClipDesign.warning.opacity(0.86))
                }

                Spacer(minLength: 8)

                TrayCommandHint(key: "← →", label: "Move")
                TrayCommandHint(key: "↵", label: "Paste")
                TrayCommandHint(key: "⌘F", label: "All Clips")
            }
            .frame(height: 22)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Use left and right arrows to move, Return to paste, or Command F for all clips"
            )
        }
    }
}

private struct QuickShelfCard: View {
    let entry: ClipboardEntry
    let row: EntryRowModel
    let preview: EntryPreview?
    let isSelected: Bool
    var dragController: HistoryDragController
    var onActivate: () -> Void
    var onPin: () -> Void
    var onAppear: () -> Void
    var onDisappear: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canDrag: Bool {
        !row.hasMissingFiles && entry.payloadRefs.contains { !$0.relativePath.isEmpty }
    }

    private var previewImage: NSImage? {
        preview?.thumbnail ?? preview?.fileIcon
    }

    private var isTextual: Bool {
        [.plainText, .rtf, .html].contains(row.kind)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Button(action: onActivate) {
                VStack(alignment: .leading, spacing: 6) {
                    previewSurface
                    metadataRow
                }
                .padding(7)
                .frame(
                    width: QuickShelfLayout.cardWidth,
                    height: QuickShelfLayout.cardHeight,
                    alignment: .topLeading
                )
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: QuickShelfLayout.cardCornerRadius,
                        style: .continuous
                    )
                )
            }
            .buttonStyle(
                TrayTileButtonStyle(
                    isSelected: isSelected,
                    isHovering: isHovering,
                    reduceMotion: reduceMotion
                )
            )
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint("Pastes this item into the previous app")
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)

            // The AppKit drag bridge stays outside the SwiftUI Button so its
            // mouse-drag threshold continues to win over button activation.
            if canDrag {
                VStack(spacing: 0) {
                    DragHandleView(
                        entry: entry,
                        previewImage: previewImage,
                        controller: dragController,
                        onActivate: onActivate,
                        isEnabled: true
                    )
                    .frame(
                        width: QuickShelfLayout.previewWidth,
                        height: QuickShelfLayout.previewHeight
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: QuickShelfLayout.previewCornerRadius,
                            style: .continuous
                        )
                    )
                    .accessibilityLabel("Drag or paste \(row.primaryText)")
                    .accessibilityHint("Click to paste, or drag into another app")
                    .help("Click to paste or drag into another app")

                    Spacer(minLength: 0)
                }
                .padding(.top, 7)
                .frame(
                    width: QuickShelfLayout.cardWidth,
                    height: QuickShelfLayout.cardHeight
                )
            }
        }
        .frame(
            width: QuickShelfLayout.cardWidth,
            height: QuickShelfLayout.cardHeight
        )
        .onHover { isHovering = $0 }
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
        .contextMenu {
            Button(entry.isPinned ? "Unpin" : "Pin", action: onPin)
            Button("Paste into Previous App", action: onActivate)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Press to paste this item into the previous app")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Paste") { onActivate() }
        .accessibilityAction(named: entry.isPinned ? "Unpin" : "Pin") { onPin() }
    }

    private var previewSurface: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: QuickShelfLayout.previewCornerRadius,
                style: .continuous
            )
            .fill(NotchClipDesign.surfaceStrong.opacity(0.68))

            previewContent
        }
        .frame(
            width: QuickShelfLayout.previewWidth,
            height: QuickShelfLayout.previewHeight
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: QuickShelfLayout.previewCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: QuickShelfLayout.previewCornerRadius,
                style: .continuous
            )
                .strokeBorder(NotchClipDesign.hairline, lineWidth: 0.5)
        }
        .overlay(alignment: .topTrailing) {
            statusGlyph
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let thumbnail = preview?.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(
                    width: QuickShelfLayout.previewWidth,
                    height: QuickShelfLayout.previewHeight
                )
                .clipped()
                .allowsHitTesting(false)
        } else if let fileIcon = preview?.fileIcon {
            Image(nsImage: fileIcon)
                .resizable()
                .scaledToFit()
                .padding(14)
                .allowsHitTesting(false)
        } else if isTextual {
            Text(row.primaryText)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(NotchClipDesign.primaryText.opacity(0.82))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(9)
                .allowsHitTesting(false)
        } else if row.kind == .url {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.secondaryText)

                Text(row.primaryText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotchClipDesign.primaryText.opacity(0.82))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(9)
            .allowsHitTesting(false)
        } else {
            Image(systemName: kindSymbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(NotchClipDesign.secondaryText)
                .allowsHitTesting(false)
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 5) {
            Image(systemName: kindSymbol)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(NotchClipDesign.tertiaryText)
                .accessibilityHidden(true)

            Text(metadataText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(NotchClipDesign.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .frame(height: 14)
        .padding(.horizontal, 1)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if row.hasMissingFiles {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(NotchClipDesign.warning)
                .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                .accessibilityLabel("Missing file")
        } else if row.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NotchClipDesign.primaryText.opacity(0.78))
                .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                .accessibilityLabel("Pinned")
        } else if isHovering && canDrag {
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NotchClipDesign.primaryText.opacity(0.66))
                .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }

    private var metadataText: String {
        if isTextual { return row.kindLabel }
        if row.kind == .url, preview?.thumbnail == nil {
            return row.secondaryText ?? row.kindLabel
        }
        return row.primaryText
    }

    private var kindSymbol: String {
        switch row.kind {
        case .plainText: return "text.alignleft"
        case .rtf: return "textformat"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .url: return "link"
        case .image: return "photo"
        case .fileList: return "doc.on.doc"
        case .mixed: return "square.stack.3d.up"
        case .other: return "clipboard"
        }
    }

    private var accessibilitySummary: String {
        var parts = [row.primaryText, row.kindLabel]
        if row.isPinned { parts.append("Pinned") }
        if row.hasMissingFiles { parts.append("Missing file") }
        return parts.joined(separator: ", ")
    }
}

private struct AllClipsTile: View {
    let isSelected: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(NotchClipDesign.secondaryText)

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NotchClipDesign.tertiaryText)
                        .offset(x: isHovering && !reduceMotion ? 1 : 0, y: isHovering && !reduceMotion ? -1 : 0)
                }

                Spacer(minLength: 8)

                Text("All Clips")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.primaryText)
                    .lineLimit(1)

                Text("Browse")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(NotchClipDesign.tertiaryText)
                    .lineLimit(1)
            }
            .padding(9)
            .frame(
                width: QuickShelfLayout.libraryWidth,
                height: QuickShelfLayout.cardHeight,
                alignment: .topLeading
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: QuickShelfLayout.cardCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(
            TrayTileButtonStyle(
                isSelected: isSelected,
                isHovering: isHovering,
                reduceMotion: reduceMotion
            )
        )
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isHovering)
        .keyboardShortcut("f", modifiers: [.command])
        .accessibilityLabel("Open all clipboard history")
        .accessibilityHint("Opens the searchable clipboard library")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("Search All Clips (Command-F)")
    }
}

private struct TrayTileButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isHovering: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: QuickShelfLayout.cardCornerRadius,
            style: .continuous
        )
        configuration.label
            .background(shape.fill(surfaceColor(isPressed: configuration.isPressed)))
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: isSelected ? 1 : 0.5)
            }
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.985)
            .animation(
                reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.90),
                value: configuration.isPressed
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.10),
                value: isHovering
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.14),
                value: isSelected
            )
    }

    private func surfaceColor(isPressed: Bool) -> Color {
        if isPressed { return NotchClipDesign.surfacePressed }
        if isSelected { return NotchClipDesign.surfaceSelected }
        if isHovering { return NotchClipDesign.surfaceHover }
        return NotchClipDesign.surface
    }

    private var borderColor: Color {
        if isSelected { return NotchClipDesign.borderSelected }
        if isHovering { return NotchClipDesign.borderHover.opacity(0.72) }
        return NotchClipDesign.border.opacity(0.30)
    }
}

private struct TrayCloseButton: View {
    let reduceMotion: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchClipDesign.secondaryText)
                .frame(width: 36, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovering ? NotchClipDesign.surfaceHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(TrayIconButtonStyle(reduceMotion: reduceMotion))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isHovering)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close clipboard history")
        .help("Close")
    }
}

private struct TrayIconButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.68 : 1)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.92)
            .animation(
                reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.86),
                value: configuration.isPressed
            )
    }
}

private struct TrayCommandHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            NotchClipKeycap(key)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchClipDesign.tertiaryText)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key), \(label)")
    }
}

private struct CaptureErrorBar: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(NotchClipDesign.warning)
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchClipDesign.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 6)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.secondaryText)
                    .frame(width: 36, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .frame(height: 22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clipboard capture error: \(message)")
    }
}
