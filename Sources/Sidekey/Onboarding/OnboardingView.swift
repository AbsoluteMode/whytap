import AVFoundation
import SwiftUI

/// Two halves, as in the former paid onboarding: on the left a serif headline,
/// one thought and the page's controls; on the right a stage that shows what
/// the page is about (Drop at work, the switch in System Settings, the note to
/// dictate into, the feature's clip). Always dark, like the island.
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
@MainActor
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var hotkeys = HotkeyPreferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = OnboardingTheme.canvas

    var body: some View {
        let configuration = hotkeys.configuration
        ZStack {
            OnboardingTheme.bg
            Group {
                switch model.page {
                case .speech:
                    OnboardingSpeechPage(model: model, onDevice: model.onDevice, demo: model.demo, configuration: configuration)
                case .permissions:
                    OnboardingPermissionsPage(model: model, permissions: model.permissions, onDevice: model.onDevice)
                case .tryDrop:
                    OnboardingTryPage(model: model, onDevice: model.onDevice, permissions: model.permissions,
                                      configuration: configuration)
                case .customize:
                    OnboardingCustomizePage(model: model)
                case .features:
                    OnboardingFeaturesPage(model: model, codingTools: model.codingTools, configuration: configuration)
                }
            }
            .id(model.page)
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: model.page)
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}

// MARK: - Layout

/// The two halves of a page. The left half reads top to bottom and ends in its
/// actions; the stage fills the rest of the window up to the title bar.
struct OnboardingSplit<Left: View, Footer: View, Stage: View>: View {
    let step: String
    let index: Int
    let count: Int
    /// The speech page holds two cards and takes a little more height.
    var top: CGFloat = 72
    /// Back to the previous page; `nil` on the first page, which has none.
    var back: (() -> Void)?
    @ViewBuilder var left: Left
    @ViewBuilder var footer: Footer
    @ViewBuilder var stage: Stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(step.uppercased()) · \(index + 1) / \(count)")
                    .font(OnboardingTheme.mono(10.5, weight: .medium))
                    .tracking(1.6)
                    .foregroundColor(OnboardingTheme.faint)
                    .padding(.bottom, 18)
                    .accessibilityLabel("Step \(index + 1) of \(count): \(step)")
                left
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    if let back {
                        OnboardingQuietButton(title: "Back", systemImage: "chevron.left", action: back)
                            .help("Back (←)")
                        Spacer(minLength: 0)
                    }
                    footer
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(EdgeInsets(top: top, leading: 40, bottom: 26, trailing: 32))
            .frame(width: OnboardingTheme.leftPaneWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(OnboardingTheme.bg)
            .overlay(Rectangle().fill(OnboardingTheme.border).frame(width: 0.5), alignment: .trailing)
            .offset(x: shown || reduceMotion ? 0 : -10)
            .opacity(shown ? 1 : 0)

            stage
                .padding(EdgeInsets(top: 52, leading: 40, bottom: 40, trailing: 40))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(shown || reduceMotion ? 1 : 0.985)
        }
        .onAppear {
            if reduceMotion { shown = true } else {
                withAnimation(.easeOut(duration: 0.35)) { shown = true }
            }
        }
    }
}

/// Subtitle under a headline.
struct OnboardingLede: View {
    let text: String

