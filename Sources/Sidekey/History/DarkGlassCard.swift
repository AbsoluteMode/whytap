import SwiftUI

/// Dark Liquid Glass card background. Uses `.ultraThinMaterial` plus a
/// dark wash overlay so the card reads against both light and dark
/// wallpapers. macOS 26 `.glassEffect` was removed in round 2 — CI's
/// Xcode does not expose the symbol so the conditional `#available`
/// branch was failing to compile (the API is referenced at parse time
/// regardless of `#available`). When CI gains a Tahoe Xcode the native
/// effect can be reintroduced behind a feature flag.
///
/// Used as the visual base for both strip cards
/// (`HistoryCardView`) and the centered expanded panel
/// (`HistoryExpandedView`). Size + corner radius are configurable so
/// the same primitive serves cards inside the strip (compact, ~280pt
/// wide) and the centered expanded view (~700pt wide).
///
/// NOTE: no drop shadow. ROO-208 iters 5-11 chased a phantom grey
/// "ribbon" around the cards row through every plausible layer
/// (NSPanel chrome, SwiftUI ScrollView, NSScrollView, NSClipView,
/// NSHostingView backing layer) — none was the culprit. The actual
/// cause was a `.shadow(...)` modifier bleeding between adjacent cards:
/// with 12pt inter-card spacing in `HistoryStripCardsRowView` even a
/// tight halo overlapped neighbours and formed a continuous
/// row-spanning haze that looked exactly like a single rounded ribbon.
/// Iter 12 removed the shadow entirely on Maxim's call — depth cue now
/// comes from the 1px white-gradient stroke border +
/// `.ultraThinMaterial` + `.black.opacity(0.25)` overlay alone. Do not
/// re-add `.shadow(...)` here.
struct DarkGlassCard<Content: View>: View {
    var width: CGFloat?
    var height: CGFloat?
    var cornerRadius: CGFloat = 28
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content()
            .frame(width: width, height: height)
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(.black.opacity(0.25)))
            }
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.55),
                                .white.opacity(0.10),
                                .white.opacity(0.30),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .clipShape(shape)
    }
}
