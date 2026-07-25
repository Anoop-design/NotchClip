import AppKit
import SwiftUI
import NotchClipCore

enum ClipboardLibraryLayout {
    static let defaultWidth: CGFloat = 960
    static let defaultHeight: CGFloat = 620
    static let minimumWidth: CGFloat = 820
    static let minimumHeight: CGFloat = 520

    static let sidebarMinimumWidth: CGFloat = 148
    static let sidebarIdealWidth: CGFloat = 160
    static let sidebarMaximumWidth: CGFloat = 184
    static let resultsMinimumWidth: CGFloat = 330
    static let resultsIdealWidth: CGFloat = 370
    static let resultsMaximumWidth: CGFloat = 430
    static let inspectorMinimumWidth: CGFloat = 300
    static let inspectorIdealWidth: CGFloat = 390
}

/// Complete, searchable clipboard history presented as a focused command surface.
/// Search and keyboard navigation remain primary; the inspector adds context without
/// making the quick notch shelf carry the entire archive.
struct ClipboardLibraryRootView: View {
    @Bindable var history: HistoryModel
    @Bindable var state: ClipboardLibraryViewState
    var dragController: HistoryDragController
    var onPaste: (ClipboardEntry) -> Void
    var onQuickLook: (ClipboardEntry) -> Void
    var onFocusSearch: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var projection: ClipboardLibraryProjection

    init(
        history: HistoryModel,
        state: ClipboardLibraryViewState,
        dragController: HistoryDragController,
        onPaste: @escaping (ClipboardEntry) -> Void,
        onQuickLook: @escaping (ClipboardEntry) -> Void,
        onFocusSearch: @escaping () -> Void
    ) {
        self.history = history
        self.state = state
        self.dragController = dragController
        self.onPaste = onPaste
        self.onQuickLook = onQuickLook
        self.onFocusSearch = onFocusSearch
        _projection = State(
            initialValue: ClipboardLibraryProjection.make(
                entries: history.entries,
                query: state.appliedQuery,
                scope: state.scope
            )
        )
    }

    private var visibleEntries: [ClipboardEntry] {
        projection.visibleEntries
    }

    private var selectedEntry: ClipboardEntry? {
        if let selectedID = state.selectedID,
           let selected = projection.entry(id: selectedID) {
            return selected
        }
        return visibleEntries.first
    }

