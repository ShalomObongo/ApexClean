import ApexCore
import SwiftUI

/// The signature hero.
///
/// A segmented ring where every arc is one cleanup category, sized by its share
/// of the total. It is a *chart*, not decoration: the ring answers "what is this
/// number made of?" at a glance, and the same colours carry into the group list
/// below so the mapping is learnable.
struct ReclaimDial: View {
    enum Phase: Equatable {
        case idle
        case scanning(progress: Double, label: String)
        case results
        case clean
    }

    let phase: Phase
    /// (category id, bytes) pairs, largest first.
    let segments: [(id: String, bytes: Int64)]
    let totalBytes: Int64
    var diameter: CGFloat = 268
    var highlighted: String?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: Double = 0
    @State private var appeared = false

    private let thickness: CGFloat = 15
    private let gapDegrees: Double = 2.4

    var body: some View {
        ZStack {
            track
            if case .scanning = phase { scanningArc } else { segmentArcs }
            centre
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            withAnimation(Motion.respectingReduceMotion(Motion.stage.delay(0.05), reduceMotion)) {
                appeared = true
            }
            startSweepIfNeeded()
        }
        .onChange(of: phase) { _, _ in startSweepIfNeeded() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Layers

    private var track: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.hairline(scheme), lineWidth: thickness)

            // A slowly orbiting accent so the idle ring reads as a dormant
            // instrument rather than an empty placeholder. Rendered by Core
            // Animation, so the orbit costs the app nothing while it runs.
            if case .idle = phase {
                OrbitingArc(
                    sweep: 0.17,
                    period: 14,
                    lineWidth: thickness,
                    color: Palette.jade,
                    animates: !reduceMotion
                )
                .shadow(color: Palette.jade.opacity(0.30), radius: 12)
            }
        }
    }

    /// A single travelling arc with a comet head — reads as "working" without
    /// pretending to know a percentage it does not have.
    private var scanningArc: some View {
        let progress: Double = {
            if case let .scanning(value, _) = phase { return value }
            return 0
        }()

        return ZStack {
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(
                    AngularGradient(
                        colors: [Palette.jade.opacity(0.15), Palette.jade, Palette.cyan],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: thickness, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(Motion.stream, value: progress)

            Circle()
                .trim(from: 0, to: 0.055)
                .stroke(
                    LinearGradient(
                        colors: [Palette.cyan.opacity(0), Palette.cyan],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: thickness * 0.55, lineCap: .round)
                )
                .rotationEffect(.degrees(sweep - 90))
                .blur(radius: 1.5)
                .opacity(reduceMotion ? 0 : 0.85)
        }
        .shadow(color: Palette.jade.opacity(0.35), radius: 16)
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
                        LinearGradient(
                            colors: [colour, colour.mixed(with: Palette.cyan, amount: 0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(
                            lineWidth: highlighted == segment.id ? thickness + 4 : thickness, lineCap: .butt)
                    )
                    .rotationEffect(.degrees(-90))
                    .opacity(appeared ? (dimmed ? 0.24 : 1) : 0)
                    .shadow(color: colour.opacity(dimmed ? 0 : 0.4), radius: 10)
                    .animation(
                        Motion.respectingReduceMotion(
                            Motion.settle.delay(Motion.stagger(index, step: 0.06)),
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
        VStack(spacing: 3) {
            switch phase {
            case .idle:
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Palette.accentGradient)
                Text("Ready")
                    .font(Typo.metric(19))
                    .foregroundStyle(Palette.ink(scheme))
                Text("Scan to see what can be reclaimed")
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .multilineTextAlignment(.center)
                    .frame(width: diameter * 0.62)

            case let .scanning(_, label):
                Text("Examining")
                    .eyebrowStyle(scheme)
                Text(Bytes.format(totalBytes))
                    .font(Typo.metric(38, weight: .bold))
                    .foregroundStyle(Palette.ink(scheme))
                    .contentTransition(.numericText())
                Text(label)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: diameter * 0.60)

            case .results:
                Text("Reclaimable")
                    .eyebrowStyle(scheme)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Bytes.parts(totalBytes).value)
                        .font(Typo.metric(46, weight: .bold))
                        .foregroundStyle(Palette.ink(scheme))
                        .contentTransition(.numericText())
                    Text(Bytes.parts(totalBytes).unit)
                        .font(Typo.metric(19, weight: .semibold))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                }
                Text("Review before anything is removed")
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .multilineTextAlignment(.center)
                    .frame(width: diameter * 0.66)

            case .clean:
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Palette.accentGradient)
                    .shadow(color: Palette.jade.opacity(0.5), radius: 18)
                Text("Nothing to clean")
                    .font(Typo.metric(18))
                    .foregroundStyle(Palette.ink(scheme))
                Text("Your Mac is in good shape")
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
        }
        .frame(width: diameter - thickness * 3)
    }

    // MARK: - Behaviour

    private func startSweepIfNeeded() {
        guard !reduceMotion, case .scanning = phase else {
            sweep = 0
            return
        }
        sweep = 0
        withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
            sweep = 360
        }
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
