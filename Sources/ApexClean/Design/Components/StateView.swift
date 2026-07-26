import SwiftUI

/// The one component every screen uses when it has nothing to show.
///
/// A blank pane is the most common failure in utility apps: the user cannot
/// tell whether the app is working, broken, or simply found nothing. Routing
/// every such moment through one component means each of those three states is
/// always distinguishable and always says what happens next.
struct StateView: View {
    enum Kind {
        /// Work is in progress. Shows a determinate-feeling spinner.
        case working(String)
        /// Nothing to show, and that is the expected outcome.
        case empty(symbol: String, title: String, message: String)
        /// Something is available but requires an explicit action first.
        case idle(symbol: String, title: String, message: String)
    }

    let kind: Kind
    var action: (title: String, symbol: String, run: () -> Void)?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 15) {
            Spacer(minLength: 40)

            switch kind {
            case .working(let message):
                ProgressView()
                    .controlSize(.large)
                    .padding(.bottom, 2)
                Text(message)
                    .font(Typo.body)
                    .foregroundStyle(Palette.inkSecondary(scheme))

            case .empty(let symbol, let title, let message),
                .idle(let symbol, let title, let message):
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(
                        isIdle
                            ? AnyShapeStyle(Palette.accentGradient)
                            : AnyShapeStyle(Palette.inkTertiary(scheme)))
                Text(title)
                    .font(Typo.metric(18))
                    .foregroundStyle(Palette.ink(scheme))
                Text(message)
                    .font(Typo.body)
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 430)

                if let action {
                    ApexButton(title: action.title, symbol: action.symbol, size: .large, action: action.run)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var isIdle: Bool {
        if case .idle = kind { return true }
        return false
    }
}