    var body: some View {
        Text(text)
            .font(OnboardingTheme.sans(14))
            .foregroundColor(OnboardingTheme.muted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A numbered line: 01, an italic verb, an optional shortcut, one sentence.
struct OnboardingStepRow: View {
    let number: Int
    let verb: String
    let detail: String
    var chord: [KeycapContent]?
    var held = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(String(format: "%02d", number))
                .font(OnboardingTheme.mono(10.5))
                .tracking(0.6)
                .foregroundColor(OnboardingTheme.faint)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text("\(verb).")
                        .font(OnboardingTheme.serifItalic(22))
                        .foregroundColor(OnboardingTheme.ink)
                    if let chord { OnboardingKeycaps(contents: chord, held: held) }
                }
                Text(detail)
                    .font(OnboardingTheme.sans(12.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A dark card on the left half.
struct OnboardingCard<Content: View>: View {
    var highlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(OnboardingTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(highlighted ? OnboardingTheme.accent.opacity(0.75) : OnboardingTheme.border,
                              lineWidth: highlighted ? 1.2 : 0.75))
    }
}

/// The rounded square holding a card's symbol.
struct OnboardingIconTile: View {
    let systemImage: String
    var tint: Color = OnboardingTheme.ink2

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(tint)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(OnboardingTheme.surface3))
            .accessibilityHidden(true)
    }
}

// MARK: - 1. Speech

/// One place on the right of the speech page's footer: Continue when Drop has
/// a way to run (a saved speech key or the downloaded model), with what Drop
/// will use above it, else the quiet Set up later.
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
@MainActor
struct OnboardingSpeechFooter: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var models: APIAndModelsViewModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            caption
            HStack(spacing: 10) {
                OnboardingQuietButton(title: "Restore from another Mac", action: model.restoreFromAnotherMac)
                Spacer(minLength: 0)
                if model.speechCanContinue {
                    OnboardingPrimaryButton(title: model.dropCheck == .checking ? "Checking…" : "Continue",
                                            isEnabled: model.dropCheck != .checking,
                                            action: model.continueFromSpeech)
                    // No default-button Return: the page's key and search
                    // fields submit with Return.
                } else {
                    OnboardingQuietButton(title: "Set up later", action: model.setUpSpeechLater)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// One line above the buttons: what Continue sets, or why it could not.
    @ViewBuilder private var caption: some View {
        Group {
            if case .failed(let choice, let reason) = model.dropCheck {
                Text("\(choice.name): \(reason)")
                    .foregroundColor(OnboardingTheme.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let choice = model.chosenDrop {
                Text("Drop will use \(choice.name)")
                    .foregroundColor(OnboardingTheme.muted)
                    .lineLimit(1)
            }
        }
        .font(OnboardingTheme.sans(12))
    }
}

/// One page for both ways to get speech: the model on this Mac or the
/// person's own key, plus the language they dictate in. The stage plays Drop.
@MainActor
struct OnboardingSpeechPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController
    /// Observed by the stage only: the page does not redraw with the demo.
    let demo: OnboardingDropDemo
    let configuration: HotkeyConfiguration

    /// The On this Mac card's copy for a model state. Pure, so it is tested
    /// without a view.
    struct Presentation: Equatable {
        let detail: String
        let action: String

        init(_ status: OnDeviceSpeechModelStatus, model: OnDeviceSpeechModel = .parakeetTdtV3) {
            switch status {
            case .notDownloaded:
                detail = "Free, works offline · \(model.approximateSize)"
                action = "Download and use for Drop"
            case .downloading(let fraction):
                detail = OnDeviceSpeechCard.Presentation.isStarting(fraction)
                    ? "Starting the download…"
                    : "Downloading · \(OnDeviceSpeechCard.Presentation.percent(fraction))% of \(model.approximateSize)"
                action = "Use for Drop"
            case .ready:
                detail = "Already on this Mac · works offline"
                action = "Use for Drop"
            case .failed:
                detail = "The download didn't finish. Try again."
                action = "Download and use for Drop"
            }
        }
    }

    var body: some View {
        let presentation = Presentation(onDevice.status)
        OnboardingSplit(step: "Speech", index: model.pageIndex, count: model.pages.count, top: 44, back: model.backAction) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline(plain: "Your voice,", italic: "typed.")
                OnboardingLanguageRow(model: model)
                    .padding(.top, 12)
                if model.supportsOnDevice {
                    OnboardingCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .center, spacing: 12) {
                                OnboardingIconTile(systemImage: "laptopcomputer", tint: OnboardingTheme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("On this Mac")
                                        .font(OnboardingTheme.sans(13.5, weight: .semibold))
                                        .foregroundColor(OnboardingTheme.ink)
                                    Text(presentation.detail)
                                        .font(OnboardingTheme.sans(12))
                                        .foregroundColor(OnboardingTheme.muted)
                                        .contentTransition(.numericText())
                                }
                            }
                            if case .downloading(let fraction) = onDevice.status {
                                OnboardingProgressLine(fraction: fraction)
                                    .accessibilityLabel("Download progress")
                            }
                            OnboardingPrimaryButton(title: presentation.action, chevron: false, action: model.startOnDevice)
                        }
                    }
                    .padding(.top, 12)
                }
                OnboardingKeyCard(model: model, models: model.models, tavily: model.tavily)
                    .padding(.top, 10)
            }
        } footer: {
            OnboardingSpeechFooter(model: model, models: model.models, onDevice: onDevice)
        } stage: {
            ZStack {
                OnboardingStageBackdrop(corner: UnitPoint(x: 0.85, y: 0.1))
                    .padding(EdgeInsets(top: -52, leading: -40, bottom: -40, trailing: -40))
                OnboardingDropDemoStage(demo: demo, chord: configuration.dropVoiceShortcut.contents)
            }
        }
        .task { await onDevice.refresh() }
    }
}

/// The language Drop listens for: Auto or one of the menu's languages, the
/// same setting as the Input Lang tool. A searchable list: typing filters by
/// English or native name, arrows move, Return picks, Escape closes.
struct OnboardingLanguageRow: View {
    @ObservedObject var model: OnboardingModel
    @State private var open = false

    static let autoTitle = "Any language"

    static func title(_ language: AppLanguage?) -> String {
        guard let language else { return autoTitle }
        return language.displayName == language.englishName
            ? language.englishName : "\(language.englishName) · \(language.displayName)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("I speak")
                .font(OnboardingTheme.sans(13))
                .foregroundColor(OnboardingTheme.muted)
            Button { open.toggle() } label: {
                OnboardingMenuLabel(title: Self.title(model.language), minWidth: 140)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dictation language")
            .accessibilityValue(Self.title(model.language))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                OnboardingLanguageList(selected: model.language) { language in
                    model.setLanguage(language)
                    open = false
                }
            }
        }
    }
}

/// Search over the dictation languages. Pure, so it is tested without a view.
enum OnboardingLanguageSearch {
    /// `nil` stands for Any language. An empty query lists everything in
    /// English-name order; otherwise names that start with the query come
    /// before names that only contain it.
    static func results(_ query: String, in languages: [AppLanguage] = AppLanguage.all) -> [AppLanguage?] {
        let sorted = languages.sorted { $0.englishName < $1.englishName }
        let needle = fold(query)
        guard !needle.isEmpty else { return [nil] + sorted }
        func names(_ language: AppLanguage) -> [String] {
            [language.englishName, language.displayName, language.code].map(fold)
        }
        let starts = sorted.filter { names($0).contains { $0.hasPrefix(needle) } }
        let contains = sorted.filter { language in
            !starts.contains(language) && names(language).contains { $0.contains(needle) }
        }
        let auto: [AppLanguage?] = fold(OnboardingLanguageRow.autoTitle).contains(needle) || fold("auto").hasPrefix(needle)
            ? [nil] : []
        return auto + starts + contains
    }

    static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

struct OnboardingLanguageList: View {
    let selected: AppLanguage?
    let choose: (AppLanguage?) -> Void
    /// The height of the scrolling rows under the search field.
    var rowsHeight: CGFloat = 248
    @State private var query: String
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    init(selected: AppLanguage?, query: String = "", rowsHeight: CGFloat = 248, choose: @escaping (AppLanguage?) -> Void) {
        self.selected = selected
        self.rowsHeight = rowsHeight
        self.choose = choose
        _query = State(initialValue: query)
    }

