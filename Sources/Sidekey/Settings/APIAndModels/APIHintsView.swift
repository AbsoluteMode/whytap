import SwiftUI

/// Editorial guidance only: opening hints never checks balances or changes a route.
/// WHY: .project-docs/decisions/2026-10-19-api-hints.md
@MainActor
struct APIHintsView: View {
    let onAddKey: () -> Void
    let onClose: () -> Void
    var embedded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("API hints")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text)
                Text("Free tiers and credits for the providers you connect.")
                    .font(.system(size: 13))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
            .padding(24)
            .padding(.bottom, 2)

            GeometryReader { geometry in
                let columns = geometry.size.width >= 560 ? 2 : 1
                ScrollView {
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        ForEach(Array(stride(from: 0, to: Self.hints.count, by: columns)), id: \.self) { index in
                            GridRow {
                                offerCard(Self.hints[index])
                                    .gridCellColumns(index + 1 == Self.hints.count ? columns : 1)
                                if columns == 2, index + 1 < Self.hints.count {
                                    offerCard(Self.hints[index + 1])
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, embedded ? 24 : 16)
                }
            }

            // The tab shows only the offers: the user removed its footer on 2026-11-19.
            if !embedded { footer }
        }
        .background(embedded ? MacSettingsTheme.bgCard : Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onClose)
    }

    private func offerCard(_ hint: Hint) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Group {
                    if let assetName = hint.assetName {
                        ProviderBrandIcon(assetName: assetName, size: 18, color: MacSettingsTheme.text)
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 18))
                            .foregroundStyle(MacSettingsTheme.text)
                    }
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
                .background(MacSettingsTheme.hover, in: RoundedRectangle(cornerRadius: 8))
                Text(hint.provider)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text)
                Spacer(minLength: 4)
                if hint.requiresPaidPlan {
                    Text("Paid plan")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(MacSettingsTheme.hover, in: Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(hint.allowance)
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(MacSettingsTheme.text)
                Text(hint.cadence)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
            .padding(.top, 17)

            Text(hint.detail)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 11)

            Spacer(minLength: 16)

            HStack(alignment: .center, spacing: 8) {
                OfferLink(provider: hint.provider, url: hint.url)
                Spacer(minLength: 0)
            }
            Text("Checked \(hint.checkedDate)")
                .font(.system(size: 10.5))
                .foregroundStyle(MacSettingsTheme.text2)
                .padding(.top, 7)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity, alignment: .topLeading)
        .background(MacSettingsTheme.bgCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add keys in API keys. Choose language and speech models in Models; Tavily provides web search for Agent.")
                .font(.system(size: 11.5))
                .foregroundStyle(MacSettingsTheme.text2)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Provider terms, limits and billing settings apply.")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(MacSettingsTheme.text2)
                Spacer(minLength: 16)
                MacButton(title: "Add API key", style: .default, action: onAddKey)
                MacButton(title: "Done", style: .primary, action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .overlay(alignment: .top) {
            Rectangle().fill(MacSettingsTheme.sep).frame(height: 0.5)
        }
    }

    private struct Hint {
        let provider: String
        let assetName: String?
        let allowance: String
        let cadence: String
        let detail: String
        let url: URL
        var requiresPaidPlan = false
        var checkedDate = "October 19, 2026"
    }

    // Keep amounts and the visible verification date together when refreshing offers.
    private static let hints: [Hint] = [
        Hint(
            provider: "Deepgram",
            assetName: "deepgram",
            allowance: "$200",
            cadence: "one-time starter credit",
            detail: "Speech recognition credit for new accounts. No card needed to start.",
            url: URL(string: "https://deepgram.com/pricing")!
        ),
        Hint(
            provider: "ElevenLabs",
            assetName: "elevenlabs",
            allowance: "10,000",
            cadence: "free credits each month",
            detail: "The Free plan includes API access. Check Scribe's allowance: realtime and batch audio have different quotas.",
            url: URL(string: "https://elevenlabs.io/pricing/api")!
        ),
        Hint(
            provider: "OpenRouter",
            assetName: "openrouter",
            allowance: "50 / day",
            cadence: "free model requests",
            detail: "Choose a :free model. Limit: 20 requests a minute. Tool support and availability vary; agent turns may use several requests.",
            url: URL(string: "https://openrouter.ai/models?max_price=0")!
        ),
        Hint(
            provider: "Claude Max",
            assetName: "claude-code",
            allowance: "$100–200",
            cadence: "API credit each month",
            detail: "Max 5x: $100; Max 20x: $200. After seven days, link a Console organization in Claude's billing settings. Use its Anthropic key for Agent. Credits expire each cycle.",
            url: URL(string: "https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-and-team-plans")!,
            requiresPaidPlan: true
        ),
        Hint(
            provider: "Tavily",
            assetName: nil,
            allowance: "1,000",
            cadence: "free search credits each month",
            detail: "Web search for Agent. No card required. One basic search uses one credit. Add the Tavily key in API keys.",
            url: URL(string: "https://www.tavily.com/pricing")!,
            checkedDate: "October 22, 2026"
        ),
    ]

    private struct OfferLink: View {
        let provider: String
        let url: URL
        @Environment(\.isEnabled) private var enabled
        @FocusState private var focused: Bool

        var body: some View {
            Link(destination: url) {
                HStack(spacing: 4) {
                    Text("View offer")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(MacSettingsTheme.accent)
                .padding(.horizontal, 7).padding(.vertical, 5)
            }
            .buttonStyle(MacButtonInteractionStyle(background: .clear,
                highlight: MacSettingsTheme.accent, outline: MacSettingsTheme.accent, focused: focused))
            .focused($focused)
            .opacity(enabled ? 1 : 0.42)
            .accessibilityLabel("\(provider) offer details")
            .accessibilityHint("Opens the provider's website in your browser")
        }
    }
}
