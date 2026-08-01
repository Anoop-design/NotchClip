import Foundation
import AppKit

/// What a "paste as plain text" request should do for one clip.
public enum PlainTextPasteDecision: Equatable, Sendable {
    /// Read this retained representation and write back only its plain string.
    case plainText(sourceTypeIdentifier: String)
    /// The clip has no plain-text form — write every retained representation instead.
    case fallbackToNormalPaste
}

/// Decides which retained representation a plain-text paste reads and what it writes.
///
/// Pure and storage-free: the caller resolves the returned type identifier against
/// `payloadRefs`, so the decision stays unit-testable without a payload store.
public enum PlainTextPastePolicy {
    /// Retained types that can yield a plain string, best first. `url` sits above
    /// rtf/html so a copied link pastes its absolute string rather than the
    /// flattened text of the anchor that carried it.
    public static let sourceOrder: [String] = [
        ClipboardTypeIdentifiers.utf8PlainText,
        ClipboardTypeIdentifiers.plainText,
        ClipboardTypeIdentifiers.utf16External,
        ClipboardTypeIdentifiers.url,
        ClipboardTypeIdentifiers.rtf,
        ClipboardTypeIdentifiers.html
    ]

    /// The only types a plain-text paste writes. Everything the clip also carried
    /// (RTF, HTML, attachments, source markers) is dropped.
    public static let outputTypeIdentifiers: [String] = [
        ClipboardTypeIdentifiers.utf8PlainText,
        ClipboardTypeIdentifiers.plainText
    ]

    public static func decision(
        kind: ClipboardContentKind,
        availableTypeIdentifiers: [String]
    ) -> PlainTextPasteDecision {
        switch kind {
        case .image, .fileList:
            // No plain-text form at all; stripping would paste nothing.
            return .fallbackToNormalPaste
        case .plainText, .rtf, .html, .url, .mixed, .other:
            break
        }
        let available = Set(availableTypeIdentifiers)
        guard let source = sourceOrder.first(where: { available.contains($0) }) else {
            return .fallbackToNormalPaste
        }
        return .plainText(sourceTypeIdentifier: source)
    }

    public static func decision(for entry: ClipboardEntry) -> PlainTextPasteDecision {
        decision(
            kind: entry.primaryKind,
            availableTypeIdentifiers: entry.payloadRefs
                .filter { !$0.relativePath.isEmpty }
                .map(\.typeIdentifier)
        )
    }

    /// Whether a paste strips formatting, given the preference and whether ⇧ was held.
    /// The modifier inverts the preference rather than adding to it, so ⇧ always
    /// means "the other kind of paste".
    public static func usesPlainText(alwaysPlainText: Bool, shiftHeld: Bool) -> Bool {
        alwaysPlainText != shiftHeld
    }

    /// Decode one retained representation into the string a plain-text paste writes.
    ///
    /// Background-safe: RTF import does not go through WebKit, and HTML uses the
    /// tag-stripping path rather than `NSAttributedString(html:)`, which Apple
    /// requires to run on the main thread.
    public static func plainString(from data: Data, typeIdentifier: String) -> String? {
        guard !data.isEmpty else { return nil }
        switch typeIdentifier {
        case ClipboardTypeIdentifiers.rtf:
            return NSAttributedString(rtf: data, documentAttributes: nil)?.string
        case ClipboardTypeIdentifiers.html:
            return PasteboardParser.plainTextFromHTML(data)
        case ClipboardTypeIdentifiers.url:
            if let raw = decodeText(data) {
                let cleaned = raw
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
            // Binary NSURL absolute-URL data representation.
            return (NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?)?
                .absoluteString
        default:
            return decodeText(data)
        }
    }

    private static func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }
}