    var body: some View {
        let results = OnboardingLanguageSearch.results(query)
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(OnboardingTheme.muted)
                    .accessibilityHidden(true)
                TextField("Search languages", text: $query)
                    .textFieldStyle(.plain)
                    .font(OnboardingTheme.sans(13))
                    .foregroundColor(OnboardingTheme.ink)
                    .focused($focused)
                    .onSubmit { pick(results) }
                    .accessibilityLabel("Search languages")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Rectangle().fill(OnboardingTheme.border).frame(height: 0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.offset) { index, language in
                            row(language, highlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { choose(language) }
                                .onHover { if $0 { highlighted = index } }
                        }
                        if results.isEmpty {
                            Text("No language matches")
                                .font(OnboardingTheme.sans(12))
                                .foregroundColor(OnboardingTheme.faint)
                                .frame(maxWidth: .infinity, minHeight: 40)
                        }
                    }
                    .padding(5)
                }
                .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
            }
            .frame(height: rowsHeight)
        }
        .frame(width: 260)
        .background(OnboardingTheme.surface)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
    }

    private func pick(_ results: [AppLanguage?]) {
        guard results.indices.contains(highlighted) else { return }
        choose(results[highlighted])
    }

    private func row(_ language: AppLanguage?, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Text(language?.englishName ?? OnboardingLanguageRow.autoTitle)
                .foregroundColor(OnboardingTheme.ink)
            if let language, language.displayName != language.englishName {
                Text(language.displayName).foregroundColor(OnboardingTheme.muted)
            }
            Spacer(minLength: 4)
            if language?.code == selected?.code {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(OnboardingTheme.accent)
                    .accessibilityLabel("Selected")
            }
        }
        .font(OnboardingTheme.sans(13))
        .lineLimit(1)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(highlighted ? OnboardingTheme.accent.opacity(0.28) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A key the onboarding can save: a model provider's or Tavily's.
enum OnboardingKeyTarget: Hashable {
    case provider(AIProviderKind)
    case tavily

    var name: String {
        switch self {
        case .provider(let kind): return kind.displayName
        case .tavily: return "Tavily"
        }
    }

    /// Speech providers also become Drop's speech when their key is saved.
    var speechKind: AIProviderKind? {
        if case .provider(let kind) = self, OnboardingDropSpeech.keyProviders.contains(kind) { return kind }
        return nil
    }
}

/// One tile of the key card: every provider Whytap takes a key for, with its
/// offer from Settings -> API & Models -> API hints (the one source for
/// offers; a provider without one gets none).
struct OnboardingKeyOffer: Equatable {
    enum Category: String { case speech = "SPEECH", ai = "AI", search = "SEARCH" }

    let target: OnboardingKeyTarget
    let category: Category
    let short: String?
    /// The offer needs a paid plan (Claude Max, ChatGPT Pro), so it is not free.
    let needsPlan: Bool
    let url: URL?
    let detail: String?

    /// Speech first (Drop needs one), then language models, then search.
    static let targets: [(OnboardingKeyTarget, Category)] =
        OnboardingDropSpeech.keyProviders.map { (.provider($0), .speech) }
        + [(.provider(.openRouter), .ai), (.provider(.openAI), .ai), (.provider(.anthropic), .ai),
           (.tavily, .search)]

    /// Which provider's key an API hints offer is spent with.
    static func target(of hint: APIHintsView.Hint) -> OnboardingKeyTarget? {
        switch hint.provider {
        case "Claude Max & Ultra": return .provider(.anthropic)
        case "ChatGPT Pro": return .provider(.openAI)
        default: return targets.map(\.0).first { $0.name == hint.provider }
        }
    }

    static var all: [OnboardingKeyOffer] {
        targets.map { target, category in
            let hint = APIHintsView.hints.first { Self.target(of: $0) == target }
            return OnboardingKeyOffer(
                target: target, category: category, short: hint.map(short), needsPlan: hint?.access == .paidPlan,
                url: hint?.url, detail: hint.map { "\($0.provider): \($0.allowance) \($0.cadence). \($0.detail)" })
        }
    }

    /// "$200 credit", "10,000 credits/mo", "50/day free": the allowance and
    /// its period in a tile's width.
    static func short(_ hint: APIHintsView.Hint) -> String {
        let cadence = hint.cadence.lowercased()
        if hint.allowance.contains("/") {
            return hint.allowance.replacingOccurrences(of: " ", with: "") + " free"
        }
        let unit = cadence.contains("credits") ? " credits" : cadence.contains("credit") ? " credit" : ""
        let amount = compact(hint.allowance)
        if cadence.contains("month") { return "\(amount)\(unit)/mo" }
        if cadence.contains("day") { return "\(amount)\(unit)/day" }
        return amount + unit
    }

    /// "10,000" -> "10k", so the offer fits a tile.
    static func compact(_ amount: String) -> String {
        amount.hasSuffix(",000") ? String(amount.dropLast(4)) + "k" : amount
    }
}

/// The person's own keys: every provider with its offer; a click opens its
/// key field and offer link. A speech key also becomes Drop's speech.
@MainActor
struct OnboardingKeyCard: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var models: APIAndModelsViewModel
    @ObservedObject var tavily: TavilySettings
    @State private var key = ""
    @State private var saving = false
    @State private var failure: String?
    /// The provider the failure belongs to; another tile hides it.
    @State private var failureTarget: OnboardingKeyTarget?
    @State private var saved: Set<OnboardingKeyTarget> = []
    @FocusState private var focused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        let offers = OnboardingKeyOffer.all
        let selected = offers.first { $0.target == model.keyTarget }
        let failure = failureTarget == model.keyTarget ? failure : nil
        OnboardingCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text("OR USE YOUR KEYS")
                        .font(OnboardingTheme.mono(10, weight: .medium))
                        .tracking(1.2)
                        .foregroundColor(OnboardingTheme.faint)
                    Spacer(minLength: 0)
                    if let selected, failure == nil, let url = selected.url {
                        Link(destination: url) {
                            HStack(spacing: 3) {
                                Text("Get offer")
                                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                            }
                            .font(OnboardingTheme.sans(11.5, weight: .medium))
                            .foregroundColor(OnboardingTheme.ink2)
                        }
                        .buttonStyle(.plain)
                        .help(selected.detail ?? "")
                        .accessibilityLabel("Get the \(selected.target.name) offer")
                    }
                }
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(offers, id: \.target) { offer in
                        tile(offer, selected: offer.target == model.keyTarget)
                    }
                }
                // A saved speech key needs no panel: its tile says For Drop and
                // the footer says what Continue sets. A refusal still shows.
                if let selected, !quietlySaved(selected.target) { actions(selected) }
            }
        }
        .onChange(of: model.keyTarget) { _, _ in self.failure = nil; key = "" }
    }

    private func isSaved(_ target: OnboardingKeyTarget) -> Bool {
        if saved.contains(target) { return true }
        switch target {
        case .tavily: return tavily.configured
        case .provider(let kind):
            return APIAndModelsViewModel.builtInAccount(for: kind).map(models.accountIsAvailableForSelection) ?? false
        }
    }

    private func tile(_ offer: OnboardingKeyOffer, selected: Bool) -> some View {
        let hasKey = isSaved(offer.target)
        let refusal = offer.target.speechKind.flatMap(model.keyRefusal)
        let forDrop = offer.target.speechKind.map { model.chosenDrop == .provider($0) } ?? false
        let highlighted = selected || forDrop
        return OnboardingKeyTileButton(highlighted: highlighted, isEnabled: !saving) {
            model.keyTarget = selected ? nil : offer.target
            // A saved speech key is a choice for Drop, applied by Continue.
            if hasKey, refusal == nil, let kind = offer.target.speechKind { model.pickDrop(.provider(kind)) }
        } label: {
            VStack(spacing: 2) {
                Text(offer.category.rawValue)
                    .font(OnboardingTheme.mono(7.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(OnboardingTheme.faint)
                Group {
                    switch offer.target {
                    case .provider(let kind): ProviderKindIcon(kind: kind, size: 17)
                    case .tavily: ProviderKindIcon(assetName: "tavily", size: 17)
                    }
                }
                .foregroundColor(OnboardingTheme.ink)
                .frame(height: 18)
                Text(offer.target.name)
                    .font(OnboardingTheme.sans(10.5, weight: .semibold))
                    .foregroundColor(OnboardingTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Group {
                    if hasKey, refusal != nil {
                        Text("Key refused").foregroundColor(OnboardingTheme.orange)
                    } else if forDrop {
                        Label("For Drop", systemImage: "mic.fill").labelStyle(.titleAndIcon)
                            .foregroundColor(OnboardingTheme.accent)
                    } else if hasKey {
                        Label("Saved", systemImage: "checkmark").labelStyle(.titleAndIcon)
                            .foregroundColor(OnboardingTheme.green)
                    } else if let short = offer.short {
                        Text(offer.needsPlan ? "Plan credit" : short)
                            .foregroundColor(offer.needsPlan ? OnboardingTheme.muted : OnboardingTheme.green)
                    } else {
                        Text("Paid").foregroundColor(OnboardingTheme.faint)
                    }
                }
                .font(OnboardingTheme.sans(9.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .help(offer.detail ?? offer.target.name)
        .accessibilityLabel("\(offer.target.name), \(offer.category.rawValue.lowercased())"
                            + (offer.short.map { ", \($0)" } ?? ""))
        .accessibilityValue(forDrop ? "Drop will use it" : (refusal ?? ""))
        .accessibilityAddTraits(selected || forDrop ? .isSelected : [])
    }

    @ViewBuilder private func actions(_ offer: OnboardingKeyOffer) -> some View {
        let target = offer.target
        VStack(alignment: .leading, spacing: 8) {
            if isSaved(target) {
                HStack(spacing: 10) {
                    Text(savedText(target))
                        .font(OnboardingTheme.sans(11.5))
                        .foregroundColor(OnboardingTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("Paste your \(target.name) key", text: $key)
                        .textFieldStyle(.plain)
                        .font(OnboardingTheme.sans(12.5))
                        .foregroundColor(OnboardingTheme.ink)
                        .focused($focused)
                        .onSubmit(save)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(OnboardingTheme.bg))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(focused ? OnboardingTheme.accent.opacity(0.8) : OnboardingTheme.borderStrong,
                                          lineWidth: focused ? 1.2 : 0.75))
                        .disabled(saving)
                    if saving {
                        ProgressView().controlSize(.small).accessibilityLabel("Checking the key")
                    } else {
                        OnboardingOutlineButton(title: "Save", action: save)
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if let failure, failureTarget == target { OnboardingStageStatus(tone: .warning, text: failure) }
        }
    }

    private func quietlySaved(_ target: OnboardingKeyTarget) -> Bool {
        guard let kind = target.speechKind else { return false }
        return isSaved(target) && model.keyRefusal(kind) == nil && failureTarget != target
    }

    private func savedText(_ target: OnboardingKeyTarget) -> String {
        guard let kind = target.speechKind else { return "Saved. Pick its models in Settings → API & Models." }
        if let refusal = model.keyRefusal(kind) { return refusal }
        return "Your \(target.name) key is saved."
    }

    /// The same checks and Keychain saves as Settings -> API keys
    /// (`ProviderKeyForm.save` with the provider's account, `TavilySettings.save`).
    private func save() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !saving, let target = model.keyTarget else { return }
        // Saving a speech key is the page's latest speech action until another starts.
        let action = target.speechKind == nil ? nil : model.beginSpeechAction()
        saving = true
        failure = nil
        Task {
            let problem: String?
            switch target {
            case .tavily:
                tavily.draftKey = candidate
                await tavily.save()
                problem = tavily.messageIsError ? (tavily.message ?? "Key not accepted") : nil
            case .provider(let kind):
                if let account = APIAndModelsViewModel.builtInAccount(for: kind) {
                    problem = await models.replaceKey(candidate, for: account)
                } else {
                    problem = await models.addKey(candidate, kind: kind)
                }
            }
            saving = false
            if let problem {
                failure = problem
                failureTarget = target
            } else {
                if model.keyTarget == target { key = "" }
                saved.insert(target)
                if let kind = target.speechKind, let action { model.useKey(kind, action: action) }
            }
        }
    }
}

// MARK: - 2. Permissions

@MainActor
struct OnboardingPermissionsPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var permissions: PermissionsSettingsViewModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController

    var body: some View {
        let microphone = permissions.snapshot.microphoneGranted
        let keyboard = permissions.snapshot.accessibilityGranted
        OnboardingSplit(step: "Permissions", index: model.pageIndex, count: model.pages.count, back: model.backAction) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline(plain: "Two quick", italic: "permissions.", stacked: true)
                OnboardingLede(text: "Asked once, used only while you dictate.")
                    .padding(.top, 12)
                VStack(spacing: 10) {
                    card(icon: "mic", title: "Microphone", detail: "To hear you.",
                         granted: microphone, requested: false, action: permissions.requestMicrophone)
                    card(icon: "keyboard", title: "Keyboard control",
                         detail: "To type for you.",
                         granted: keyboard, requested: permissions.accessibilityRequested,
                         action: permissions.requestAccessibility)
                    screenRecordingRow
                }
                .padding(.top, 24)
                // Both allowed but no shortcut: the repair actions, never a
                // second permission request.
                if permissions.snapshot.allRequiredGranted && permissions.dropHotkeyStatus != .ready {
                    DropShortcutStatusSection(viewModel: permissions)
                        .padding(.top, 12)
                }
            }
        } footer: {
            OnboardingQuietButton(title: "Skip", action: model.advance)
            OnboardingPrimaryButton(title: "Continue", isEnabled: permissions.allRequiredGranted, action: model.advance)
        } stage: {
            ZStack {
                OnboardingStageBackdrop(corner: UnitPoint(x: 0.8, y: 0.15))
                    .padding(EdgeInsets(top: -52, leading: -40, bottom: -40, trailing: -40))
                VStack(alignment: .leading, spacing: 18) {
                    OnboardingPrivacyMock(microphone: microphone, keyboard: keyboard)
                    if !keyboard {
                        Text("Allow opens System Settings. Turn on Whytap there, then come back.")
                            .font(OnboardingTheme.sans(12))
                            .foregroundColor(OnboardingTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    OnboardingModelStatusCard(status: onDevice.status)
                }
                .frame(maxWidth: 420)
            }
        }
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh(restartRecoveryPolling: false)
        }
    }

    /// Optional, for Shot: never holds Continue. Allow is the launch's one
    /// request shared with Shot (`OnboardingModel.requestScreenRecording`); a
    /// second press opens System Settings.
    private var screenRecordingRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OnboardingTheme.muted)
                .frame(width: 34, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Recording")
                    .font(OnboardingTheme.sans(12.5, weight: .medium))
                    .foregroundColor(OnboardingTheme.ink2)
                Text("OPTIONAL · FOR SHOT")
                    .font(OnboardingTheme.mono(9.5, weight: .medium))
                    .tracking(0.8)
                    .foregroundColor(OnboardingTheme.faint)
            }
            Spacer(minLength: 4)
            if permissions.screenRecordingGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(OnboardingTheme.green)
                    .accessibilityLabel("Screen Recording: Allowed")
            } else {
                OnboardingOutlineButton(title: model.screenRecordingAsked ? "Open Settings" : "Allow",
                                        action: model.requestScreenRecording)
                .accessibilityLabel(model.screenRecordingAsked
                    ? "Open System Settings for Screen Recording" : "Allow Screen Recording, optional, for Shot")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(OnboardingTheme.border, style: StrokeStyle(lineWidth: 0.75, dash: [4, 3])))
        .accessibilityElement(children: .contain)
    }

    private func card(icon: String, title: String, detail: String, granted: Bool, requested: Bool,
                      action: @escaping () -> Void) -> some View {
        OnboardingCard {
            HStack(alignment: .center, spacing: 12) {
                OnboardingIconTile(systemImage: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(OnboardingTheme.sans(13.5, weight: .semibold))
                        .foregroundColor(OnboardingTheme.ink)
                    Text(detail)
                        .font(OnboardingTheme.sans(12))
                        .foregroundColor(OnboardingTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(OnboardingTheme.green)
                        .accessibilityLabel("\(title): Allowed")
                } else {
                    // The first press asks macOS; the next one opens its pane.
                    // WHY: .project-docs/decisions/2026-11-19-permission-request-before-settings.md
                    OnboardingPrimaryButton(title: requested ? "Open Settings" : "Allow", chevron: false, action: action)
                        .accessibilityLabel(requested ? "Open System Settings for \(title)" : "Allow \(title)")
                }
            }
        }
    }
}

/// System Settings as the person will see it: the one switch to turn on for
/// each permission, lit when it is on.
struct OnboardingPrivacyMock: View {
    let microphone: Bool
    let keyboard: Bool

    var body: some View {
        OnboardingMockWindow(caption: "PRIVACY & SECURITY") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                section("MICROPHONE", on: microphone)
                section("ACCESSIBILITY", on: keyboard)
                    .padding(.top, 6)
            }
            .padding(16)
        }
        .accessibilityHidden(true)
    }

    private func section(_ title: String, on: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(OnboardingTheme.mono(10, weight: .medium))
                .tracking(1)
                .foregroundColor(OnboardingTheme.faint)
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(OnboardingTheme.accent, lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black))
                Text("Whytap")
                    .font(OnboardingTheme.sans(14, weight: .semibold))
                    .foregroundColor(OnboardingTheme.ink)
                Spacer()
                Capsule()
                    .fill(on ? OnboardingTheme.green : Color.white.opacity(0.14))
                    .frame(width: 34, height: 20)
                    .overlay(Circle().fill(Color.white).frame(width: 16, height: 16)
                        .offset(x: on ? 7 : -7))
                    .animation(.easeOut(duration: 0.25), value: on)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? Color.white.opacity(0.03) : OnboardingTheme.accent.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? OnboardingTheme.border : OnboardingTheme.accent.opacity(0.45), lineWidth: 0.75))
        }
    }
}

