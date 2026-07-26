import SwiftUI

/// Filled line chart for a rolling series. Drawn with a Catmull-Rom style smooth
/// so a 2-second sampling cadence does not look like a sawtooth.
///
/// Deliberately a single `Canvas` rather than a `GeometryReader` wrapping
/// stacked `Shape` views. Sampling publishes four times a minute-and-a-half of
/// history, and with a view-tree implementation every one of those updates
/// re-ran layout for the whole page — profiling put SwiftUI's stack layout at
/// the top of the main thread. A Canvas is one leaf: it draws, it never lays
/// out, and the live dashboard stops costing what it measures.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = Palette.jade
    /// Fixed ceiling. When nil, the chart auto-scales to its own maximum.
    var ceiling: Double? = nil
    var lineWidth: CGFloat = 1.6
    var showsFill: Bool = true

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard values.count > 1 else { return }
            let maximum = ceiling ?? max(values.max() ?? 1, 0.0001)
            let points = normalizedPoints(in: size, maximum: maximum)
            guard points.count > 1 else { return }
            let line = linePath(points)

            if showsFill {
                context.fill(
                    fillPath(line, points: points, in: size),
                    with: .linearGradient(
                        Gradient(colors: [tint.opacity(0.34), tint.opacity(0.02)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
            }

            context.stroke(
                line,
                with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.55), tint]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )

            if let last = points.last {
                let radius = lineWidth * 1.3
                // A drawn halo instead of a shadow filter: the same read at a
                // fraction of the cost, and it never triggers offscreen passes.
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: last.x - radius * 2.4, y: last.y - radius * 2.4,
                        width: radius * 4.8, height: radius * 4.8
                    )),
                    with: .color(tint.opacity(0.22))
                )
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: last.x - radius, y: last.y - radius,
                        width: radius * 2, height: radius * 2
                    )),
                    with: .color(tint)
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func normalizedPoints(in size: CGSize, maximum: Double) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let inset = lineWidth
        let usableHeight = max(1, size.height - inset * 2)
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let ratio = min(1, max(0, value / maximum))
            return CGPoint(
                x: CGFloat(index) * step,
                y: inset + usableHeight * (1 - CGFloat(ratio))
            )
        }
    }

    private func linePath(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: points[0])
        // Midpoint quadratic smoothing: cheap, stable, and never overshoots the
        // data the way a naive cubic spline can.
        for index in 1 ..< points.count {
            let previous = points[index - 1]
            let current = points[index]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private func fillPath(_ line: Path, points: [CGPoint], in size: CGSize) -> Path {
        var path = line
        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
        path.addLine(to: CGPoint(x: points[0].x, y: size.height))
        path.closeSubpath()
        return path
    }
}

/// Circular gauge for a bounded 0…1 value.
struct RingGauge: View {
    let value: Double
    var tint: Color = Palette.jade
    var thickness: CGFloat = 6
    var trackOpacity: Double = 1

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.hairline(scheme).opacity(trackOpacity), lineWidth: thickness)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.65), tint],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: thickness, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.4), radius: 5)
        }
        .animation(Motion.stream, value: value)
    }
}

/// Horizontal capacity bar with optional pending-removal segment, so the effect
/// of a selection is visible before it is committed.
struct CapacityBar: View {
    let used: Int64
    let total: Int64
    var pendingRelease: Int64 = 0
    var height: CGFloat = 10
    var tint: Color = Palette.jade

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let totalValue = max(1, Double(total))
            let keptFraction = max(0, Double(used - pendingRelease)) / totalValue
            let releaseFraction = Double(min(pendingRelease, used)) / totalValue

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Palette.hairline(scheme))

                HStack(spacing: 0) {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.75), tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, width * keptFraction))

                    if releaseFraction > 0 {
                        Capsule(style: .continuous)
                            .fill(Palette.caution.opacity(0.85))
                            .frame(width: max(0, width * releaseFraction))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Palette.caution, lineWidth: 0.5)
                            )
                    }
                }
                .clipShape(Capsule(style: .continuous))
            }
        }
        .frame(height: height)
        .animation(Motion.stream, value: pendingRelease)
        .animation(Motion.stream, value: used)
    }
}

/// Multi-segment proportional bar used to break a total into named parts.
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let id: String
        let bytes: Int64
        let color: Color
    }

    let segments: [Segment]
    let total: Int64
    var height: CGFloat = 12
    var highlighted: String?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let totalValue = max(1, Double(total))

            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    let fraction = Double(segment.bytes) / totalValue
                    let dimmed = highlighted != nil && highlighted != segment.id
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [segment.color, segment.color.mixed(with: Palette.cyan, amount: 0.28)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(2, width * fraction))
                        .opacity(dimmed ? 0.25 : 1)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .animation(Motion.tactile, value: highlighted)
    }
}
