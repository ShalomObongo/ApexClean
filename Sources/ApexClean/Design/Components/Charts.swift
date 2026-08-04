import SwiftUI

struct Sparkline: View {
    let values: [Double]
    var tint: Color = Palette.jade
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
                    with: .color(tint.opacity(0.12))
                )
            }

            context.stroke(
                line,
                with: .color(tint),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )

            if let last = points.last {
                let radius = lineWidth * 1.3
                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: last.x - radius,
                            y: last.y - radius,
                            width: radius * 2,
                            height: radius * 2
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
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let middle = CGPoint(
                x: (previous.x + current.x) / 2,
                y: (previous.y + current.y) / 2
            )
            path.addQuadCurve(to: middle, control: previous)
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

struct RingGauge: View {
    let value: Double
    var tint: Color = Palette.jade
    var thickness: CGFloat = 6
    var trackOpacity: Double = 1

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    Palette.contour(scheme).opacity(0.16 * trackOpacity),
                    lineWidth: thickness
                )
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: thickness, lineCap: .butt)
                )
                .rotationEffect(.degrees(-90))
        }
        .animation(Motion.stream, value: value)
    }
}

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
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Palette.contour(scheme).opacity(0.14))

                HStack(spacing: 0) {
                    Rectangle()
                        .fill(tint)
                        .frame(width: max(0, width * keptFraction))

                    if releaseFraction > 0 {
                        Rectangle()
                            .fill(Palette.caution)
                            .frame(width: max(0, width * releaseFraction))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
        }
        .frame(height: height)
        .animation(Motion.stream, value: pendingRelease)
        .animation(Motion.stream, value: used)
    }
}

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

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let totalValue = max(1, Double(total))

            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    let fraction = Double(segment.bytes) / totalValue
                    let dimmed = highlighted != nil && highlighted != segment.id
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(segment.color)
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
