#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Generates the ApexClean app icon set.
//
// The mark is an abstract "apex": a chevron rising out of a set of receding
// strata, drawn on the jade→cyan signature gradient. Rendered at every size the
// macOS icon pipeline expects, then assembled with iconutil.

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "./ApexClean.iconset"

try? FileManager.default.createDirectory(
    atPath: outputDirectory,
    withIntermediateDirectories: true
)

func drawIcon(size: CGFloat) -> NSBitmapImageRep? {
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS icons sit inside a ~80% squircle with transparent margin.
    let margin = size * 0.10
    let plateRect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let cornerRadius = plateRect.width * 0.2237
    let plate = CGPath(
        roundedRect: plateRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // Deep base so the accent reads as emitted light rather than paint.
    context.saveGState()
    context.addPath(plate)
    context.clip()

    let baseColors = [
        CGColor(srgbRed: 0.043, green: 0.063, blue: 0.086, alpha: 1),
        CGColor(srgbRed: 0.020, green: 0.031, blue: 0.047, alpha: 1),
    ] as CFArray
    if let base = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: baseColors,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            base,
            start: CGPoint(x: plateRect.minX, y: plateRect.maxY),
            end: CGPoint(x: plateRect.maxX, y: plateRect.minY),
            options: []
        )
    }

    // Aurora bloom in the upper-left, echoing the app's backdrop.
    let bloomColors = [
        CGColor(srgbRed: 0.184, green: 0.878, blue: 0.627, alpha: 0.62),
        CGColor(srgbRed: 0.141, green: 0.812, blue: 0.910, alpha: 0.22),
        CGColor(srgbRed: 0.141, green: 0.812, blue: 0.910, alpha: 0),
    ] as CFArray
    if let bloom = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: bloomColors,
        locations: [0, 0.55, 1]
    ) {
        context.drawRadialGradient(
            bloom,
            startCenter: CGPoint(x: plateRect.minX + plateRect.width * 0.28, y: plateRect.maxY - plateRect.height * 0.18),
            startRadius: 0,
            endCenter: CGPoint(x: plateRect.minX + plateRect.width * 0.28, y: plateRect.maxY - plateRect.height * 0.18),
            endRadius: plateRect.width * 0.82,
            options: []
        )
    }

    // Receding strata: three bars that shorten as they rise, reading as
    // "storage being reclaimed" without spelling it out.
    let centreX = plateRect.midX
    let barHeight = plateRect.height * 0.052
    let strata: [(width: CGFloat, y: CGFloat, alpha: CGFloat)] = [
        (0.52, 0.235, 0.95),
        (0.37, 0.355, 0.62),
        (0.22, 0.475, 0.34),
    ]
    for stratum in strata {
        let width = plateRect.width * stratum.width
        let rect = CGRect(
            x: centreX - width / 2,
            y: plateRect.minY + plateRect.height * stratum.y,
            width: width,
            height: barHeight
        )
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: stratum.alpha))
        context.addPath(
            CGPath(
                roundedRect: rect,
                cornerWidth: barHeight / 2,
                cornerHeight: barHeight / 2,
                transform: nil
            )
        )
        context.fillPath()
    }

    // The apex chevron.
    let chevronWidth = plateRect.width * 0.46
    let chevronHeight = plateRect.height * 0.26
    let apexY = plateRect.minY + plateRect.height * 0.84
    let baseY = apexY - chevronHeight
    let stroke = plateRect.width * 0.105

    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: centreX - chevronWidth / 2, y: baseY))
    chevron.addLine(to: CGPoint(x: centreX, y: apexY))
    chevron.addLine(to: CGPoint(x: centreX + chevronWidth / 2, y: baseY))

    // Glow pass, then the crisp stroke on top.
    context.saveGState()
    context.setShadow(
        offset: .zero,
        blur: size * 0.055,
        color: CGColor(srgbRed: 0.184, green: 0.878, blue: 0.627, alpha: 0.9)
    )
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.addPath(chevron)
    context.strokePath()
    context.restoreGState()

    context.addPath(chevron)
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    let chevronColors = [
        CGColor(srgbRed: 0.310, green: 0.949, blue: 0.694, alpha: 1),
        CGColor(srgbRed: 0.196, green: 0.867, blue: 0.965, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: chevronColors,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: centreX - chevronWidth / 2, y: apexY),
            end: CGPoint(x: centreX + chevronWidth / 2, y: baseY),
            options: []
        )
    }
    context.restoreGState()

    // Hairline rim so the icon holds an edge on any wallpaper.
    context.saveGState()
    context.addPath(plate)
    context.setLineWidth(max(1, size * 0.004))
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14))
    context.strokePath()
    context.restoreGState()

    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image)
}

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let rep = drawIcon(size: variant.size),
          let data = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write("Failed to render \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(variant.name).png"))
}

print("Rendered \(variants.count) icon variants to \(outputDirectory)")
