import SwiftUI

/// Thin capsule progress bar for the Usage tab (ROO-250 Stage 7). A muted
/// track with a coloured fill whose width and colour both follow the used
/// fraction: accent under 80%, orange at/above 80%, red at/above 100%.
///
/// The fraction clamp and colour selection live in pure static helpers so
/// they are unit-tested without rendering.
struct MacProgressBar: View {
    /// Used / limit, before clamping. Values < 0 or NaN are treated as 0,
    /// values > 1 (over the limit) clamp the fill to full width.
    let fraction: Double

    /// Visual fill state derived from the fraction.
    enum FillTier: Equatable {
        case normal
        case warning
        case over

        var color: Color {
            switch self {
            case .normal: return MacSettingsTheme.accent
            case .warning: return MacSettingsTheme.orange
            case .over: return MacSettingsTheme.red
            }
        }
    }

    /// Warning kicks in at 80% of the budget.
    private static let warningThreshold: Double = 0.8

    /// Clamp an arbitrary fraction into [0, 1], mapping NaN/negative to 0.
    static func clampedFraction(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }

    /// Tier for the (unclamped) fraction. Uses the raw value so an
    /// over-limit fraction (>1) reads `.over` even though the fill is
    /// clamped to full width.
    static func tier(for raw: Double) -> FillTier {
        let value = raw.isFinite ? raw : 0
        if value >= 1.0 { return .over }
        if value >= warningThreshold { return .warning }
        return .normal
    }

    private static let trackHeight: CGFloat = 6

    var body: some View {
        let clamped = Self.clampedFraction(fraction)
        let fillColor = Self.tier(for: fraction).color

        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(0, proxy.size.width * clamped))
            }
        }
        .frame(height: Self.trackHeight)
        .animation(.easeOut(duration: 0.25), value: clamped)
    }
}