    private var projectionInput: ClipboardLibraryProjectionInput {
        ClipboardLibraryProjectionInput(
            entriesRevision: history.entriesRevision,
            query: state.appliedQuery,
            scope: state.scope
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            libraryBody
            Divider()
            actionFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(
            minWidth: ClipboardLibraryLayout.minimumWidth,
            minHeight: ClipboardLibraryLayout.minimumHeight
        )
        .onAppear {
            reconcileSelection(in: projection)
        }
        .onChange(of: projectionInput) { _, input in
            let updatedProjection = input.makeProjection(entries: history.entries)
            projection = updatedProjection
            reconcileSelection(in: updatedProjection)
        }
        .task(id: state.query) {
            do {
                try await Task.sleep(for: .milliseconds(140))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            state.appliedQuery = state.query
        }
        .alert(
            "Delete Clipboard Item?",
            isPresented: Binding(
                get: { state.pendingDeletionID != nil },
                set: { if !$0 { state.pendingDeletionID = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                state.pendingDeletionID = nil
            }
            Button("Delete", role: .destructive) {
                if let id = state.pendingDeletionID {
                    history.delete(id: id)
                }
                state.pendingDeletionID = nil
            }
        } message: {
            Text("This removes the item and its retained clipboard data. This action cannot be undone.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchClip clipboard library")
    }

    // MARK: - Results and inspector

    @ViewBuilder
    private var libraryBody: some View {
        if let storageError = history.storageError {
            unavailableState(
                title: "Clipboard Storage Unavailable",
                systemImage: "externaldrive.badge.exclamationmark",
                description: storageError
            )
        } else {
            HSplitView {
                scopeSidebar
                    .frame(
                        minWidth: ClipboardLibraryLayout.sidebarMinimumWidth,
                        idealWidth: ClipboardLibraryLayout.sidebarIdealWidth,
                        maxWidth: ClipboardLibraryLayout.sidebarMaximumWidth
                    )

                resultsPane
                    .frame(
                        minWidth: ClipboardLibraryLayout.resultsMinimumWidth,
                        idealWidth: ClipboardLibraryLayout.resultsIdealWidth,
                        maxWidth: ClipboardLibraryLayout.resultsMaximumWidth
                    )

                inspectorPane
                    .frame(
                        minWidth: ClipboardLibraryLayout.inspectorMinimumWidth,
                        idealWidth: ClipboardLibraryLayout.inspectorIdealWidth,
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
            }
        }
    }

    private var scopeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LIBRARY")
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.bottom, 8)
                .accessibilityLabel("Library")

            VStack(spacing: 2) {
                ForEach(ClipboardLibraryScope.allCases) { scope in
                    ClipboardLibraryScopeRow(
                        scope: scope,
                        isSelected: state.scope == scope
                    ) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                            state.scope = scope
                        }
                    }
                }
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 9)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            ClipboardLibrarySidebarMaterial()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clipboard filters")
    }

    private var resultsPane: some View {
        Group {
            if visibleEntries.isEmpty {
                emptyState
            } else {
                historyResults
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var historyResults: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(projection.displaySections) { displaySection in
                        Section {
                            ForEach(displaySection.entries) { entry in
                                libraryRow(entry)
                                    .id(entry.id)
                            }
                        } header: {
                            sectionHeader(displaySection.title)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: state.selectedID) { _, selectedID in
                guard let selectedID,
                      projection.contains(id: selectedID) else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
            .accessibilityLabel("Clipboard items")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.45)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.96))
        .accessibilityAddTraits(.isHeader)
    }

    private func libraryRow(_ entry: ClipboardEntry) -> some View {
        let preview = history.previewCache[entry.id]
        let row = EntryRowModel(
            entry: entry,
            linkTitle: preview?.linkTitle ?? history.linkPreviews?.results[entry.id]?.title
        )

        return ClipboardLibraryRow(
            entry: entry,
            row: row,
            preview: preview,
            dragController: dragController,
            isSelected: state.selectedID == entry.id,
            onSelect: { state.selectedID = entry.id },
            onPaste: {
                state.selectedID = entry.id
                onPaste(entry)
            },
            onPin: { history.togglePin(id: entry.id) },
            onDelete: { state.pendingDeletionID = entry.id },
            onQuickLook: {
                state.selectedID = entry.id
                onQuickLook(entry)
            },
            onAppear: { history.rowBecameVisible(entry) },
            onDisappear: { history.rowDidDisappear(entry.id) }
        )
    }

    @ViewBuilder
    private var inspectorPane: some View {
        if let selectedEntry {
            let preview = history.previewCache[selectedEntry.id]
            let row = EntryRowModel(
                entry: selectedEntry,
                linkTitle: preview?.linkTitle ?? history.linkPreviews?.results[selectedEntry.id]?.title
            )

            ClipboardLibraryInspector(entry: selectedEntry, row: row, preview: preview)
                .id(selectedEntry.id)
                .transition(.opacity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("Select a clip to preview it")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Empty and error states

    @ViewBuilder
    private var emptyState: some View {
        if !state.appliedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            compactUnavailableState(
                title: "No Results",
                systemImage: "magnifyingglass",
                description: "Nothing matches “\(state.appliedQuery)”."
            ) {
                Button("Clear Search") {
                    state.query = ""
                    state.appliedQuery = ""
                    onFocusSearch()
                }
                .buttonStyle(.link)
            }
        } else if history.entries.isEmpty {
            compactUnavailableState(
                title: "Your Clipboard Is Ready",
                systemImage: "rectangle.on.rectangle.angled",
                description: "Copy text, links, images, or files and they’ll appear here."
            ) { EmptyView() }
        } else {
            compactUnavailableState(
                title: "No \(state.scope.title)",
                systemImage: state.scope.systemImage,
                description: scopeEmptyDescription
            ) {
                Button("Show All Items") {
                    state.scope = .all
                }
                .buttonStyle(.link)
            }
        }
    }

    private func compactUnavailableState<Actions: View>(
        title: String,
        systemImage: String,
        description: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func unavailableState(
        title: String,
        systemImage: String,
        description: String
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        }
    }

    // MARK: - Contextual footer

    private var actionFooter: some View {
        HStack(spacing: 8) {
            footerStatus

            Spacer(minLength: 12)

            Button("Paste", systemImage: "arrow.turn.down.left") {
                guard let selectedEntry else { return }
                onPaste(selectedEntry)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(selectedEntry == nil)
            .keyboardShortcut(.defaultAction)
            .help("Paste into the previous app (Return)")

            actionsMenu
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var footerStatus: some View {
        if let captureError = history.captureError {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(captureError)
                    .lineLimit(1)
                    .help(captureError)
                Button("Dismiss") {
                    history.clearCaptureError()
                }
                .buttonStyle(.link)
            }
            .accessibilityElement(children: .contain)
        } else if history.isPaused {
            Label("Capture paused", systemImage: "pause.fill")
                .foregroundStyle(.orange)
        } else {
            Label(resultCountLabel, systemImage: "rectangle.on.rectangle.angled")
        }
    }

    private var actionsMenu: some View {
        Menu {
            if let selectedEntry {
                Button("Quick Look", systemImage: "eye") {
                    onQuickLook(selectedEntry)
                }
                .disabled(!canQuickLook(selectedEntry))
                Button(
                    selectedEntry.isPinned ? "Unpin" : "Pin",
                    systemImage: selectedEntry.isPinned ? "pin.slash" : "pin"
                ) {
                    history.togglePin(id: selectedEntry.id)
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    state.pendingDeletionID = selectedEntry.id
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(selectedEntry == nil)
        .keyboardShortcut("k", modifiers: [.command])
        .accessibilityLabel("Clipboard actions")
        .help("Show actions (Command-K)")
    }

    private func canQuickLook(_ entry: ClipboardEntry) -> Bool {
        !entry.hasMissingFiles() && (entry.primaryKind == .image || entry.primaryKind == .fileList)
    }

    private func reconcileSelection(in projection: ClipboardLibraryProjection) {
        if let selectedID = state.selectedID, projection.contains(id: selectedID) {
            return
        }
        state.selectedID = projection.visibleEntries.first?.id
    }

    private var resultCountLabel: String {
        let count = visibleEntries.count
        if state.appliedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return count == 1 ? "1 clip" : "\(count) clips"
        }
        return count == 1 ? "1 result" : "\(count) results"
    }

    private var scopeEmptyDescription: String {
        switch state.scope {
        case .all:
            return "Copy something and it will appear here."
        case .pinned:
            return "Pin a clip to keep it easy to reach."
        case .text:
            return "Copied text, rich text, and HTML will appear here."
        case .links:
            return "Copied web links will appear here."
        case .images:
            return "Copied images will appear here."
        case .files:
            return "Files copied from Finder will appear here."
        }
    }
}

private struct ClipboardLibraryDisplaySection: Identifiable {
    let id: String
    let title: String
    let entries: [ClipboardEntry]
}

/// A single filtered, sorted, and sectioned snapshot for the current library inputs.
/// Keeping it in view state avoids rebuilding the complete history projection every
/// time selection, hover, preview loading, or another unrelated observable value changes.
private struct ClipboardLibraryProjection {
    let visibleEntries: [ClipboardEntry]
    let visibleIDs: Set<UUID>
    let displaySections: [ClipboardLibraryDisplaySection]

    static func make(
        entries: [ClipboardEntry],
        query: String,
        scope: ClipboardLibraryScope,
        calendar: Calendar = .current
    ) -> ClipboardLibraryProjection {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchNeedle = trimmedQuery.lowercased()
        let sourceNeedle = trimmedQuery.localizedLowercase

        let matchingEntries = entries.filter { entry in
            guard scope.includes(entry) else { return false }
            guard !trimmedQuery.isEmpty else { return true }
            return entry.searchText.lowercased().contains(searchNeedle)
                || entry.previewText.lowercased().contains(searchNeedle)
                || entry.source.applicationName?.localizedLowercase.contains(sourceNeedle) == true
                || entry.source.bundleIdentifier?.localizedLowercase.contains(sourceNeedle) == true
        }
        let visibleEntries = ClipboardSorting.pinnedFirst(matchingEntries)

        var pinned: [ClipboardEntry] = []
        var today: [ClipboardEntry] = []
        var yesterday: [ClipboardEntry] = []
        var earlier: [ClipboardEntry] = []
        var visibleIDs: Set<UUID> = []
        visibleIDs.reserveCapacity(visibleEntries.count)

        for entry in visibleEntries {
            visibleIDs.insert(entry.id)
            if entry.isPinned {
                pinned.append(entry)
            } else if calendar.isDateInToday(entry.updatedAt) {
                today.append(entry)
            } else if calendar.isDateInYesterday(entry.updatedAt) {
                yesterday.append(entry)
            } else {
                earlier.append(entry)
            }
        }

        var displaySections: [ClipboardLibraryDisplaySection] = []
        displaySections.reserveCapacity(4)
        if !pinned.isEmpty {
            displaySections.append(.init(id: "pinned", title: "Pinned", entries: pinned))
        }
        if !today.isEmpty {
            displaySections.append(.init(id: "today", title: "Today", entries: today))
        }
        if !yesterday.isEmpty {
            displaySections.append(.init(id: "yesterday", title: "Yesterday", entries: yesterday))
        }
        if !earlier.isEmpty {
            displaySections.append(.init(id: "earlier", title: "Earlier", entries: earlier))
        }

        return ClipboardLibraryProjection(
            visibleEntries: visibleEntries,
            visibleIDs: visibleIDs,
            displaySections: displaySections
        )
    }

    func contains(id: UUID) -> Bool {
        visibleIDs.contains(id)
    }

    func entry(id: UUID) -> ClipboardEntry? {
        visibleEntries.first(where: { $0.id == id })
    }
}

private struct ClipboardLibraryProjectionInput: Equatable {
    let entriesRevision: UInt64
    let query: String
    let scope: ClipboardLibraryScope

    func makeProjection(entries: [ClipboardEntry]) -> ClipboardLibraryProjection {
        ClipboardLibraryProjection.make(entries: entries, query: query, scope: scope)
    }
}

private struct ClipboardLibraryScopeRow: View {
    let scope: ClipboardLibraryScope
    let isSelected: Bool
    var onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: scope.systemImage)
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 16)

                Text(scope.title)
                    .font(.body.weight(isSelected ? .medium : .regular))
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .foregroundStyle(isSelected ? selectedForeground : Color.primary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isSelected
                            ? selectedBackground
                            : (isHovering ? hoverBackground : Color.clear)
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(scope.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectedBackground: Color {
        Color(nsColor: .selectedContentBackgroundColor)
    }

    private var selectedForeground: Color {
        Color(nsColor: .selectedControlTextColor)
    }

    private var hoverBackground: Color {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.55)
    }
}

private struct ClipboardLibraryRow: View {
    let entry: ClipboardEntry
    let row: EntryRowModel
    let preview: EntryPreview?
    var dragController: HistoryDragController
    let isSelected: Bool
    var onSelect: () -> Void
    var onPaste: () -> Void
    var onPin: () -> Void
    var onDelete: () -> Void
    var onQuickLook: () -> Void
    var onAppear: () -> Void
    var onDisappear: () -> Void

    @State private var isHovering = false

    private var previewImage: NSImage? {
        preview?.thumbnail ?? preview?.fileIcon
    }

    private var canDrag: Bool {
        !row.hasMissingFiles && entry.payloadRefs.contains { !$0.relativePath.isEmpty }
    }

    private var canQuickLook: Bool {
        !row.hasMissingFiles && (entry.primaryKind == .image || entry.primaryKind == .fileList)
    }

    var body: some View {
        HStack(spacing: 10) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.primaryText)
                        .font(.body.weight(.medium))
                        .foregroundStyle(primaryForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if row.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(secondaryForeground)
                            .accessibilityLabel("Pinned")
                    }
                }

                if let secondary = row.secondaryText {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(secondaryForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if row.hasMissingFiles {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Missing file")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                        ? selectedBackground
                        : (isHovering ? hoverBackground : Color.clear)
                )
        }
        .onTapGesture(count: 2) {
            onPaste()
        }
        .onTapGesture {
            onSelect()
        }
        .onHover { isHovering = $0 }
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
        .contextMenu {
            Button("Paste into Previous App", systemImage: "arrow.turn.down.left", action: onPaste)
            Button(row.isPinned ? "Unpin" : "Pin", systemImage: row.isPinned ? "pin.slash" : "pin", action: onPin)
            Button("Quick Look", systemImage: "eye", action: onQuickLook)
                .disabled(!canQuickLook)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            Button("Paste", action: onPaste)
            Button(row.isPinned ? "Unpin" : "Pin", action: onPin)
            if canQuickLook {
                Button("Quick Look", action: onQuickLook)
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))

            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: entry.primaryKind == .fileList ? .fit : .fill)
                    .padding(entry.primaryKind == .fileList ? 6 : 0)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: kindSymbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(secondaryForeground)
                    .accessibilityHidden(true)
            }

            if canDrag {
                DragHandleView(
                    entry: entry,
                    previewImage: previewImage,
                    controller: dragController,
                    onActivate: onSelect,
                    onDoubleActivate: onPaste
                )
                .accessibilityLabel("Drag \(row.primaryText)")
                .accessibilityHint("Drag this clipboard item into another app")
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .help(canDrag ? "Drag into another app" : row.kindLabel)
    }

    private var selectedBackground: Color {
        Color(nsColor: .selectedContentBackgroundColor)
    }

    private var hoverBackground: Color {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
    }

    private var primaryForeground: Color {
        isSelected ? Color(nsColor: .selectedControlTextColor) : Color.primary
    }

    private var secondaryForeground: Color {
        isSelected ? Color(nsColor: .selectedControlTextColor).opacity(0.78) : Color.secondary
    }

    private var accessibilityHint: String {
        if canDrag {
            return "Press Return to paste, or drag this item into another app."
        }
        return "Press Return to paste this item."
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
        if let secondary = row.secondaryText { parts.append(secondary) }
        return parts.joined(separator: ", ")
    }
}

private struct ClipboardLibraryInspector: View {
    let entry: ClipboardEntry
    let row: EntryRowModel
    let preview: EntryPreview?

    private var previewImage: NSImage? {
        preview?.thumbnail ?? preview?.fileIcon
    }

    private var retainedByteCount: Int {
        entry.payloadRefs.reduce(0) { $0 + $1.byteCount }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                inspectorHeader
                previewSurface
                metadata
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected clipboard item details")
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(row.kindLabel, systemImage: kindSymbol)
                    .font(.headline)

                Spacer(minLength: 8)

                if row.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
            }

            Text(inspectorSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var previewSurface: some View {
        switch entry.primaryKind {
        case .image:
            mediaSurface {
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 240)
                        .accessibilityLabel("Image preview")
                } else {
                    previewPlaceholder(systemImage: "photo", title: "Image")
                }
            }
        case .fileList:
            mediaSurface {
                filePreview
            }
        case .url:
            mediaSurface {
                linkPreview
            }
        default:
            Text(entry.previewText.isEmpty ? row.primaryText : entry.previewText)
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func mediaSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
    }

    @ViewBuilder
    private var linkPreview: some View {
        if let previewImage {
            Image(nsImage: previewImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityLabel("Link preview image")
        }

        Text(preview?.linkTitle ?? row.primaryText)
            .font(.headline)
            .textSelection(.enabled)

        Text(entry.previewText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    private var filePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
            }

            ForEach(Array(row.originalPaths.prefix(8).enumerated()), id: \.offset) { _, path in
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            if row.originalPaths.count > 8 {
                Text("\(row.originalPaths.count - 8) more files")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if row.hasMissingFiles {
                Label("One or more original files are missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func previewPlaceholder(systemImage: String, title: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.title)
            Text(title)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 140)
        .accessibilityElement(children: .combine)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 0) {
                metadataRow("Application", value: EntryPresentation.sourceLabel(from: entry.source) ?? "Unknown")
                Divider()
                metadataRow(
                    "Copied",
                    value: entry.updatedAt.formatted(date: .abbreviated, time: .shortened)
                )
                Divider()
                metadataRow("Content Type", value: row.kindLabel)
                Divider()
                metadataRow("Retained Size", value: EntryPresentation.byteCountString(retainedByteCount))
            }
        }
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .frame(minHeight: 30)
        .accessibilityElement(children: .combine)
    }

    private var inspectorSubtitle: String {
        let source = EntryPresentation.sourceLabel(from: entry.source) ?? "Unknown application"
        let copied = entry.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(source) · \(copied)"
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
}

/// Uses the same sidebar material as native macOS split-view applications while
/// inheriting the user's appearance and contrast settings.
private struct ClipboardLibrarySidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
    }
}
