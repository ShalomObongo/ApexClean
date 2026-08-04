#!/usr/bin/env swift
import AppKit

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "./ApexClean.iconset"
let sourcePath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "./Sources/ApexClean/Resources/CoastalAtlasAppIcon.png"

guard let source = NSImage(contentsOfFile: sourcePath) else {
    FileHandle.standardError.write("Could not read icon source at \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.createDirectory(
    atPath: outputDirectory,
    withIntermediateDirectories: true
)

func render(size: Int) -> Data? {
    guard
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else { return nil }

    representation.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    return representation.representation(using: .png, properties: [:])
}

let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let data = render(size: variant.size) else {
        FileHandle.standardError.write("Failed to render \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(variant.name).png"))
}

print("Rendered \(variants.count) icon variants to \(outputDirectory)")
