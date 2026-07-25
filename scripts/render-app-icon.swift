#!/usr/bin/env swift
import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first
    ?? "Packaging/Assets/AppIconMaster.png"
let canvas = NSSize(width: 1024, height: 1024)

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func fill(_ path: NSBezierPath, _ color: NSColor) {
    color.setFill()
    path.fill()
}

func stroke(_ path: NSBezierPath, _ color: NSColor, width: CGFloat) {
    color.setStroke()
    path.lineWidth = width
    path.stroke()
}

let image = NSImage(size: canvas)
image.lockFocus()

NSColor.clear.setFill()
NSRect(origin: .zero, size: canvas).fill()

// One solid near-black key shape. Transparency outside lets macOS apply its
// normal icon presentation without leaving a dark square around the artwork.
let tile = roundedRect(NSRect(x: 72, y: 72, width: 880, height: 880), radius: 218)
NSGraphicsContext.current?.cgContext.saveGState()
NSGraphicsContext.current?.cgContext.setShadow(
    offset: CGSize(width: 0, height: -18),
    blur: 34,
    color: NSColor.black.withAlphaComponent(0.52).cgColor
)
fill(tile, NSColor(calibratedWhite: 0.055, alpha: 1))
NSGraphicsContext.current?.cgContext.restoreGState()
stroke(tile, NSColor.white.withAlphaComponent(0.13), width: 4)

// A quiet camera-housing cutout anchors the mark to the MacBook notch.
let notch = roundedRect(NSRect(x: 278, y: 765, width: 468, height: 116), radius: 56)
fill(notch, NSColor(calibratedWhite: 0.018, alpha: 1))
stroke(notch, NSColor.white.withAlphaComponent(0.12), width: 3)

// Solid clipboard silhouette. The inset is cut with the same black as the tile,
// giving the mark depth without gradients, neon, or decorative color.
let paper = roundedRect(NSRect(x: 270, y: 250, width: 484, height: 426), radius: 96)
fill(paper, NSColor(calibratedWhite: 0.91, alpha: 1))

let clip = roundedRect(NSRect(x: 382, y: 610, width: 260, height: 126), radius: 52)
fill(clip, NSColor(calibratedWhite: 0.91, alpha: 1))

let clipHole = NSBezierPath(ovalIn: NSRect(x: 480, y: 659, width: 64, height: 64))
fill(clipHole, NSColor(calibratedWhite: 0.055, alpha: 1))

let paperInset = roundedRect(NSRect(x: 316, y: 302, width: 392, height: 292), radius: 58)
fill(paperInset, NSColor(calibratedWhite: 0.075, alpha: 1))

// Three retained clipboard entries—simple, legible, and consistent at 16 px.
for (y, width) in [(505.0, 282.0), (425.0, 320.0), (345.0, 238.0)] {
    let line = roundedRect(
        NSRect(x: 360, y: y, width: width, height: 28),
        radius: 14
    )
    fill(line, NSColor.white.withAlphaComponent(0.78))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("error: could not encode app icon\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
print(outputURL.path)
