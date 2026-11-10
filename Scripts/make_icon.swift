#!/usr/bin/env swift
// Icon grid normalization and iconutil packaging adapted from MacClean/Scripts/make_icon.swift.
// The artwork is generated separately; this script only resizes and packs it without redesigning it.
// Usage (from the project root): swift Scripts/make_icon.swift
import AppKit

let source = "Resources/AppIcon-source.png"
guard let data = FileManager.default.contents(atPath: source), let art = NSBitmapImageRep(data: data) else {
    fatalError("Cannot read app icon artwork")
}

// Fit the opaque tile to the same 824/1024 grid used by the sibling macOS apps.
var bounds = (minX: art.pixelsWide, maxX: -1, minY: art.pixelsHigh, maxY: -1)
for y in 0..<art.pixelsHigh {
    for x in 0..<art.pixelsWide where (art.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.8 {
        bounds = (min(bounds.minX, x), max(bounds.maxX, x), min(bounds.minY, y), max(bounds.maxY, y))
    }
}
guard bounds.maxX >= bounds.minX, bounds.maxY >= bounds.minY else { fatalError("Icon artwork is empty") }
let bodySize = CGFloat(max(bounds.maxX - bounds.minX, bounds.maxY - bounds.minY) + 1)
let scale = 824 / bodySize
let center = NSPoint(x: CGFloat(bounds.minX + bounds.maxX + 1) / 2,
                     y: CGFloat(art.pixelsHigh) - CGFloat(bounds.minY + bounds.maxY + 1) / 2)
let artRect = NSRect(x: 512 - center.x * scale, y: 512 - center.y * scale,
                     width: CGFloat(art.pixelsWide) * scale, height: CGFloat(art.pixelsHigh) * scale)
let image = NSImage(size: NSSize(width: art.pixelsWide, height: art.pixelsHigh))
image.addRepresentation(art)

func render(_ pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let unit = CGFloat(pixels) / 1024
    image.draw(in: NSRect(x: artRect.minX * unit, y: artRect.minY * unit,
                         width: artRect.width * unit, height: artRect.height * unit),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render app icon") }
    return data
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("MacClipBoard-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for (name, pixels) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    try render(pixels).write(to: iconset.appendingPathComponent(name + ".png"))
}
try render(1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-preview.png"))
let packer = Process()
packer.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
packer.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try packer.run()
packer.waitUntilExit()
guard packer.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns and Resources/AppIcon-preview.png")