/// The speech model's download, shown while the person does something else.
struct OnboardingModelStatusCard: View {
    let status: OnDeviceSpeechModelStatus

    var body: some View {
        switch status {
        case .downloading(let fraction):
            card {
                HStack {
                    Text("Speech model")
                        .font(OnboardingTheme.sans(13, weight: .semibold))
                        .foregroundColor(OnboardingTheme.ink)
                    Spacer()
                    Text(OnDeviceSpeechCard.Presentation.isStarting(fraction)
                         ? "Starting…" : "\(OnDeviceSpeechCard.Presentation.percent(fraction))%")
                        .font(OnboardingTheme.mono(12, weight: .medium))
                        .foregroundColor(OnboardingTheme.muted)
                        .contentTransition(.numericText())
                }
                OnboardingProgressLine(fraction: fraction)
                Text("Downloading in the background. Drop works as soon as it lands.")
                    .font(OnboardingTheme.sans(11.5))
                    .foregroundColor(OnboardingTheme.faint)
            }
        case .ready:
            card {
                OnboardingStageStatus(tone: .success, text: "The speech model is on this Mac.")
            }
        case .notDownloaded, .failed:
            EmptyView()
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(OnboardingTheme.border, lineWidth: 0.75))
    }
}

// MARK: - 3. Try

