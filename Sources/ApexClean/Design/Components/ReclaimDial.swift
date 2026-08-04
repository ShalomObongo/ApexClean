import ApexCore
import SwiftUI

/// Segmented storage map used by Smart Care.
struct ReclaimDial: View {
    enum Phase: Equatable {
        case idle
        case scanning(progress: Double, label: String)
        case results
        case clean
    }

    let phase: Phase
    let segments: [(id: String, bytes: Int64)]
    let totalBytes: Int64
    var diameter: CGFloat = 230
    var highlighted: String?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private let thickness: CGFloat = 20
    private let gapDegrees: Double = 3.2

    var body: some View {
        ZStack {
            track
            if case .scanning = phase {
                scanningArc
            } else {
                segmentArcs
            }
            centre
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            withAnimation(Motion.respectingReduceMotion(Motion.stage, reduceMotion)) {
                appeared = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var track: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.surfaceRaised(scheme), lineWidth: thickness)
            Circle()
                .strokeBorder(Palette.contour(scheme), lineWidth: 1.2)
        }
    }

    private var scanningArc: some View {
        let progress: Double = {
            if case let .scanning(value, _) = phase { return value }
            return 0
        }()

        return Circle()
            .trim(from: 0, to: max(0.02, progress))
            .stroke(
                Palette.dustyBlue,
                style: StrokeStyle(lineWidth: thickness, lineCap: .butt)
            )
            .rotationEffect(.degrees(-90))
            .animation(Motion.stream, value: progress)
    }

    private var segmentArcs: some View {
        let total = max(1, Double(totalBytes))
        var cursor = 0.0

        return ZStack {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                let fraction = Double(segment.bytes) / total
                let start = cursor
                let end = cursor + fraction
                let colour = Palette.category(segment.id)
                let dimmed = highlighted != nil && highlighted != segment.id

                Circle()
                    .trim(from: start, to: max(start, end - gapFraction))
                    .stroke(
                        colour,
                        style: StrokeStyle(
                            lineWidth: highlighted == segment.id ? thickness + 4 : thickness,
                            lineCap: .butt
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .opacity(appeared ? (dimmed ? 0.22 : 1) : 0)
                    .animation(
                        Motion.respectingReduceMotion(
                            Motion.settle.delay(Motion.stagger(index, step: 0.05)),
                            reduceMotion
                        ),
                        value: appeared
                    )
                    .animation(Motion.tactile, value: highlighted)

                let _ = cursor = end
            }
        }
    }

    private var gapFraction: Double {
        segments.count > 1 ? gapDegrees / 360 : 0
    }

    @ViewBuilder
    private var centre: some View {
        VStack(spacing: 5) {
            switch phase {
            case .idle:
                Image(systemName: "scope")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Palette.info)
                Text("Ready")
                    .font(Typo.metric(17))
                    .foregroundStyle(Palette.ink(scheme))

            case let .scanning(progress, label):
                Text("\(Int(progress * 100))%")
                    .font(Typo.metric(30, weight: .bold))
                    .foregroundStyle(Palette.ink(scheme))
                    .contentTransition(.numericText())
                Text(label)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: diameter * 0.56)

            case .results:
                Image(systemName: "square.grid.3x3.topleft.filled")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(Palette.info)
                Text("Mapped")
                    .font(Typo.metric(16))
                    .foregroundStyle(Palette.ink(scheme))

            case .clean:
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Palette.positive)
                Text("Clear")
                    .font(Typo.metric(16))
                    .foregroundStyle(Palette.ink(scheme))
            }
        }
        .frame(width: diameter - thickness * 3)
    }

    private var accessibilityDescription: String {
        switch phase {
        case .idle: "Ready to scan"
        case let .scanning(progress, label):
            "Scanning, \(Int(progress * 100)) percent complete, currently \(label)"
        case .results: "\(Bytes.format(totalBytes)) reclaimable across \(segments.count) categories"
        case .clean: "Nothing to clean"
        }
    }
}
