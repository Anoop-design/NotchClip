import AppKit
import OSLog
import SwiftUI
import NotchClipCore

/// AppKit dragging source for history rows (multi-item pasteboard, session callbacks).
@MainActor
final class HistoryDragController: NSObject, NSDraggingSource {
    var onBegin: (() -> Void)?
    var onEnd: ((Bool) -> Void)?

    private weak var engine: ClipboardEngine?
    private let logger = Logger(subsystem: "com.anoop.notchclip", category: "Drag")
    /// Retained for the whole NSDraggingSession so lazy providers stay alive.
    private var activeProviders: [LazyDragPayloadProvider] = []
    private weak var activeSession: NSDraggingSession?

    func attach(engine: ClipboardEngine?) {
        self.engine = engine
    }

    /// Start a drag session for `entry` from `view`. Returns false if no items could be built.
    /// Inspects metadata only — does not load retained payload bytes from disk.
    @discardableResult
    func beginDrag(entry: ClipboardEntry, from view: NSView, event: NSEvent, image: NSImage?) -> Bool {
        guard event.type == .leftMouseDown else {
            logger.error("Refused drag because the initiating event was not leftMouseDown")
            return false
        }
        guard activeSession == nil, let engine else {
            logger.error("Refused drag because a session is active or the clipboard engine is unavailable")
            return false
        }
        let built = engine.makeLazyDraggingItems(for: entry)
        guard !built.items.isEmpty else {
            logger.error("Refused drag because no pasteboard items could be built")
            return false
        }

        activeProviders = built.providers

        let size = NSSize(width: 56, height: 56)
        let dragImage = Self.makeDragImage(preview: image, entry: entry, size: size)
        let location = view.convert(event.locationInWindow, from: nil)
        let frame = NSRect(
            x: location.x - size.width / 2,
            y: location.y - size.height / 2,
            width: size.width,
            height: size.height
        )

        let draggingItems = built.items.map { pbItem -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: pbItem)
            item.setDraggingFrame(frame, contents: dragImage)
            return item
        }

        let session = view.beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        activeSession = session
        logger.debug("Created drag session with \(draggingItems.count, privacy: .public) pasteboard item(s)")
        return true
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        activeSession = session
        logger.debug("Drag session began")
        onBegin?()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let success = operation != []
        logger.debug("Drag session ended; accepted=\(success, privacy: .public)")
        activeSession = nil
        activeProviders.removeAll()
        onEnd?(success)
    }

    private static func makeDragImage(
        preview: NSImage?,
        entry: ClipboardEntry,
        size: NSSize
    ) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let bounds = NSRect(origin: .zero, size: size)
        NSColor(calibratedWhite: 0.08, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13).fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 12.5, yRadius: 12.5)
        border.lineWidth = 1
        border.stroke()

        if let preview, preview.size.width > 0, preview.size.height > 0 {
            let target = aspectFit(preview.size, in: bounds.insetBy(dx: 8, dy: 8))
            preview.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            let mark = dragMark(for: entry.primaryKind) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9)
            ]
            let markSize = mark.size(withAttributes: attributes)
            mark.draw(
                at: NSPoint(
                    x: (size.width - markSize.width) / 2,
                    y: (size.height - markSize.height) / 2
                ),
                withAttributes: attributes
            )
        }
        return image
    }

    private static func aspectFit(_ source: NSSize, in bounds: NSRect) -> NSRect {
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let fitted = NSSize(width: source.width * scale, height: source.height * scale)
        return NSRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private static func dragMark(for kind: ClipboardContentKind) -> String {
        switch kind {
        case .plainText, .rtf, .html: return "TXT"
        case .url: return "URL"
        case .image: return "IMG"
        case .fileList: return "FILE"
        case .mixed: return "MIX"
        case .other: return "CLIP"
        }
    }
}

/// SwiftUI bridge for an artwork-sized click-and-drag surface using AppKit sessions.
struct DragHandleView: NSViewRepresentable {
    let entry: ClipboardEntry
    let previewImage: NSImage?
    let controller: HistoryDragController
    let onActivate: () -> Void
    var onDoubleActivate: (() -> Void)? = nil
    var isEnabled: Bool = true

    func makeNSView(context: Context) -> DragHandleNSView {
        let view = DragHandleNSView()
        view.controller = controller
        view.entry = entry
        view.previewImage = previewImage
        view.onActivate = onActivate
        view.onDoubleActivate = onDoubleActivate
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: DragHandleNSView, context: Context) {
        nsView.controller = controller
        nsView.entry = entry
        nsView.previewImage = previewImage
        nsView.onActivate = onActivate
        nsView.onDoubleActivate = onDoubleActivate
        nsView.isEnabled = isEnabled
    }
}

final class DragHandleNSView: NSView {
    var controller: HistoryDragController?
    var entry: ClipboardEntry?
    var previewImage: NSImage?
    var onActivate: (() -> Void)?
    var onDoubleActivate: (() -> Void)?
    var isEnabled: Bool = true

    private var mouseDownEvent: NSEvent?
    private var mouseDownLocation: NSPoint?
    private var didCrossDragThreshold = false
    private var didBeginDrag = false

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, event.type == .leftMouseDown else {
            super.mouseDown(with: event)
            return
        }
        mouseDownEvent = event
        mouseDownLocation = event.locationInWindow
        didCrossDragThreshold = false
        didBeginDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled,
              !didCrossDragThreshold,
              let mouseDownEvent,
              let mouseDownLocation,
              let controller,
              let entry else {
            return
        }
        guard DragGesturePolicy.shouldBeginDrag(
            mouseDown: mouseDownLocation,
            current: event.locationInWindow
        ) else {
            return
        }

        // Crossing the threshold turns this gesture into a drag attempt even when
        // the session cannot be built, so mouse-up must never become an activation.
        didCrossDragThreshold = true
        didBeginDrag = controller.beginDrag(
            entry: entry,
            from: self,
            event: mouseDownEvent,
            image: previewImage
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer { resetGesture() }
        guard isEnabled else {
            super.mouseUp(with: event)
            return
        }
        if !didCrossDragThreshold && !didBeginDrag {
            if event.clickCount == 2, let onDoubleActivate {
                onDoubleActivate()
            } else {
                onActivate?()
            }
        }
    }

    private func resetGesture() {
        mouseDownEvent = nil
        mouseDownLocation = nil
        didCrossDragThreshold = false
        didBeginDrag = false
    }
}
