import Foundation
import AppKit
import LinkPresentation
import NotchClipCore

/// Live LPMetadataProvider-backed fetcher. Cancellation calls `provider.cancel()`.
final class LPMetadataFetcher: LinkMetadataFetching, @unchecked Sendable {
    func fetch(url: URL) async throws -> LinkMetadataResult {
        let provider = LPMetadataProvider()
        provider.timeout = 12
        provider.shouldFetchSubresources = false
        return try await withTaskCancellationHandler {
            let metadata = try await provider.startFetchingMetadata(for: url)
            try Task.checkCancellation()
            let title = LinkPreviewURLPolicy.trimmedTitle(metadata.title)
            var imageData: Data?
            if let imageProvider = metadata.imageProvider {
                imageData = try await loadImageData(from: imageProvider)
            }
            return LinkMetadataResult(title: title, imagePNGData: imageData)
        } onCancel: {
            provider.cancel()
        }
    }

    private func loadImageData(from provider: NSItemProvider) async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadObject(ofClass: NSImage.self) { object, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let image = object as? NSImage else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: LinkPreviewImageCodec.boundedPNG(from: image))
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
