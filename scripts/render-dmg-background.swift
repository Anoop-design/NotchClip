#!/usr/bin/env swift
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: render-dmg-background.swift OUTPUT.png\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let width = 680
let height = 440

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("error: could not allocate bitmap\n", stderr)
    exit(1)
}

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("error: could not create graphics context\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let canvas = NSRect(x: 0, y: 0, width: width, height: height)
NSColor(calibratedWhite: 0.075, alpha: 1).setFill()
canvas.fill()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    .paragraphStyle: paragraph,
    .kern: -0.2
]
let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
    .foregroundColor: NSColor.white.withAlphaComponent(0.46),
    .paragraphStyle: paragraph
]
let footerAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
    .foregroundColor: NSColor.white.withAlphaComponent(0.28),
    .paragraphStyle: paragraph
]

("Drag NotchClip to Applications" as NSString).draw(
    in: NSRect(x: 80, y: 354, width: 520, height: 28),
    withAttributes: titleAttributes
)
("Then open it from your Applications folder" as NSString).draw(
    in: NSRect(x: 80, y: 329, width: 520, height: 18),
    withAttributes: subtitleAttributes
)
("Requires macOS 14 or later" as NSString).draw(
    in: NSRect(x: 80, y: 28, width: 520, height: 18),
    withAttributes: footerAttributes
)

// A quiet directional cue; the Finder icons remain the visual focus.
let arrow = NSBezierPath()
arrow.lineWidth = 2
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 306, y: 207))
arrow.line(to: NSPoint(x: 374, y: 207))
arrow.move(to: NSPoint(x: 363, y: 217))
arrow.line(to: NSPoint(x: 374, y: 207))
arrow.line(to: NSPoint(x: 363, y: 197))
NSColor.white.withAlphaComponent(0.34).setStroke()
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("error: could not encode png\n", stderr)
    exit(1)
}
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
print(outputURL.path)
