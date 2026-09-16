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
    /// The ⇧⏎ paste: strips formatting, or keeps it when the preference already strips.
    var onSelectAlternate: () -> Void
    var onEscape: () -> Void
    var onBeginDrag: () -> Void
    var onEndDrag: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    private var motionReduced: Bool { reduceMotion || visualState.reduceMotion }

    /// Depth of field the content resolves out of as it rides the shell open,
    /// and softens back into on the way closed. Small: at 6 pt the text is
    /// unreadable for the first frames and crisp well before the shell stops,
    /// which reads as focusing rather than as an effect.
    private static let maximumContentBlur: CGFloat = 6

    /// Tied to the opacity so it needs no timer of its own — the same
    /// `withAnimation` that fades the content drives it, in both directions.
    /// Gated by the same accessibility settings that gate the geometry: a
    /// reduced presentation gets the plain fade and nothing else.
    private var contentBlurRadius: CGFloat {
        guard !motionReduced, !visualState.reduceTransparency else { return 0 }
        return Self.maximumContentBlur * CGFloat(1 - visualState.contentOpacity)
    }

    /// ⇧⏎ pastes with formatting once the preference makes plain the default.
    private var alternatePasteTitle: String {
        history.preferences.alwaysPastePlainText ? "Paste with Formatting" : "Paste as Plain Text"
    }

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
                selectedIsPinned: selectedEntry?.isPinned ?? false,
                alternatePasteTitle: alternatePasteTitle,
                onDismissError: history.clearCaptureError,
                onPaste: onSelect,
                onPasteAlternate: onSelectAlternate,
                onPin: {
                    guard let entry = selectedEntry else { return }
                    history.togglePin(id: entry.id)
                },
                onCopy: {
                    guard let entry = selectedEntry else { return }
                    history.paste(entryID: entry.id) { written, error in
                        if let error {
                            history.setCaptureError(error.localizedDescription)
                        } else if written == 0 {
                            history.setCaptureError("Could not copy this item to the clipboard.")
                        }
                    }
                },
                onDelete: {
                    guard let entry = selectedEntry else { return }
                    history.delete(id: entry.id)
                }
            )
        }
        // The cap sits over the physical notch, so content starts below it.
        .padding(.top, max(6, visualState.capHeight + 4))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .environment(\.colorScheme, .dark)
        // Sharpens as it arrives, which is what lets the fade start while the
        // shell is still small without the content reading as a pasted-on
        // block. The scale and the rise that used to live here are gone: the
        // content's motion is now a layer transform driven by the shell's own
        // progress (see `NotchChromeView.applyContentTransform`), so repeating
        // them here would apply the movement twice.
        .blur(radius: contentBlurRadius)
        .opacity(visualState.contentOpacity)
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
                    fullText: selectedEntry.flatMap { history.fullTextCache[$0.id] },
                    alternatePasteTitle: alternatePasteTitle,
                    onPasteAlternate: onSelectAlternate,
                    onPin: {
                        guard let entry = selectedEntry else { return }
                        history.togglePin(id: entry.id)
                    },
                    onCopy: {
                        guard let entry = selectedEntry else { return }
                        // Copy without dismissing: writes the exact entry back to
                        // the clipboard and leaves the panel open. Self-write
                        // suppression keeps it from re-capturing.
                        history.paste(entryID: entry.id) { written, error in
                            if let error {
                                history.setCaptureError(error.localizedDescription)
                            } else if written == 0 {
                                history.setCaptureError("Could not copy this item to the clipboard.")
                            }
                        }
                    },
                    onDelete: {
                        guard let entry = selectedEntry else { return }
                        history.delete(id: entry.id)
                    }
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
            alternatePasteTitle: alternatePasteTitle,
            onSelect: {
                history.selectedID = entry.id
                history.requestFullTextForSelection()
            },
            onPaste: {
                history.selectedID = entry.id
                onSelect()
            },
            onPasteAlternate: {
                history.selectedID = entry.id
                onSelectAlternate()
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
                // ⌥, not ⌘ — ⌘1–⌘9 pastes the Nth visible row.
                .keyboardShortcut(
                    KeyEquivalent(Character("\(option.shortcutNumber)")),
                    modifiers: [.option]
                )
            }
        } label: {
            // Styled like a native pop-up button: title plus the stacked
            // chevrons macOS uses everywhere for "this is a menu".
            HStack(spacing: 6) {
                Text(scope.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(NotchClipDesign.primaryText.opacity(0.85))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.secondaryText)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(NotchClipDesign.surfaceStrong)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Filter: \(scope.title)")
        .help("Filter clips (⌥1–⌥6)")
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
    let alternatePasteTitle: String
    var onSelect: () -> Void
    var onPaste: () -> Void
    var onPasteAlternate: () -> Void
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
            Button(alternatePasteTitle, systemImage: "textformat", action: onPasteAlternate)
            Button(row.isPinned ? "Unpin" : "Pin", systemImage: row.isPinned ? "pin.slash" : "pin", action: onPin)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Press Return to paste this item into the previous app")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Paste", onPaste)
        .accessibilityAction(named: alternatePasteTitle, onPasteAlternate)
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
    var alternatePasteTitle: String = "Paste as Plain Text"
    var onPasteAlternate: () -> Void = {}
    var onPin: () -> Void = {}
    var onCopy: () -> Void = {}
    var onDelete: () -> Void = {}

    /// Momentary checkmark after Copy; reset when the selection changes.
    @State private var showCopied = false

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
        .onChange(of: entry.id) { _, _ in showCopied = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of selected clip")
    }

    /// Kind on the left; the selected clip's actions on the right. The source
    /// app lives in the meta strip below, so this row is about *doing*.
    private func header(for entry: ClipboardEntry, row: EntryRowModel) -> some View {
        HStack(spacing: 7) {
            Image(systemName: NotchClipSymbols.symbol(for: row.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchClipDesign.secondaryText)
                .accessibilityHidden(true)
            Text(row.kindLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchClipDesign.primaryText)

            Spacer(minLength: 8)

            PaneActionButton(
                systemImage: entry.isPinned ? "pin.slash" : "pin",
                label: entry.isPinned ? "Unpin" : "Pin",
                shortcutHint: "⌘P",
                action: onPin
            )
            PaneActionButton(
                systemImage: showCopied ? "checkmark" : "doc.on.doc",
                label: showCopied ? "Copied" : "Copy",
                tint: showCopied ? NotchClipDesign.success : nil,
                shortcutHint: nil,
                action: {
                    onCopy()
                    withAnimation(.easeOut(duration: 0.12)) { showCopied = true }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1200))
                        withAnimation(.easeOut(duration: 0.2)) { showCopied = false }
                    }
                }
            )
            // Sits next to Delete, not next to Copy: like Delete and unlike the
            // buttons before it, this one closes the panel and acts elsewhere.
            PaneActionButton(
                systemImage: "textformat",
                label: alternatePasteTitle,
                shortcutHint: "⇧↵",
                action: onPasteAlternate
            )
            PaneActionButton(
                systemImage: "trash",
                label: "Delete",
                shortcutHint: "⌘⌫",
                action: onDelete
            )
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .frame(height: 34)
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
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 140)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(NotchClipDesign.surfaceStrong)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Link preview image")
            }
            if entry.primaryKind == .url,
               let title = preview?.linkTitle,
               !title.isEmpty {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.primaryText)
                    .lineLimit(2)
                    .accessibilityLabel("Link title: \(title)")
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
        // Source moved here from the pane header when actions took its place.
        let parts = [
            EntryPresentation.sourceLabel(from: entry.source),
            entry.updatedAt.formatted(date: .abbreviated, time: .shortened)
        ].compactMap { $0 }
        return HStack(spacing: 10) {
            Text(parts.joined(separator: " · "))
                .lineLimit(1)
                .truncationMode(.middle)
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

/// Small icon button for the preview pane's action row.
private struct PaneActionButton: View {
    let systemImage: String
    let label: String
    var tint: Color? = nil
    var shortcutHint: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    tint ?? (isHovering ? NotchClipDesign.primaryText : NotchClipDesign.secondaryText)
                )
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? NotchClipDesign.surfaceHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.10), value: isHovering)
        .help(shortcutHint.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
    }
}

