#!/usr/bin/env swift
import AppKit
import Foundation

// Resolve paths relative to this script file so it runs from anywhere.
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let projectRoot = scriptDir.deletingLastPathComponent()
let svgPath = scriptDir.appendingPathComponent("icon-source.svg")
let appiconset = projectRoot
    .appendingPathComponent("WindowMover")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

struct IconSize {
    let filename: String
    let pixels: Int
}

let sizes: [IconSize] = [
    .init(filename: "icon_16.png",     pixels: 16),
    .init(filename: "icon_16@2x.png",  pixels: 32),
    .init(filename: "icon_32.png",     pixels: 32),
    .init(filename: "icon_32@2x.png",  pixels: 64),
    .init(filename: "icon_128.png",    pixels: 128),
    .init(filename: "icon_128@2x.png", pixels: 256),
    .init(filename: "icon_256.png",    pixels: 256),
    .init(filename: "icon_256@2x.png", pixels: 512),
    .init(filename: "icon_512.png",    pixels: 512),
    .init(filename: "icon_512@2x.png", pixels: 1024),
]

guard FileManager.default.fileExists(atPath: svgPath.path) else {
    FileHandle.standardError.write("SVG not found: \(svgPath.path)\n".data(using: .utf8)!)
    exit(1)
}

let svgData = try Data(contentsOf: svgPath)

// Clean old PNGs so the directory is reproducible.
let existing = (try? FileManager.default.contentsOfDirectory(atPath: appiconset.path)) ?? []
for name in existing where name.hasSuffix(".png") {
    try? FileManager.default.removeItem(at: appiconset.appendingPathComponent(name))
}

func renderPNG(from svgData: Data, pixels: Int) -> Data? {
    guard let svgImage = NSImage(data: svgData) else { return nil }
    let targetSize = NSSize(width: pixels, height: pixels)
    guard let bitmap = NSBitmapImageRep(
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
    ) else { return nil }
    bitmap.size = targetSize
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    svgImage.size = targetSize
    svgImage.draw(in: NSRect(origin: .zero, size: targetSize),
                  from: NSRect(origin: .zero, size: NSSize(width: 1024, height: 1024)),
                  operation: .copy,
                  fraction: 1.0)
    return bitmap.representation(using: .png, properties: [:])
}

for size in sizes {
    guard let pngData = renderPNG(from: svgData, pixels: size.pixels) else {
        FileHandle.standardError.write("Failed to render \(size.filename)\n".data(using: .utf8)!)
        exit(1)
    }
    let outURL = appiconset.appendingPathComponent(size.filename)
    try pngData.write(to: outURL)
    print("wrote \(size.filename) (\(size.pixels)x\(size.pixels))")
}
print("done: \(sizes.count) icons")
