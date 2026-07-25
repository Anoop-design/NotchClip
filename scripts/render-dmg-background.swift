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
NSColor(calibratedWhite: 0.045, alpha: 1).setFill()
canvas.fill()

// Flat neutral plates frame the Finder icons without simulated lighting or color.
for centerX in [170.0, 510.0] {
    let plateRect = NSRect(x: centerX - 82, y: 128, width: 164, height: 164)
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: 30, yRadius: 30)
    NSColor.white.withAlphaComponent(0.035).setFill()
    plate.fill()
    NSColor.white.withAlphaComponent(0.085).setStroke()
    plate.lineWidth = 1
    plate.stroke()
}

// A restrained island mark ties the installer back to the app interaction.
let islandRect = NSRect(x: 287, y: 380, width: 106, height: 20)
NSColor(calibratedWhite: 0.015, alpha: 1).setFill()
NSBezierPath(roundedRect: islandRect, xRadius: 10, yRadius: 10).fill()
let accentRect = NSRect(x: 299, y: 386, width: 8, height: 8)
NSColor.white.withAlphaComponent(0.72).setFill()
NSBezierPath(ovalIn: accentRect).fill()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 27, weight: .semibold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph,
    .kern: -0.35
]
let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.58),
    .paragraphStyle: paragraph
]
let footerAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
    .foregroundColor: NSColor.white.withAlphaComponent(0.30),
    .paragraphStyle: paragraph
]

("Install NotchClip" as NSString).draw(
    in: NSRect(x: 80, y: 338, width: 520, height: 34),
    withAttributes: titleAttributes
)
("Drag NotchClip to Applications" as NSString).draw(
    in: NSRect(x: 80, y: 313, width: 520, height: 22),
    withAttributes: subtitleAttributes
)
("macOS 14 or later" as NSString).draw(
    in: NSRect(x: 80, y: 28, width: 520, height: 18),
    withAttributes: footerAttributes
)

// Draw a soft three-segment arrow without relying on font glyph rendering.
let arrow = NSBezierPath()
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 292, y: 190))
arrow.line(to: NSPoint(x: 382, y: 190))
arrow.move(to: NSPoint(x: 366, y: 205))
arrow.line(to: NSPoint(x: 382, y: 190))
arrow.line(to: NSPoint(x: 366, y: 175))
NSColor.white.withAlphaComponent(0.52).setStroke()
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
