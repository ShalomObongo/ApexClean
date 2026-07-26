import SwiftUI
import AppKit
import QuartzCore

/// The ambient backdrop.
///
/// Three soft colour fields drifting on long, mismatched periods so the
/// composition never visibly loops.
///
/// This is deliberately *not* a SwiftUI animation. A continuously animating
/// SwiftUI view re-runs the layout and render passes on every display cycle for
/// as long as it is on screen, which for a permanently visible backdrop is a
/// standing CPU cost measured in whole percentage points. Driving the drift with
/// `CABasicAnimation` on pre-rendered layers hands the whole thing to the render
/// server: the main thread does nothing at all once the animation is installed.
struct AuroraBackdrop: View {
    var intensity: Double = 1.0
    /// Rising energy during a scan: brighter and faster.
    var energy: Double = 0

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Palette.canvasDeep(scheme)

            AuroraLayerView(
                isDark: scheme == .dark,
                intensity: intensity,
                energy: energy,
                animates: !reduceMotion
            )
            .ignoresSafeArea()

            // A vertical scrim keeps text legible wherever a field drifts, while
            // still letting the colour read as ambient light in the room.
            LinearGradient(
                colors: [
                    Palette.canvas(scheme).opacity(scheme == .dark ? 0.42 : 0.44),
                    Palette.canvas(scheme).opacity(scheme == .dark ? 0.76 : 0.76),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            GrainOverlay(opacity: scheme == .dark ? 0.05 : 0.028)
                .ignoresSafeArea()
        }
    }
}

private struct AuroraLayerView: NSViewRepresentable {
    let isDark: Bool
    let intensity: Double
    let energy: Double
    let animates: Bool

    func makeNSView(context: Context) -> AuroraNSView {
        let view = AuroraNSView()
        view.configure(isDark: isDark, intensity: intensity, energy: energy, animates: animates)
        return view
    }

    func updateNSView(_ view: AuroraNSView, context: Context) {
        view.configure(isDark: isDark, intensity: intensity, energy: energy, animates: animates)
    }
}

final class AuroraNSView: NSView {
    /// Relative size, drift vector and period for each field. The periods are
    /// coprime-ish so the three cycles do not resynchronise.
    private struct FieldSpec {
        let scale: CGFloat
        let from: CGPoint
        let to: CGPoint
        let period: CFTimeInterval
    }

    private static let specs: [FieldSpec] = [
        .init(scale: 1.50, from: CGPoint(x: 0.08, y: -0.06), to: CGPoint(x: -0.22, y: -0.28), period: 41),
        .init(scale: 1.35, from: CGPoint(x: 0.04, y: 0.34), to: CGPoint(x: 0.28, y: 0.12), period: 53),
        .init(scale: 1.20, from: CGPoint(x: 0.26, y: -0.04), to: CGPoint(x: -0.04, y: 0.30), period: 67),
    ]

    private var fieldLayers: [CALayer] = []
    private var currentKey: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(isDark: Bool, intensity: Double, energy: Double, animates: Bool) {
        // Rebuilding is comparatively costly, so only do it when something that
        // actually affects the imagery changed.
        let key = "\(isDark)-\(String(format: "%.2f", intensity))-\(String(format: "%.2f", energy))-\(animates)"
        guard key != currentKey else { return }
        currentKey = key

        wantsLayer = true
        guard let host = layer else { return }

        fieldLayers.forEach { $0.removeFromSuperlayer() }
        fieldLayers = []

        let colors: [NSColor] = [
            NSColor(Palette.jade),
            NSColor(Palette.cyan),
            NSColor(isDark ? Color(hex: 0x5B6BF0) : Color(hex: 0x8FA0FF)),
        ]
        let opacities: [Double] = isDark ? [0.62, 0.54, 0.42] : [0.34, 0.28, 0.22]

        for index in 0 ..< Self.specs.count {
            let layer = CALayer()
            layer.contents = RadialFieldImage.tinted(colors[index])
            layer.contentsGravity = .resize
            layer.opacity = Float(min(1, opacities[index] * intensity + energy * 0.14))
            layer.masksToBounds = false
            layer.allowsEdgeAntialiasing = false
            host.addSublayer(layer)
            fieldLayers.append(layer)
        }

        layoutFields(animates: animates, energy: energy)
    }

