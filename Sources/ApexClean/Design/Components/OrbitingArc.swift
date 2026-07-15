import SwiftUI
import AppKit
import QuartzCore

/// A continuously rotating arc, driven by Core Animation.
///
/// Anything that spins forever has to live outside SwiftUI's animation system.
/// A SwiftUI `rotationEffect` animation invalidates layout on every display
/// cycle for as long as it runs, which for a permanent idle flourish is several
/// percent of a core — an unacceptable trade for decoration. A `CABasicAnimation`
/// on a shape layer is handed to the render server and costs the app nothing
/// once installed.
struct OrbitingArc: NSViewRepresentable {
    /// Fraction of the circle the arc covers, 0…1.
    var sweep: Double = 0.16
    /// Seconds per full revolution.
    var period: Double = 12
    var lineWidth: CGFloat = 15
    var color: Color = Palette.jade
    var animates: Bool = true

    func makeNSView(context: Context) -> OrbitingArcNSView {
        let view = OrbitingArcNSView()
        view.apply(sweep: sweep, period: period, lineWidth: lineWidth, color: color, animates: animates)
        return view
    }

    func updateNSView(_ view: OrbitingArcNSView, context: Context) {
        view.apply(sweep: sweep, period: period, lineWidth: lineWidth, color: color, animates: animates)
    }
}

final class OrbitingArcNSView: NSView {
    private let container = CALayer()
    private let arc = CAShapeLayer()
    private let gradient = CAGradientLayer()
    private var signature = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(container)
        container.addSublayer(gradient)
        // The gradient supplies the colour; the arc supplies the shape. Masking
        // one with the other gives a stroke that fades along its own length.
        gradient.mask = arc
        arc.fillColor = nil
        // A mask layer is read for coverage, not colour, but CAShapeLayer draws
        // nothing at all without a stroke colour — so an opaque one is required
        // even though the visible colour comes entirely from the gradient.
        arc.strokeColor = NSColor.black.cgColor
        arc.lineCap = .round
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(sweep: Double, period: Double, lineWidth: CGFloat, color: Color, animates: Bool) {
        let key = "\(sweep)-\(period)-\(lineWidth)-\(color.description)-\(animates)"
        guard key != signature else { return }
        signature = key

        arc.lineWidth = lineWidth
        arc.strokeEnd = CGFloat(max(0.01, min(1, sweep)))

        let base = NSColor(color)
        gradient.type = .axial
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [
            base.withAlphaComponent(0.0).cgColor,
            base.withAlphaComponent(0.65).cgColor,
        ]

        layoutArc(period: period, animates: animates)
    }

    override func layout() {
        super.layout()
        layoutArc(period: nil, animates: nil)
    }

    private func layoutArc(period: Double?, animates: Bool?) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        container.frame = bounds
        gradient.frame = bounds

        let inset = arc.lineWidth / 2
        let radius = (min(bounds.width, bounds.height) - arc.lineWidth) / 2
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        // Start at 12 o'clock and sweep clockwise, matching the direction the
        // scan progress arc travels.
        path.addArc(
            center: centre,
            radius: max(1, radius),
            startAngle: .pi / 2,
            endAngle: .pi / 2 - .pi * 2,
            clockwise: true
        )
        arc.path = path
        arc.frame = bounds
        _ = inset

        CATransaction.commit()

        guard let period, let animates else { return }
        container.removeAnimation(forKey: "orbit")
        guard animates else { return }

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -Double.pi * 2
        rotation.duration = period
        rotation.repeatCount = .greatestFiniteMagnitude
        rotation.isRemovedOnCompletion = false
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        container.frame = bounds
        container.add(rotation, forKey: "orbit")
    }
}