@MainActor
struct OnboardingTryPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController
    @ObservedObject var permissions: PermissionsSettingsViewModel
    let configuration: HotkeyConfiguration

    /// Copy for the user's own Drop shortcut and gesture. Pure for tests.
    struct Copy: Equatable {
        let pressVerb: String
        let pressDetail: String
        let releaseVerb: String
        let releaseDetail: String
        let placeholder: String

        init(shortcut: String, gesture: HotkeyGesture) {
            switch gesture {
            case .hold:
                pressVerb = "Hold"
                pressDetail = "Speak while you hold it."
                releaseVerb = "Let go"
                releaseDetail = "The text appears at the cursor."
                placeholder = "Click here, hold \(shortcut) and say a sentence"
            case .tap:
                pressVerb = "Press"
                pressDetail = "Then speak."
                releaseVerb = "Press again"
                releaseDetail = "The text appears at the cursor."
                placeholder = "Click here, press \(shortcut) and say a sentence"
            }
        }
    }

    var body: some View {
        let chord = configuration.dropVoiceShortcut.contents
        let copy = Copy(shortcut: configuration.dropVoiceShortcut.title, gesture: configuration.normalizedDropGesture)
        OnboardingSplit(step: "Try it", index: model.pageIndex, count: model.pages.count, back: model.backAction) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline(plain: "Try", italic: "Drop.")
                VStack(alignment: .leading, spacing: 18) {
                    OnboardingStepRow(number: 1, verb: "Click", detail: "Into the note on the right.")
                    OnboardingStepRow(number: 2, verb: copy.pressVerb, detail: copy.pressDetail, chord: chord)
                    OnboardingStepRow(number: 3, verb: copy.releaseVerb, detail: copy.releaseDetail)
                }
                .padding(.top, 28)
                .accessibilityLabel("Drop shortcut: \(configuration.dropVoiceShortcut.title)")
            }
        } footer: {
            if !model.dictated { OnboardingQuietButton(title: "Skip", action: model.advance) }
            OnboardingPrimaryButton(title: "Continue", action: model.advance)
        } stage: {
            ZStack {
                OnboardingStageBackdrop(tint: model.dictated ? OnboardingTheme.green : OnboardingTheme.accent,
                                        corner: UnitPoint(x: 0.25, y: 0.1))
                    .padding(EdgeInsets(top: -52, leading: -40, bottom: -40, trailing: -40))
                    .animation(.easeInOut(duration: 0.6), value: model.dictated)
                VStack(alignment: .leading, spacing: 18) {
                    OnboardingMockWindow(caption: "NOTES — TRY DROP") {
                        OnboardingKeycaps(contents: chord)
                    } content: {
                        OnboardingTryField(placeholder: copy.placeholder, onDictated: model.noteDictated)
                            .padding(10)
                            .frame(height: 210)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(model.dictated ? OnboardingTheme.green.opacity(0.55) : .clear, lineWidth: 1))
                    status
                        .frame(minHeight: 44, alignment: .top)
                }
                .frame(maxWidth: 440)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if model.dictated {
            OnboardingStageStatus(tone: .success,
                                  text: "That's Drop. Same shortcut, any app.")
        } else if !model.dropReady, case .downloading(let fraction) = onDevice.status {
            VStack(alignment: .leading, spacing: 9) {
                OnboardingStageStatus(tone: .neutral, text: OnDeviceSpeechCard.Presentation.isStarting(fraction)
                    ? "The speech model is starting to download. Drop works as soon as it's on this Mac."
                    : "The speech model is downloading: \(OnDeviceSpeechCard.Presentation.percent(fraction))%. Drop works as soon as it's on this Mac.")
                OnboardingProgressLine(fraction: fraction)
                    .frame(maxWidth: 260)
            }
        } else if !model.dropReady || model.dropSetupFailure != nil {
            HStack(spacing: 12) {
                OnboardingStageStatus(tone: .warning, text: model.dropReady
                    ? "Drop couldn’t start with these speech settings."
                    : "Drop has no speech model yet.")
                OnboardingQuietButton(title: model.dropReady ? "Check settings" : "Choose a model",
                                      action: model.openDropSpeechSettings)
            }
        } else if permissions.dropHotkeyStatus != .ready {
            HStack(spacing: 12) {
                OnboardingStageStatus(tone: .warning, text: "Your Drop shortcut isn't active yet.")
                OnboardingQuietButton(title: "Fix", action: model.showPermissions)
            }
        }
    }
}

