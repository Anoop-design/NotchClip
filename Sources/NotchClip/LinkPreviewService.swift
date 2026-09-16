import Foundation
import AppKit
import LinkPresentation
import UniformTypeIdentifiers
import NotchClipCore

/// Live LPMetadataProvider-backed fetcher. Cancellation calls `provider.cancel()`.
final class LPMetadataFetcher: LinkMetadataFetching, @unchecked Sendable {
    func fetch(url: URL) async throws -> LinkMetadataResult {
        let provider = LPMetadataProvider()
        provider.timeout = 12
        // Artwork and video thumbnails are subresources. Disabling this still
        // returns titles for many pages, but commonly leaves imageProvider nil.
        provider.shouldFetchSubresources = true
        return try await withTaskCancellationHandler {
            let metadata = try await provider.startFetchingMetadata(for: url)
            try Task.checkCancellation()
            let title = LinkPreviewURLPolicy.trimmedTitle(metadata.title)
            let imageData = try await loadBestVisual(
                imageProvider: metadata.imageProvider,
                iconProvider: metadata.iconProvider
            )
            return LinkMetadataResult(title: title, imagePNGData: imageData)
        } onCancel: {
            provider.cancel()
        }
    }

    /// App Store pages commonly expose the app artwork as an icon rather than
    /// as the page's primary image. Try both, keeping the richer page image when
    /// available and falling back cleanly if a provider cannot vend an NSImage.
    private func loadBestVisual(
        imageProvider: NSItemProvider?,
        iconProvider: NSItemProvider?
    ) async throws -> Data? {
        for provider in [imageProvider, iconProvider].compactMap({ $0 }) {
            do {
                if let data = try await loadImageData(from: provider) {
                    return data
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            try Task.checkCancellation()
        }
        return nil
    }

    private func loadImageData(from provider: NSItemProvider) async throws -> Data? {
        if provider.canLoadObject(ofClass: NSImage.self) {
            do {
                if let image = try await loadNSImage(from: provider) {
                    return LinkPreviewImageCodec.boundedPNG(from: image)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Some LinkPresentation providers advertise NSImage but only
                // successfully vend a registered image data representation.
            }
        }

        for identifier in provider.registeredTypeIdentifiers where
            UTType(identifier)?.conforms(to: .image) == true {
            do {
                guard let bytes = try await loadDataRepresentation(
                    from: provider,
                    typeIdentifier: identifier
                ), let image = NSImage(data: bytes) else { continue }
                if let png = LinkPreviewImageCodec.boundedPNG(from: image) {
                    return png
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return nil
    }

    private func loadNSImage(from provider: NSItemProvider) async throws -> NSImage? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: NSImage.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: object as? NSImage)
            }
        }
    }

    private func loadDataRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}

enum LinkPreviewImageCodec {
    static let maxPixel: CGFloat = 512
    static let maxBytes = LinkPreviewURLPolicy.maxImageBytes

    static func boundedPNG(from image: NSImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxPixel / max(size.width, size.height))
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(newSize.width),
            pixelsHigh: Int(newSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: newSize))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return LinkPreviewURLPolicy.boundedImageData(data)
    }
}