    override func layout() {
        super.layout()
        layoutFields(animates: currentKey.hasSuffix("true"), energy: 0, preservingAnimation: true)
    }

    private func layoutFields(
        animates: Bool,
        energy: Double,
        preservingAnimation: Bool = false
    ) {
        guard !fieldLayers.isEmpty, bounds.width > 0, bounds.height > 0 else { return }

        let width = bounds.width
        let height = bounds.height
        let unit = max(width, height)
        let centre = CGPoint(x: width / 2, y: height / 2)

        for (index, layer) in fieldLayers.enumerated() {
            let spec = Self.specs[index]
            let size = unit * spec.scale

            // Geometry changes must not animate; only the drift should.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            layer.position = CGPoint(
                x: centre.x + spec.from.x * width,
                y: centre.y + spec.from.y * height
            )
            CATransaction.commit()

            layer.removeAnimation(forKey: "drift")
            guard animates else { continue }

            let animation = CABasicAnimation(keyPath: "position")
            animation.fromValue = CGPoint(
                x: centre.x + spec.from.x * width,
                y: centre.y + spec.from.y * height
            )
            animation.toValue = CGPoint(
                x: centre.x + spec.to.x * width,
                y: centre.y + spec.to.y * height
            )
            animation.duration = spec.period * (1 - energy * 0.45)
            animation.autoreverses = true
            animation.repeatCount = .greatestFiniteMagnitude
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Stagger the start so the three fields are never in phase, even on
            // the very first cycle.
            animation.timeOffset = spec.period * Double(index) * 0.37
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "drift")
        }
    }
}

/// Pre-rendered radial falloff, cached per tint.
///
/// Rendering the gradient once per colour turns each field into a plain textured
/// layer that the render server can move with no rasterisation work.
enum RadialFieldImage {
    private static var cache: [String: CGImage] = [:]
    private static let lock = NSLock()

    static func tinted(_ color: NSColor) -> CGImage? {
        let rgb = color.usingColorSpace(.sRGB) ?? .white
        let key = String(
            format: "%.3f-%.3f-%.3f",
            rgb.redComponent, rgb.greenComponent, rgb.blueComponent
        )

        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }

        guard let image = render(rgb) else { return nil }
        cache[key] = image
        return image
    }

    private static func render(_ color: NSColor, side: Int = 512) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let red = color.redComponent
        let green = color.greenComponent
        let blue = color.blueComponent

        // A three-stop falloff to fully transparent, so the edge is soft without
        // needing a blur filter.
        let colors = [
            CGColor(srgbRed: red, green: green, blue: blue, alpha: 1),
            CGColor(srgbRed: red, green: green, blue: blue, alpha: 0.42),
            CGColor(srgbRed: red, green: green, blue: blue, alpha: 0),
        ] as CFArray

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: colors,
            locations: [0, 0.36, 1]
        ) else { return nil }

        let centre = CGPoint(x: Double(side) / 2, y: Double(side) / 2)
        context.drawRadialGradient(
            gradient,
            startCenter: centre,
            startRadius: 0,
            endCenter: centre,
            endRadius: Double(side) / 2,
            options: []
        )
        return context.makeImage()
    }
}

/// Static noise, rasterised once and tiled.
///
/// Grain breaks up gradient banding and gives flat surfaces a hint of material.
/// Building it as an `NSImage` a single time means it costs one texture upload
/// for the life of the process instead of a Canvas pass per frame.
struct GrainOverlay: View {
    var opacity: Double = 0.035

    var body: some View {
        Image(nsImage: GrainTile.shared)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }
}

enum GrainTile {
    /// 128×128 tile. Large enough that repetition is invisible at this opacity,
    /// small enough to stay resident in cache.
    static let shared: NSImage = make(side: 128)

    private static func make(side: Int) -> NSImage {
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: side * side * bytesPerPixel)
        var generator = SplitMix64(seed: 0x9E37_79B9_7F4A_7C15)

        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            // Centred noise: values above and below mid-grey, so `overlay`
            // blending both lifts and deepens rather than only brightening.
            let value = generator.nextUnit()
            let level = UInt8(max(0, min(255, 128 + (value - 0.5) * 190)))
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

/// Small, fast, seedable PRNG so the grain is identical between launches.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
