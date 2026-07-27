import AppKit
import SwiftUI
import NotchClipCore

enum PanelLayout {
    static let headerHeight: CGFloat = 40
    // Slightly taller than the strictly-needed 30 so the count and keycaps
    // sit with a little air above the r24 bottom corners.
    static let footerHeight: CGFloat = 36
    static let footerPadding: CGFloat = 14
    static let listWidth: CGFloat = 252
    static let rowHeight: CGFloat = 44
    static let sectionHeaderHeight: CGFloat = 24
    static let glyphSize: CGFloat = 28
    static let horizontalPadding: CGFloat = 12
}

/// The single NotchClip surface: search, the complete filtered history, and a
/// full-content preview of the selection — all inside the notch shell.
struct PanelRootView: View {
    @Bindable var history: HistoryModel
    @Bindable var visualState: PanelVisualState
    var dragController: HistoryDragController
    var onSelect: () -> Void
    var onEscape: () -> Void
    var onBeginDrag: () -> Void
    var onEndDrag: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    private var motionReduced: Bool { reduceMotion || visualState.reduceMotion }

    private var selectedEntry: ClipboardEntry? {
        guard let id = history.selectedID else { return history.projection.visibleEntries.first }
        return history.projection.entry(id: id) ?? history.projection.visibleEntries.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            PanelRule(axis: .horizontal)

            if let storageError = history.storageError {
                PanelEmptyState(
                    title: "Storage unavailable",
                    systemImage: "externaldrive.badge.exclamationmark",
                    detail: storageError,
                    tone: NotchClipDesign.warning
                )
            } else {
                bodyContent
            }

            PanelRule(axis: .horizontal)

            PanelFooter(
                clipCount: history.projection.visibleEntries.count,
                isFiltered: !history.query.isEmpty || history.scope != .all,
                isPaused: history.isPaused,
                captureError: history.captureError,
                canPaste: selectedEntry != nil,
                onDismissError: history.clearCaptureError,
                onPaste: onSelect
            )
        }
        // The cap sits over the physical notch, so content starts below it.
        .padding(.top, max(6, visualState.capHeight + 4))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .environment(\.colorScheme, .dark)
        .opacity(visualState.contentOpacity)
        // The content settles into place with the shell: a slight scale from
        // the top plus a short rise, matching the island's inflate.
        .scaleEffect(
            motionReduced ? 1 : 0.97 + 0.03 * visualState.contentOpacity,
            anchor: .top
        )
        .offset(y: motionReduced ? 0 : CGFloat(1 - visualState.contentOpacity) * -6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchClip clipboard history")
        .onChange(of: visualState.focusRequestID) { _, _ in
            searchFocused = true
        }
        .onAppear { searchFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchClipDesign.tertiaryText)
                .accessibilityHidden(true)

            TextField("Search clipboard history", text: $history.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(NotchClipDesign.primaryText)
                .focused($searchFocused)
                .accessibilityLabel("Search clipboard history")

            if !history.query.isEmpty {
                Button {
                    history.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(NotchClipDesign.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            ScopePicker(scope: $history.scope, reduceMotion: motionReduced)
        }
        .padding(.horizontal, PanelLayout.horizontalPadding)
        .frame(height: PanelLayout.headerHeight)
    }

    // MARK: - Body

    @ViewBuilder
    private var bodyContent: some View {
        if history.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                clipList
                    .frame(width: PanelLayout.listWidth)

                PanelRule(axis: .vertical)

                ClipPreviewPane(
                    entry: selectedEntry,
                    preview: selectedEntry.flatMap { history.previewCache[$0.id] },
                    fullText: selectedEntry.flatMap { history.fullTextCache[$0.id] }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if history.hasNoHistory {
            PanelEmptyState(
                title: "Your clipboard is ready",
                systemImage: "rectangle.on.rectangle",
                detail: "Copy text, links, images, or files and they'll appear here.",
                tone: NotchClipDesign.secondaryText
            )
        } else if !history.query.isEmpty {
            PanelEmptyState(
                title: "No results",
                systemImage: "magnifyingglass",
                detail: "Nothing matches “\(history.query)”.",
                tone: NotchClipDesign.secondaryText
            )
        } else {
            PanelEmptyState(
                title: "No \(history.scope.title.lowercased()) clips",
                systemImage: history.scope.systemImage,
                detail: history.scope.emptyDescription,
                tone: NotchClipDesign.secondaryText
            )
        }
    }

    private var clipList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 1, pinnedViews: [.sectionHeaders]) {
                    ForEach(history.projection.sections) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                row(entry)
                                    .id(entry.id)
                            }
                        } header: {
                            SectionHeader(title: section.title)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }
            .scrollIndicators(.never)
            .onChange(of: history.selectedID) { _, id in
                guard let id, history.projection.contains(id: id) else { return }
                withAnimation(motionReduced ? nil : .easeOut(duration: 0.16)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityLabel("Clipboard items")
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        let preview = history.previewCache[entry.id]
        let model = EntryRowModel(
            entry: entry,
            linkTitle: preview?.linkTitle ?? history.linkPreviews?.results[entry.id]?.title
        )
        return ClipRow(
            entry: entry,
            row: model,
            preview: preview,
            isSelected: history.selectedID == entry.id,
            dragController: dragController,
            reduceMotion: motionReduced,
            onSelect: {
                history.selectedID = entry.id
                history.requestFullTextForSelection()
            },
            onPaste: {
                history.selectedID = entry.id
                onSelect()
            },
            onPin: { history.togglePin(id: entry.id) },
            onDelete: { history.delete(id: entry.id) },
            onAppear: { history.rowBecameVisible(entry) },
            onDisappear: { history.rowDidDisappear(entry.id) }
        )
    }
}

// MARK: - Scope picker

private struct ScopePicker: View {
    @Binding var scope: ClipScope
    let reduceMotion: Bool

    var body: some View {
        Menu {
            ForEach(ClipScope.allCases) { option in
                Button {
                    scope = option
                } label: {
                    Label(option.title, systemImage: option.systemImage)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(option.shortcutNumber)")),
                    modifiers: [.command]
                )
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: scope.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(scope.title)
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(NotchClipDesign.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(NotchClipDesign.surfaceStrong)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(NotchClipDesign.border, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Filter: \(scope.title)")
        .help("Filter clips (⌘1–⌘6)")
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(NotchClipDesign.tertiaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: PanelLayout.sectionHeaderHeight, alignment: .leading)
        .background(NotchClipDesign.shellTint.opacity(0.92))
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Row

private struct ClipRow: View {
    let entry: ClipboardEntry
    let row: EntryRowModel
    let preview: EntryPreview?
    let isSelected: Bool
    var dragController: HistoryDragController
    let reduceMotion: Bool
    var onSelect: () -> Void
    var onPaste: () -> Void
    var onPin: () -> Void
    var onDelete: () -> Void
    var onAppear: () -> Void
    var onDisappear: () -> Void

    @State private var isHovering = false

    private var previewImage: NSImage? {
        preview?.thumbnail ?? preview?.fileIcon
    }

    private var canDrag: Bool {
        !row.hasMissingFiles && entry.payloadRefs.contains { !$0.relativePath.isEmpty }
    }

    var body: some View {
        HStack(spacing: 9) {
            glyph

            VStack(alignment: .leading, spacing: 1) {
                // 13pt matches native menu items; the row should read like a
                // system control, not a custom widget.
                Text(row.primaryText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(NotchClipDesign.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let secondary = row.secondaryText {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(NotchClipDesign.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if row.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.secondaryText)
                    .accessibilityLabel("Pinned")
            }
            if row.hasMissingFiles {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.warning)
                    .accessibilityLabel("Missing file")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: PanelLayout.rowHeight)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background {
            // Neutral, menu-like selection: a light wash, no colour and no
            // border — the same language as macOS dark-mode menus and HUDs.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isSelected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isHovering)
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onPaste)
        .onTapGesture(perform: onSelect)
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
        .contextMenu {
            Button("Paste into Previous App", systemImage: "arrow.turn.down.left", action: onPaste)
            Button(row.isPinned ? "Unpin" : "Pin", systemImage: row.isPinned ? "pin.slash" : "pin", action: onPin)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Press Return to paste this item into the previous app")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Paste", onPaste)
        .accessibilityAction(named: row.isPinned ? "Unpin" : "Pin", onPin)
        .accessibilityAction(named: "Delete", onDelete)
    }

    private var glyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(NotchClipDesign.surfaceStrong)

            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: entry.primaryKind == .fileList ? .fit : .fill)
                    .padding(entry.primaryKind == .fileList ? 4 : 0)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: kindSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NotchClipDesign.secondaryText)
                    .accessibilityHidden(true)
            }

            // AppKit drag bridge sits above the artwork so its movement
            // threshold wins over the row's tap gestures.
            if canDrag {
                DragHandleView(
                    entry: entry,
                    previewImage: previewImage,
                    controller: dragController,
                    onActivate: onSelect,
                    onDoubleActivate: onPaste
                )
                .accessibilityHidden(true)
            }
        }
        .frame(width: PanelLayout.glyphSize, height: PanelLayout.glyphSize)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(NotchClipDesign.hairline, lineWidth: 0.5)
        }
        .help(canDrag ? "Drag into another app" : row.kindLabel)
    }

    private var background: Color {
        if isSelected { return Color.white.opacity(0.14) }
        if isHovering { return NotchClipDesign.surfaceHover }
        return .clear
    }

    private var kindSymbol: String { NotchClipSymbols.symbol(for: row.kind) }

    private var accessibilitySummary: String {
        var parts = [row.primaryText, row.kindLabel]
        if row.isPinned { parts.append("Pinned") }
        if row.hasMissingFiles { parts.append("Missing file") }
        if let secondary = row.secondaryText { parts.append(secondary) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Preview pane

private struct ClipPreviewPane: View {
    let entry: ClipboardEntry?
    let preview: EntryPreview?
    let fullText: String?

    var body: some View {
        if let entry {
            content(for: entry)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 22))
                    .foregroundStyle(NotchClipDesign.tertiaryText)
                Text("Select a clip to preview it")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchClipDesign.tertiaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    private func content(for entry: ClipboardEntry) -> some View {
        let row = EntryRowModel(entry: entry, linkTitle: preview?.linkTitle)
        return VStack(alignment: .leading, spacing: 0) {
            header(for: entry, row: row)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    body(for: entry, row: row)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)

            footer(for: entry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of selected clip")
    }

    private func header(for entry: ClipboardEntry, row: EntryRowModel) -> some View {
        HStack(spacing: 7) {
            Image(systemName: NotchClipSymbols.symbol(for: row.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchClipDesign.secondaryText)
            Text(row.kindLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchClipDesign.primaryText)

            Spacer(minLength: 8)

            Text(EntryPresentation.sourceLabel(from: entry.source) ?? "Unknown")
                .font(.system(size: 10.5))
                .foregroundStyle(NotchClipDesign.tertiaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func body(for entry: ClipboardEntry, row: EntryRowModel) -> some View {
        switch entry.primaryKind {
        case .image:
            if let image = preview?.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Image preview")
            } else {
                placeholder(systemImage: "photo", title: "Image")
            }

        case .fileList:
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(row.originalPaths.prefix(12).enumerated()), id: \.offset) { _, path in
                    HStack(spacing: 7) {
                        Image(systemName: "doc")
                            .font(.system(size: 10))
                            .foregroundStyle(NotchClipDesign.tertiaryText)
                        Text(path)
                            .font(.system(size: 11))
                            .foregroundStyle(NotchClipDesign.secondaryText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                if row.originalPaths.count > 12 {
                    Text("\(row.originalPaths.count - 12) more files")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NotchClipDesign.tertiaryText)
                }
                if row.hasMissingFiles {
                    Label("One or more original files are missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NotchClipDesign.warning)
                }
            }

        default:
            if let image = preview?.thumbnail, entry.primaryKind == .url {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Link preview image")
            }
            // The complete retained text, with real line breaks. `previewText`
            // is collapsed and capped at 200 characters, so it is only a
            // fallback for the brief moment before the payload load lands.
            Text(fullText ?? entry.previewText)
                .font(.system(size: 12, design: textDesign(for: entry)))
                .foregroundStyle(NotchClipDesign.primaryText.opacity(0.92))
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityLabel("Clip contents")
        }
    }

    private func footer(for entry: ClipboardEntry) -> some View {
        let bytes = entry.payloadRefs.reduce(0) { $0 + $1.byteCount }
        return HStack(spacing: 10) {
            Text(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))
            Spacer(minLength: 8)
            Text(EntryPresentation.byteCountString(bytes))
        }
        .font(.system(size: 10.5))
        .foregroundStyle(NotchClipDesign.tertiaryText)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .accessibilityElement(children: .combine)
    }

    /// Monospace anything that reads like code or markup so structure survives.
    private func textDesign(for entry: ClipboardEntry) -> Font.Design {
        entry.primaryKind == .html ? .monospaced : .default
    }

    private func placeholder(systemImage: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(NotchClipDesign.tertiaryText)
        .frame(maxWidth: .infinity, minHeight: 120)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Footer

private struct PanelFooter: View {
    let clipCount: Int
    let isFiltered: Bool
    let isPaused: Bool
    let captureError: String?
    let canPaste: Bool
    let onDismissError: () -> Void
    let onPaste: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let captureError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.warning)
                    .accessibilityHidden(true)
                Text(captureError)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchClipDesign.secondaryText)
                    .lineLimit(1)
                    .help(captureError)
                Button("Dismiss", action: onDismissError)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotchClipDesign.secondaryText)
            } else if isPaused {
                Label("Capture paused", systemImage: "pause.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotchClipDesign.warning.opacity(0.86))
            } else {
                Text(countLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchClipDesign.tertiaryText)
            }

            Spacer(minLength: 8)

            PanelHint(key: "↑↓", label: "Move")
            PanelHint(key: "↵", label: "Paste")
            PanelHint(key: "⌘1–6", label: "Filter")
        }
        .padding(.horizontal, PanelLayout.footerPadding)
        .frame(height: PanelLayout.footerHeight)
        .accessibilityElement(children: .contain)
    }

    private var countLabel: String {
        let noun = clipCount == 1 ? "clip" : "clips"
        return isFiltered ? "\(clipCount) \(noun) shown" : "\(clipCount) \(noun)"
    }
}

private struct PanelHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            NotchClipKeycap(key)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(NotchClipDesign.tertiaryText)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key), \(label)")
    }
}

// MARK: - Shared bits

/// Barely-there separator. SwiftUI's `Divider` draws the system separator
/// colour beneath any overlay, which reads far too bright on true black —
/// this owns its whole pixel instead.
private struct PanelRule: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis

    var body: some View {
        // 4.5% proved too faint, the system separator too bright; 7% sits on
        // the same ladder as the other hairlines (6.5–7.5%).
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
            .accessibilityHidden(true)
    }
}

private struct PanelEmptyState: View {
    let title: String
    let systemImage: String
    let detail: String
    let tone: Color

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(tone)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NotchClipDesign.primaryText)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(NotchClipDesign.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

enum NotchClipSymbols {
    static func symbol(for kind: ClipboardContentKind) -> String {
        switch kind {
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
}
