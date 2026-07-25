import AppKit
import Observation
import SwiftUI
import NotchClipCore

/// The durable scopes shown in the clipboard library sidebar.
enum ClipboardLibraryScope: String, CaseIterable, Identifiable, Hashable {
    case all
    case pinned
    case text
    case links
    case images
    case files

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "All Items"
        case .pinned: return "Pinned"
        case .text: return "Text"
        case .links: return "Links"
        case .images: return "Images"
        case .files: return "Files"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .pinned: return "pin"
        case .text: return "text.alignleft"
        case .links: return "link"
        case .images: return "photo"
        case .files: return "folder"
        }
    }

    func includes(_ entry: ClipboardEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .pinned:
            return entry.isPinned
        case .text:
            return [.plainText, .rtf, .html].contains(entry.primaryKind)
        case .links:
            return entry.primaryKind == .url
        case .images:
            return entry.primaryKind == .image
        case .files:
            return entry.primaryKind == .fileList
        }
    }
}

/// View-owned state for the full library. It deliberately does not reuse
/// `HistoryModel.query`, so opening the library never changes the compact notch.
@MainActor
@Observable
final class ClipboardLibraryViewState {
    var scope: ClipboardLibraryScope = .all
    var query: String = ""
    /// Debounced projection used for filtering large histories.
    var appliedQuery: String = ""
    var selectedID: UUID?
    var pendingDeletionID: UUID?
    var isVisible = false

    func entries(from allEntries: [ClipboardEntry]) -> [ClipboardEntry] {
        let scoped = allEntries.filter(scope.includes)
        let trimmedQuery = appliedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return ClipboardSorting.pinnedFirst(scoped)
        }

        let needle = trimmedQuery.localizedLowercase
        return ClipboardSorting.pinnedFirst(scoped.filter { entry in
            if ClipboardSorting.matches(entry: entry, query: trimmedQuery) {
                return true
            }
            return entry.source.applicationName?.localizedLowercase.contains(needle) == true
                || entry.source.bundleIdentifier?.localizedLowercase.contains(needle) == true
        })
    }

    func sections(from allEntries: [ClipboardEntry]) -> HistorySections {
        let visible = entries(from: allEntries)
        return HistorySections(
            pinned: visible.filter(\.isPinned),
            recent: visible.filter { !$0.isPinned }
        )
    }

    func count(for scope: ClipboardLibraryScope, in entries: [ClipboardEntry]) -> Int {
        entries.lazy.filter(scope.includes).count
    }

    func reconcileSelection(with allEntries: [ClipboardEntry]) {
        let visible = entries(from: allEntries)
        if let selectedID, visible.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = visible.first?.id
    }

    func selectedEntry(from allEntries: [ClipboardEntry]) -> ClipboardEntry? {
        let visible = entries(from: allEntries)
        if let selectedID,
           let selected = visible.first(where: { $0.id == selectedID }) {
            return selected
        }
        return visible.first
    }

    func moveSelection(by delta: Int, in allEntries: [ClipboardEntry]) {
        let sections = sections(from: allEntries)
        selectedID = HistoryQuery.moveSelection(
            currentID: selectedID,
            delta: delta,
            sections: sections
        )
    }

}

