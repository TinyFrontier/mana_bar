#!/usr/bin/env swift
//
// Rasterizes Resources/icons/mana-mark.svg (and the <20px optical variant,
// mana-mark-small.svg) into the macOS AppIcon.appiconset PNGs, reproducing
// the "Иконка приложения и фавикон" panel of the Mana logo kit:
//
//   - plate background: #1B1F26 ("Plate"), corner radius = 24% of the side
//   - glyph tint (the mark's currentColor track): #333C4B
//   - glyph fill ratio of the plate: ~64% for rendered sizes >= 20px
//     (mana-mark.svg, full mark with core), ~75% for the one slot that
//     rasterizes below 20px (mana-mark-small.svg, no core, heavier stroke —
//     "Ниже 20 px ядро убирается, обводка дуги растёт до 12")
//
// Usage (from repo root):
//   swift scripts/render-app-icon.swift
//
// Re-run this after editing Resources/icons/mana-mark*.svg to refresh the
// checked-in PNGs under Sources/Resources/Assets.xcassets/AppIcon.appiconset.
// Kept in scripts/ (rather than discarded as a one-off) so the icon is
// reproducible from source instead of only existing as opaque binary PNGs.

import AppKit

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsDir = repoRoot.appendingPathComponent("Resources/icons")
let outDir = repoRoot.appendingPathComponent(
    "Sources/Resources/Assets.xcassets/AppIcon.appiconset"
)

let plateColor = NSColor(srgbRed: 0x1B / 255.0, green: 0x1F / 255.0, blue: 0x26 / 255.0, alpha: 1)
let glyphTintHex = "#333c4b"
let plateCornerFraction: CGFloat = 0.24
let standardGlyphFraction: CGFloat = 0.64
let smallGlyphFraction: CGFloat = 0.75
/// Rendered pixel size below which the kit's "bare" (no-core) optical
/// variant replaces the standard mark.
let smallSizeThreshold = 20

struct IconSlot {
    let filename: String
    let pixels: Int
}

let slots: [IconSlot] = [
    IconSlot(filename: "icon_16x16.png", pixels: 16),
    IconSlot(filename: "icon_16x16@2x.png", pixels: 32),
    IconSlot(filename: "icon_32x32.png", pixels: 32),
    IconSlot(filename: "icon_32x32@2x.png", pixels: 64),
    IconSlot(filename: "icon_128x128.png", pixels: 128),
    IconSlot(filename: "icon_128x128@2x.png", pixels: 256),
    IconSlot(filename: "icon_256x256.png", pixels: 256),
    IconSlot(filename: "icon_256x256@2x.png", pixels: 512),
    IconSlot(filename: "icon_512x512.png", pixels: 512),
    IconSlot(filename: "icon_512x512@2x.png", pixels: 1024),
]

func loadGlyph(named name: String, tintHex: String) -> NSImage {
    let source = iconsDir.appendingPathComponent(name)
    guard var svg = try? String(contentsOf: source, encoding: .utf8) else {
        fatalError("Could not read \(source.path)")
    }
    // Tint currentColor for this bake by setting the CSS `color` presentation
    // attribute on the root <svg> element — the gradient-filled arc/core are
    // unaffected (they don't reference currentColor).
    guard let range = svg.range(of: "<svg ") else {
        fatalError("Unexpected SVG shape in \(name)")
    }
    svg.insert(contentsOf: "color=\"\(tintHex)\" ", at: range.upperBound)
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".svg")
    try! svg.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard let image = NSImage(contentsOf: tmp) else {
        fatalError("NSImage failed to load rasterized SVG for \(name)")
    }
    return image
}

func roundedRectPath(in rect: NSRect, cornerRadius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
}

func renderIcon(pixels: Int, into outputURL: URL) {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    let plate = roundedRectPath(in: bounds, cornerRadius: size * plateCornerFraction)
    plateColor.setFill()
    plate.fill()

    let useBare = pixels < smallSizeThreshold
    let glyphName = useBare ? "mana-mark-small.svg" : "mana-mark.svg"
    let glyphFraction = useBare ? smallGlyphFraction : standardGlyphFraction
    let glyph = loadGlyph(named: glyphName, tintHex: glyphTintHex)

    let glyphSize = size * glyphFraction
    let glyphOrigin = (size - glyphSize) / 2
    let glyphRect = NSRect(x: glyphOrigin, y: glyphOrigin, width: glyphSize, height: glyphSize)
    glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG for \(outputURL.lastPathComponent)")
    }
    try! png.write(to: outputURL)
    print("wrote \(outputURL.lastPathComponent) (\(pixels)x\(pixels), glyph=\(glyphName))")
}

try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for slot in slots {
    renderIcon(pixels: slot.pixels, into: outDir.appendingPathComponent(slot.filename))
}
print("Done — \(slots.count) PNGs written to \(outDir.path)")
