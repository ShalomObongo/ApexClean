import AppKit
import SwiftUI

/// Static paper-and-contour field behind the Coastal Atlas interface.
struct AtlasBackdrop: View {
    var intensity: Double = 1
    var energy: Double = 0

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Palette.canvas(scheme)

            Canvas { context, size in
                drawGrid(context: &context, size: size)
                drawContours(context: &context, size: size)
            }
            .opacity(0.45 + intensity * 0.18 + energy * 0.08)

            GrainOverlay(opacity: scheme == .dark ? 0.026 : 0.04)
        }
        .ignoresSafeArea()
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let spacing: CGFloat = 64
        let colour = Palette.contour(scheme).opacity(scheme == .dark ? 0.055 : 0.075)

        var path = Path()
        for x in stride(from: CGFloat.zero, through: size.width, by: spacing) {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in stride(from: CGFloat.zero, through: size.height, by: spacing) {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(path, with: .color(colour), lineWidth: 0.7)
    }

    private func drawContours(context: inout GraphicsContext, size: CGSize) {
        let colour = Palette.dustyBlue.opacity(scheme == .dark ? 0.08 : 0.11)
        let centres = [
            CGPoint(x: size.width * 0.86, y: size.height * 0.12),
            CGPoint(x: size.width * 0.04, y: size.height * 0.92),
        ]

        for centre in centres {
            for radius in stride(from: CGFloat(110), through: 430, by: 54) {
                let rect = CGRect(
                    x: centre.x - radius,
                    y: centre.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.stroke(Path(ellipseIn: rect), with: .color(colour), lineWidth: 1)
            }
        }
    }
}

struct GrainOverlay: View {
    var opacity: Double = 0.035

    var body: some View {
        Image(nsImage: GrainTile.shared)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(.multiply)
            .allowsHitTesting(false)
    }
}

enum GrainTile {
    static let shared: NSImage = make(side: 128)

    private static func make(side: Int) -> NSImage {
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: side * side * bytesPerPixel)
        var generator = SplitMix64(seed: 0x9E37_79B9_7F4A_7C15)

        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let value = generator.nextUnit()
            let level = UInt8(max(0, min(255, 128 + (value - 0.5) * 120)))
            pixels[index] = level
            pixels[index + 1] = level
            pixels[index + 2] = level
            pixels[index + 3] = 255
        }

        let image = NSImage(size: NSSize(width: side, height: side))
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                let context = CGContext(
                    data: base,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side * bytesPerPixel,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                let cgImage = context.makeImage()
            else { return }
            image.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
        }
        return image
    }
}

struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