/// Standard, resizable macOS window for the complete clipboard library.
///
/// Integration remains callback based: the app coordinator owns focus restoration,
/// paste dispatch, and Quick Look presentation, while this controller owns only its
/// window and library-specific keyboard behavior.
@MainActor
final class ClipboardLibraryController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    let state = ClipboardLibraryViewState()
    let dragController = HistoryDragController()

    var onPaste: ((ClipboardEntry) -> Void)?
    var onDismiss: (() -> Void)?
    var onQuickLook: ((ClipboardEntry) -> Void)?

    private let history: HistoryModel
    private var libraryWindow: NSWindow?
    private var hostingController: NSHostingController<ClipboardLibraryRootView>?
    private weak var searchField: NSSearchField?
    private var keyMonitor: Any?
    private var notifyDismissOnClose = true

    private static let toolbarIdentifier = NSToolbar.Identifier("NotchClip.ClipboardLibraryToolbar")
    private static let searchItemIdentifier = NSToolbarItem.Identifier("NotchClip.ClipboardLibraryToolbar.Search")

    init(history: HistoryModel) {
        self.history = history
        super.init()
    }

    var isVisible: Bool {
        libraryWindow?.isVisible == true
    }

    var selectedEntry: ClipboardEntry? {
        state.selectedEntry(from: history.entries)
    }

    func attach(engine: ClipboardEngine?) {
        dragController.attach(engine: engine)
    }

    func present() {
        buildWindowIfNeeded()
        guard let window = libraryWindow else { return }

        history.refresh()
        history.setLibraryVisible(true)
        state.isVisible = true
        state.reconcileSelection(with: history.entries)
        notifyDismissOnClose = true
        installKeyMonitor()

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.focusSearchField(selectAll: false)
        }
    }

    func toggle() {
        if isVisible {
            close()
        } else {
            present()
        }
    }

    func close() {
        guard let window = libraryWindow, window.isVisible else { return }
        window.performClose(nil)
    }

    func refocusAfterQuickLook() {
        guard let window = libraryWindow, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// Process teardown path; closes without firing app-level restoration callbacks.
    func shutdown() {
        notifyDismissOnClose = false
        removeKeyMonitor()
        history.setLibraryVisible(false)
        libraryWindow?.orderOut(nil)
        state.isVisible = false
    }

    func pasteSelection() {
        guard let entry = state.selectedEntry(from: history.entries) else { return }
        state.selectedID = entry.id
        // The coordinator receives the exact entry and can use HistoryModel's
        // entry-ID paste seam without coupling this window to the notch selection.
        onPaste?(entry)
    }

    func quickLookSelection() {
        guard let entry = state.selectedEntry(from: history.entries) else { return }
        guard entry.primaryKind == .image || entry.primaryKind == .fileList else {
            NSSound.beep()
            return
        }
        state.selectedID = entry.id
        onQuickLook?(entry)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        history.setLibraryVisible(false)
        state.isVisible = false
        if notifyDismissOnClose {
            onDismiss?()
        }
        notifyDismissOnClose = true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        state.reconcileSelection(with: history.entries)
    }

    // MARK: - Window construction

    private func buildWindowIfNeeded() {
        guard libraryWindow == nil else { return }

        let root = ClipboardLibraryRootView(
            history: history,
            state: state,
            dragController: dragController,
            onPaste: { [weak self] entry in
                guard let self else { return }
                self.state.selectedID = entry.id
                self.pasteSelection()
            },
            onQuickLook: { [weak self] entry in
                guard let self else { return }
                self.state.selectedID = entry.id
                self.quickLookSelection()
            },
            onFocusSearch: { [weak self] in
                self?.focusSearchField()
            }
        )
        let hostingController = NSHostingController(rootView: root)

        let style: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: ClipboardLibraryLayout.defaultWidth,
                height: ClipboardLibraryLayout.defaultHeight
            ),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard History"
        window.subtitle = ""
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentMinSize = NSSize(
            width: ClipboardLibraryLayout.minimumWidth,
            height: ClipboardLibraryLayout.minimumHeight
        )
        window.contentViewController = hostingController
        window.delegate = self

        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = true
        window.toolbar = toolbar

        let autosaveName = "NotchClip.ClipboardLibraryWindow.v2"
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)

        self.hostingController = hostingController
        self.libraryWindow = window
    }

    // MARK: - Native toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.searchItemIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.searchItemIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.searchItemIdentifier else { return nil }

        let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Search"
        item.paletteLabel = "Search Clipboard History"
        item.toolTip = "Search clipboard history (Command-F)"
        item.preferredWidthForSearchField = 320

        let field = item.searchField
        field.placeholderString = "Search Clipboard History"
        field.controlSize = .regular
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.target = self
        field.action = #selector(searchTextChanged(_:))
        field.delegate = self
        field.setAccessibilityLabel("Search clipboard history")
        field.setAccessibilityHelp("Search item contents and source applications")
        searchField = field
        return item
    }

    @objc private func searchTextChanged(_ sender: NSSearchField) {
        state.query = sender.stringValue
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        pasteSelection()
        return true
    }

    private func focusSearchField(selectAll: Bool = true) {
        guard let window = libraryWindow,
              window.isVisible,
              let searchField else { return }
        if searchField.stringValue != state.query {
            searchField.stringValue = state.query
        }
        guard window.makeFirstResponder(searchField) else { return }
        if selectAll {
            searchField.selectText(nil)
        }
    }

    // MARK: - Keyboard behavior

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.libraryWindow,
                  window.isKeyWindow,
                  event.window === window,
                  window.attachedSheet == nil else {
                return event
            }
            return self.handleKeyDown(event, in: window)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandOnly = modifiers == .command
        if commandOnly, event.charactersIgnoringModifiers?.lowercased() == "f" {
            focusSearchField()
            return nil
        }

        let hasCommandLikeModifier = !modifiers.intersection([.command, .control, .option]).isEmpty
        guard !hasCommandLikeModifier else { return event }

        switch event.keyCode {
        case 125: // Down Arrow
            state.moveSelection(by: 1, in: history.entries)
            return nil
        case 126: // Up Arrow
            state.moveSelection(by: -1, in: history.entries)
            return nil
        case 49: // Space
            // Space remains text input while the native search field is being edited.
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                return event
            }
            guard !event.isARepeat else { return nil }
            quickLookSelection()
            return nil
        case 53: // Escape
            if !state.query.isEmpty || !state.appliedQuery.isEmpty {
                state.query = ""
                state.appliedQuery = ""
                state.reconcileSelection(with: history.entries)
                searchField?.stringValue = ""
                focusSearchField(selectAll: false)
            } else {
                close()
            }
            return nil
        default:
            return event
        }
    }
}