// MARK: - 4. Customize

/// The two onboarding clips, bundled beside the Settings clips in
/// `Resources/FeatureVideos`.
enum OnboardingVideo: String, CaseIterable {
    case hotkeys = "onboarding-hotkeys"
    case hover = "onboarding-hover"

    var title: String {
        switch self {
        case .hotkeys: return "Your shortcuts"
        case .hover: return "Your tools"
        }
    }

    func url(in bundle: Bundle = FeatureVideo.resourceBundle) -> URL? {
        bundle.url(forResource: rawValue, withExtension: "mp4", subdirectory: FeatureVideo.subdirectory)
    }
}

/// Shortcuts for any tool and the tools under the island: two rows, each with
/// its clip on the stage and the Settings place that changes it.
@MainActor
struct OnboardingCustomizePage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let selected = model.customizeVideo
        OnboardingSplit(step: "Customize", index: model.pageIndex, count: model.pages.count, back: model.backAction) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline(plain: "Make it", italic: "yours.")
                OnboardingLede(text: "Your keys, your tools.")
                    .padding(.top, 8)
                VStack(spacing: 8) {
                    OnboardingSelectableRow(icon: "command", title: "Shortcuts",
                                            detail: "Any tool on its own keys.",
                                            selected: selected == .hotkeys, select: { model.customizeVideo = .hotkeys }) {
                        OnboardingOutlineButton(title: "Open", action: model.openHotkeys)
                            .accessibilityLabel("Open Hotkeys settings")
                    }
                    OnboardingSelectableRow(icon: "square.grid.3x2", title: "Hover tools",
                                            detail: "What the island shows.",
                                            selected: selected == .hover, select: { model.customizeVideo = .hover }) {
                        OnboardingOutlineButton(title: "Open", action: model.openToolbox)
                            .accessibilityLabel("Open Toolbox settings")
                    }
                }
                .padding(.top, 24)
            }
        } footer: {
            OnboardingPrimaryButton(title: "Continue", action: model.advance)
        } stage: {
            ZStack {
                OnboardingStageBackdrop(corner: UnitPoint(x: 0.3, y: 0.0))
                    .padding(EdgeInsets(top: -52, leading: -40, bottom: -40, trailing: -40))
                OnboardingClipStage(title: selected.title, url: selected.url(), shortcuts: [])
                    .id(selected)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.25), value: selected)
        }
    }
}

