import AppKit
import SwiftUI

/// Reusable glass window frame for Sidekey's secondary windows.
/// The matching `NSWindow` must be transparent and full-size-content;
/// `SidekeyWindowChrome.configure(_:)` owns that AppKit edge.
@MainActor
struct SidekeyAuroraWindow<Content: View>: View {
    let title: String
    var showsTitleBar: Bool = true
    @ViewBuilder var content: Content

    private let haloPadding: CGFloat = 0
    private let cornerRadius: CGFloat = 14
    private let titleBarHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            if showsTitleBar {
                SidekeyAuroraTitleBar(title: title, height: titleBarHeight)
            }
            content
        }
        .background(glassFill)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .padding(haloPadding)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var glassFill: some View {
        ZStack {
            // Behind-window vibrancy — shows desktop content through the window
            IslandVisualEffectBackground(material: .popover)
            // Dark tint overlay: keep ~0.40 opacity so the material is visible
            LinearGradient(
                colors: [
                    Color(red: 28 / 255, green: 28 / 255, blue: 34 / 255).opacity(0.38),
                    Color(red: 18 / 255, green: 18 / 255, blue: 24 / 255).opacity(0.50)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

}

@MainActor
private struct SidekeyAuroraTitleBar: View {
    let title: String
    let height: CGFloat

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.80))
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(.white.opacity(0.06)),
            alignment: .bottom
        )
    }
}