// MARK: - Footer

private struct PanelFooter: View {
    let clipCount: Int
    let isFiltered: Bool
    let isPaused: Bool
    let captureError: String?
    let canPaste: Bool
    var selectedIsPinned: Bool = false
    var alternatePasteTitle: String = "Paste as Plain Text"
    let onDismissError: () -> Void
    let onPaste: () -> Void
    var onPasteAlternate: () -> Void = {}
    var onPin: () -> Void = {}
    var onCopy: () -> Void = {}
    var onDelete: () -> Void = {}

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
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            PanelHint(key: "↑↓", label: "Move")
            PanelHint(key: "↵", label: "Paste")
            actionsMenu
        }
        .padding(.horizontal, PanelLayout.footerPadding)
        .frame(height: PanelLayout.footerHeight)
        .accessibilityElement(children: .contain)
    }

    /// Every action on the selected clip, with its shortcut, in one labeled
    /// place — the icon-only pane buttons were too easy to miss.
    private var actionsMenu: some View {
        Menu {
            Button("Paste into Previous App", systemImage: "arrow.turn.down.left", action: onPaste)
                .disabled(!canPaste)
            Button(alternatePasteTitle, systemImage: "textformat", action: onPasteAlternate)
                .disabled(!canPaste)
            Button(
                selectedIsPinned ? "Unpin" : "Pin",
                systemImage: selectedIsPinned ? "pin.slash" : "pin",
                action: onPin
            )
            .disabled(!canPaste)
            Button("Copy to Clipboard", systemImage: "doc.on.doc", action: onCopy)
                .disabled(!canPaste)

            Divider()

            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                .disabled(!canPaste)
        } label: {
            HStack(spacing: 5) {
                Text("Actions")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(NotchClipDesign.primaryText.opacity(0.85))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(NotchClipDesign.secondaryText)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(NotchClipDesign.surfaceStrong)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for the selected clip")
        .help("Paste options, pin, copy, or delete")
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