/// A card that picks what the stage shows, with its own control at the end.
struct OnboardingSelectableRow<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String
    let selected: Bool
    let select: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        OnboardingCard(highlighted: selected) {
            HStack(alignment: .center, spacing: 12) {
                OnboardingIconTile(systemImage: icon, tint: selected ? OnboardingTheme.accent : OnboardingTheme.ink2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(OnboardingTheme.sans(13.5, weight: .semibold))
                        .foregroundColor(OnboardingTheme.ink)
                    Text(detail)
                        .font(OnboardingTheme.sans(12))
                        .foregroundColor(OnboardingTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                trailing
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: select)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Watch how \(title) works", select)
    }
}

// MARK: - 5. Features

@MainActor
struct OnboardingFeaturesPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var codingTools: OnboardingCodingTools
    let configuration: HotkeyConfiguration
    @State private var selected: FeatureVideo = .googleSearch

    var body: some View {
        let _ = model.revision
        OnboardingSplit(step: "More", index: model.pageIndex, count: model.pages.count, back: model.backAction) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline(plain: "Turn on", italic: "more.")
                OnboardingLede(text: "Each stays off until you turn it on.")
                    .padding(.top, 8)
                VStack(spacing: 8) {
                    row(.googleSearch, icon: "magnifyingglass", title: "Google search", detail: "Type or say a query.") {
                        MacSwitch(isOn: Binding(get: { model.googleOn }, set: model.setGoogle), label: "Google search")
                    }
                    row(.meetings, icon: "waveform", title: "Meeting Notes", detail: "From your calls.") {
                        switch model.meetingsAction {
                        case .toggle:
                            MacSwitch(isOn: Binding(get: { model.meetingsOn }, set: model.setMeetings), label: "Meeting Notes")
                        case .addModel(let feature):
                            OnboardingOutlineButton(title: "Add a model") { model.addModel(feature) }
                        }
                    }
                    row(.agent, icon: "command", title: "Agent", detail: "Ask; it answers.") {
                        switch model.agentAction {
                        case .toggle:
                            HStack(spacing: 8) {
                                if model.agentConnecting { ProgressView().controlSize(.small) }
                                MacSwitch(isOn: Binding(get: { model.agentOn }, set: model.setAgent), label: "Agent")
                                    .disabled(model.agentConnecting)
                            }
                        case .addModel(let feature):
                            OnboardingOutlineButton(title: "Add a model") { model.addModel(feature) }
                        }
                    }
                    if !codingTools.installed.isEmpty {
                        OnboardingCodingToolsRow(tools: codingTools)
                    }
                }
                .padding(.top, 22)
                if let problem = model.agentProblem {
                    OnboardingStageStatus(tone: .warning, text: problem)
                        .padding(.top, 10)
                }
            }
        } footer: {
            OnboardingPrimaryButton(title: "Done", chevron: false, action: model.finish)
                .keyboardShortcut(.defaultAction)
        } stage: {
            ZStack {
                OnboardingStageBackdrop(corner: UnitPoint(x: 0.5, y: 0.0))
                    .padding(EdgeInsets(top: -52, leading: -40, bottom: -40, trailing: -40))
                OnboardingClipStage(title: selected.featureTitle, url: selected.url(), shortcuts: shortcuts(for: selected))
                    .id(selected)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.25), value: selected)
        }
        .task { await codingTools.refreshIfNeeded() }
    }

    private func row<Trailing: View>(_ video: FeatureVideo, icon: String, title: String, detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        OnboardingSelectableRow(icon: icon, title: title, detail: detail,
                                selected: selected == video, select: { selected = video }, trailing: trailing)
    }

    private func shortcuts(for video: FeatureVideo) -> [FeatureVideoShortcut] {
        switch video {
        case .googleSearch: return SettingsOtherView.googleSearchVideoShortcuts(configuration)
        case .meetings: return [FeatureVideoShortcut(label: "Record", contents: configuration.meetingRecordShortcut.contents)]
        case .agent: return AgentOtherSection.videoShortcuts(configuration)
        default: return []
        }
    }
}

