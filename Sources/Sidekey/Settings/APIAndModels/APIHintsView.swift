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
                Text("Reviewed monthly · Last checked \(Self.lastChecked)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .padding(.top, 2)
            }
            .padding(24)
            .padding(.bottom, 2)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Category.allCases, id: \.self) { category in
                        section(category)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, embedded ? 24 : 16)
            }

            // The tab shows only the offers: the user removed its footer on 2026-11-19.
            if !embedded { footer }
        }
        .background(embedded ? MacSettingsTheme.bgCard : Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: onClose)
    }

    private func section(_ category: Category) -> some View {
        let offers = Self.hints.filter { $0.category == category }
        return VStack(alignment: .leading, spacing: 8) {
            Text(category.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text2)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(offers.enumerated()), id: \.element.provider) { index, hint in
                    if index > 0 {
                        Rectangle().fill(MacSettingsTheme.sep).frame(height: 1).padding(.leading, 54)
                    }
                    OfferRow(hint: hint)
                }
            }
            .background(MacSettingsTheme.bgCard, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 0.5)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add keys in API keys. Choose language and speech models in Models. Agent searches the web with its Anthropic, OpenAI or OpenRouter model, about $10 per 1,000 searches plus result tokens; Tavily serves other models, or when chosen in Models → Search.")
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

    enum Category: CaseIterable {
        case speech, models, search

        var title: String {
            switch self {
            case .speech: "Speech to text"
            case .models: "Language models"
            case .search: "Web search"
            }
        }
    }

    /// What it takes to start using the allowance. Rows keep this order within a category.
    enum Access {
        case noCard, cardRequired, paidPlan

        var label: String {
            switch self {
            case .noCard: "No card needed"
            case .cardRequired: "Card required"
            case .paidPlan: "Paid plan"
            }
        }
    }

    struct Hint {
        let category: Category
        let provider: String
        let assetName: String?
        let allowance: String
        let cadence: String
        let access: Access
        let detail: String
        let url: URL
        /// ISO day the offer was last compared with its official source.
        var checked = "2026-10-19"

        var checkedDate: String { APIHintsView.displayDate(checked) }
    }

    // Keep amounts and the verification date together when refreshing offers.
    // The header promises a monthly review and shows the newest date below.
    // README's "Free to use" cards is generated from the no-card offers here:
    // run scripts/readme-free-apis.py after changing them.
    // WHY: .project-docs/decisions/2026-11-21-free-api-report.md
    static let hints: [Hint] = [
        Hint(
            category: .speech,
            provider: "Deepgram",
            assetName: "deepgram",
            allowance: "$200",
            cadence: "one-time starter credit",
            access: .noCard,
            detail: "Speech recognition credit for new accounts. It does not expire. No card needed to start.",
            url: URL(string: "https://deepgram.com/pricing")!,
            checked: "2026-11-21"
        ),
        Hint(
            category: .speech,
            provider: "ElevenLabs",
            assetName: "elevenlabs",
            allowance: "10,000",
            cadence: "free credits each month",
            access: .noCard,
            detail: "The Free plan includes Speech to Text, for non-commercial use with attribution. Speech to Text spends credits per minute of audio.",
            url: URL(string: "https://elevenlabs.io/pricing")!,
            checked: "2026-11-21"
        ),
        Hint(
            category: .models,
            provider: "OpenRouter",
            assetName: "openrouter",
            allowance: "50 / day",
            cadence: "free model requests",
            access: .noCard,
            detail: "Choose a :free model. Limit: 20 requests a minute; buying $10 of credit once raises the daily limit to 1,000. Tool support and availability vary; agent turns may use several requests.",
            url: URL(string: "https://openrouter.ai/models?max_price=0")!,
            checked: "2026-11-21"
        ),
        // List only offers whose key works in Whytap as it is: Groq and Cloudflare
        // wait for their own provider support (user decision, 2026-11-19).
        Hint(
            category: .models,
            provider: "Claude Max & Ultra",
            assetName: "claude-code",
            allowance: "$100–200",
            cadence: "API credit each month",
            access: .paidPlan,
            detail: "Max includes $100 and Ultra includes $200. After seven days, link a Console organization in Claude's billing settings. Use its Anthropic key for Agent. Credits expire each cycle.",
            url: URL(string: "https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-ultra-and-team-plans")!,
            checked: "2026-11-21"
        ),
        Hint(
            category: .models,
            provider: "ChatGPT Pro",
            assetName: "openai",
            allowance: "$100–500",
            cadence: "API credit each month",
            access: .paidPlan,
            detail: "Pro tiers: $100, $200 or $500; Business: up to $500 per workspace. After seven days, claim it in ChatGPT's billing settings and link an API organization you own. Use its OpenAI key for Agent. Credits expire each cycle.",
            url: URL(string: "https://developers.openai.com/api/docs/guides/chatgpt-api-credits")!,
            checked: "2026-11-21"
        ),
        Hint(
            category: .search,
            provider: "Tavily",
            assetName: "tavily",
            allowance: "1,000",
            cadence: "free search credits each month",
            access: .noCard,
            detail: "Web search for Agent with a model that has no search of its own, or when chosen in Models → Search. No card required. One basic search uses one credit. Add the Tavily key in API keys.",
            url: URL(string: "https://www.tavily.com/pricing")!,
            checked: "2026-11-21"
        ),
    ]

    /// The newest verification date among the offers; each row's own date is in its details.
    static var lastChecked: String { displayDate(hints.map(\.checked).max() ?? "") }

    nonisolated static func displayDate(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        parser.dateFormat = "MMMM d, yyyy"
        return parser.string(from: date)
    }

    /// One offer: logo, provider and what it takes to start, the allowance, and
    /// Get offer. Details open beside the button on hover or keyboard focus, so
    /// they never cover the button or the row being read.
    private struct OfferRow: View {
        let hint: Hint
        @Environment(\.openURL) private var openURL
        @Environment(\.isEnabled) private var isEnabled
        @State private var shown = false
        @State private var hovered = false
        @State private var closeTask: Task<Void, Never>?
        @FocusState private var focused: Bool

        var body: some View {
            HStack(spacing: 12) {
                Group {
                    if let assetName = hint.assetName {
                        ProviderBrandIcon(assetName: assetName, size: 17, color: MacSettingsTheme.text)
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 17))
                            .foregroundStyle(MacSettingsTheme.text)
                    }
                }
                .frame(width: 30, height: 30)
                .background(MacSettingsTheme.hover, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hint.provider)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text)
                    Text(hint.access.label)
                        .font(.system(size: 11.5, weight: hint.access == .noCard ? .regular : .medium))
                        .foregroundStyle(hint.access == .noCard ? MacSettingsTheme.text2 : MacSettingsTheme.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hint.allowance)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(MacSettingsTheme.text)
                    Text(hint.cadence)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacSettingsTheme.text2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { openURL(hint.url) } label: {
                    HStack(spacing: 4) {
                        Text("Get offer")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
                .buttonStyle(MacButtonInteractionStyle(background: MacSettingsTheme.controlBg, focused: focused))
                .focused($focused)
                .onHover { inside in
                    hovered = inside && isEnabled
                    closeTask?.cancel()
                    if hovered { shown = true } else { scheduleClose() }
                }
                .onChange(of: focused) { _, value in
                    if value { shown = true } else { scheduleClose() }
                }
                .popover(isPresented: $shown, arrowEdge: .trailing) {
                    details.onExitCommand { shown = false }
                }
                .accessibilityLabel("Get \(hint.provider) offer")
                .accessibilityHint("\(hint.detail) Checked \(hint.checkedDate). Opens the provider's website in your browser.")
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .accessibilityElement(children: .contain)
            .onDisappear { closeTask?.cancel() }
        }

        private var details: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(hint.provider)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text)
                Text(hint.detail)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(MacSettingsTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Checked \(hint.checkedDate)")
                    .font(.system(size: 11))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
        }

        private func scheduleClose() {
            closeTask?.cancel()
            closeTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, !hovered, !focused else { return }
                shown = false
            }
        }
    }
}