/// Claude Code and Codex, when present: Connect writes the same Whytap MCP
/// entry as Case -> Connect (`CaseClientConnector`).
struct OnboardingCodingToolsRow: View {
    @ObservedObject var tools: OnboardingCodingTools

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OnboardingCard {
                HStack(alignment: .center, spacing: 12) {
                    HStack(spacing: -6) {
                        ForEach(tools.installed, id: \.self) { client in
                            ProviderBrandIcon(assetName: client == .codex ? "codex" : "claude-code",
                                              size: 16, color: OnboardingTheme.ink2)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(OnboardingTheme.surface3))
                                .overlay(Circle().strokeBorder(OnboardingTheme.surface, lineWidth: 2))
                        }
                    }
                    .frame(width: 34, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Coding agents")
                            .font(OnboardingTheme.sans(13.5, weight: .semibold))
                            .foregroundColor(OnboardingTheme.ink)
                        Text(tools.installed.map(\.displayName).joined(separator: ", "))
                            .font(OnboardingTheme.sans(12))
                            .foregroundColor(OnboardingTheme.muted)
                    }
                    Spacer(minLength: 4)
                    switch tools.state {
                    case .idle, .failed:
                        OnboardingOutlineButton(title: "Connect", action: tools.connect)
                            .accessibilityLabel("Connect \(tools.names) to Whytap")
                    case .connecting:
                        ProgressView().controlSize(.small).accessibilityLabel("Connecting")
                    case .connected:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(OnboardingTheme.green)
                            .accessibilityLabel("Connected")
                    }
                }
            }
            if case .failed(let problem) = tools.state {
                OnboardingStageStatus(tone: .warning, text: problem)
            }
        }
    }
}

/// A clip looping silently, with the person's own keys under it. Reduce
/// Motion shows its first frame instead.
struct OnboardingClipStage: View {
    let title: String
    let url: URL?
    let shortcuts: [FeatureVideoShortcut]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var poster: NSImage?

    /// Offscreen review images draw the poster: a player has no frame to capture.
    nonisolated(unsafe) static var playsVideo = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title + ".")
                .font(OnboardingTheme.serifItalic(30))
                .foregroundColor(OnboardingTheme.ink)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black)
                if let poster {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
                }
                if Self.playsVideo, !reduceMotion, let url {
                    LoopingVideoView(url: url)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(OnboardingTheme.borderStrong, lineWidth: 0.75))
            .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 18)
            .accessibilityHidden(true)
            if !shortcuts.isEmpty {
                HStack(spacing: 14) {
                    Text("YOUR SHORTCUT")
                        .font(OnboardingTheme.mono(10, weight: .medium))
                        .tracking(1.2)
                        .foregroundColor(OnboardingTheme.faint)
                    ForEach(shortcuts) { shortcut in
                        HStack(spacing: 6) {
                            Text(shortcut.label)
                                .font(OnboardingTheme.sans(12))
                                .foregroundColor(OnboardingTheme.muted)
                            OnboardingKeycaps(contents: shortcut.contents)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(shortcut.label)
                    }
                }
            }
        }
        .frame(maxWidth: 480)
        .task(id: url) { poster = await Self.poster(for: url) }
    }

    static func poster(for url: URL?) async -> NSImage? {
        guard let url else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let image = try? await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

/// A key tile: the whole tile is the control. Hover lightens all of it, a
/// press dims and shrinks it slightly, keyboard focus draws the accent ring
/// and, while a key is being saved, every tile is visibly unavailable.
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
struct OnboardingKeyTileButton<Label: View>: View {
    let highlighted: Bool
    var isEnabled = true
    let action: () -> Void
    @ViewBuilder let label: Label
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(Style(highlighted: highlighted, hovered: hovered && isEnabled,
                               focused: focused, isEnabled: isEnabled))
            .disabled(!isEnabled)
            // The accent ring is the focus indicator; no second system ring.
            .focusEffectDisabled()
            .focused($focused)
            .onHover { hovered = $0 }
    }

    struct Style: ButtonStyle {
        let highlighted: Bool
        let hovered: Bool
        let focused: Bool
        let isEnabled: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            let pressed = configuration.isPressed && isEnabled
            configuration.label
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .padding(.horizontal, 3)
                .background(shape.fill(fill(pressed: pressed)))
                .overlay(shape.strokeBorder(stroke, lineWidth: highlighted ? 1.2 : 0.75))
                .overlay(shape.inset(by: -2.5).strokeBorder(focused ? OnboardingTheme.accent : .clear, lineWidth: 2))
                .opacity(isEnabled ? (pressed ? 0.85 : 1) : 0.45)
                .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
                .contentShape(shape)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
        }

        private func fill(pressed: Bool) -> Color {
            if highlighted { return OnboardingTheme.accent.opacity(pressed ? 0.22 : hovered ? 0.19 : 0.14) }
            return pressed ? OnboardingTheme.surface3 : hovered ? OnboardingTheme.surface3.opacity(0.85) : OnboardingTheme.surface2
        }

        private var stroke: Color {
            if highlighted { return OnboardingTheme.accent.opacity(0.8) }
            return hovered ? OnboardingTheme.borderStrong : OnboardingTheme.border
        }
    }
}
