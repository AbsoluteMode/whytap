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
                HStack(spacing: 10) { footer }
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

/// One page for both ways to get speech: the model on this Mac or the
/// person's own key, plus the language they dictate in. The stage plays Drop.
@MainActor
struct OnboardingSpeechPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController
    @ObservedObject var demo: OnboardingDropDemo
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
        let copy = OnboardingTryPage.Copy(shortcut: configuration.dropVoiceShortcut.title,
                                          gesture: configuration.normalizedDropGesture)
        OnboardingSplit(step: "Speech", index: model.pageIndex, count: model.pages.count, top: 52) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline(plain: "Your voice,", italic: "typed.")
                OnboardingLede(text: copy.pitch)
                    .padding(.top, 8)
                OnboardingLanguageRow(model: model)
                    .padding(.top, 20)
                if model.supportsOnDevice {
                    OnboardingCard {
                        VStack(alignment: .leading, spacing: 12) {
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
                    .padding(.top, 14)
                }
                OnboardingKeyCard(model: model, models: model.models)
                    .padding(.top, 10)
            }
        } footer: {
            OnboardingQuietButton(title: "Restore from another Mac", action: model.restoreFromAnotherMac)
            Spacer(minLength: 0)
            OnboardingQuietButton(title: "Set up later", action: model.setUpSpeechLater)
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
    @State private var query: String
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    init(selected: AppLanguage?, query: String = "", choose: @escaping (AppLanguage?) -> Void) {
        self.selected = selected
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
            .frame(height: 248)
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

/// A speech provider on the onboarding's key card with its free offer from
/// Settings -> API & Models -> API hints (the one source for offers).
struct OnboardingSpeechOffer: Equatable {
    let kind: AIProviderKind
    let short: String?
    let url: URL?
    let detail: String?

    static var all: [OnboardingSpeechOffer] {
        OnboardingDropSpeech.keyProviders.map { kind in
            let hint = APIHintsView.hints.first { $0.category == .speech && $0.provider == kind.displayName }
            return OnboardingSpeechOffer(kind: kind, short: hint.map(short), url: hint?.url,
                                         detail: hint.map { "\($0.allowance) \($0.cadence). \($0.detail)" })
        }
    }

    /// "$200 credit", "10,000 credits/mo": the allowance and its period in a
    /// tile's width.
    static func short(_ hint: APIHintsView.Hint) -> String {
        let cadence = hint.cadence.lowercased()
        let unit = cadence.contains("credits") ? " credits" : cadence.contains("credit") ? " credit" : ""
        if cadence.contains("month") { return "\(hint.allowance)\(unit)/mo" }
        if cadence.contains("day") { return "\(hint.allowance)\(unit)/day" }
        return hint.allowance + unit
    }
}

/// The person's own speech key: every speech provider with its free offer;
/// a click opens its key field and offer link.
@MainActor
struct OnboardingKeyCard: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var models: APIAndModelsViewModel
    @State private var key = ""
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        let offers = OnboardingSpeechOffer.all
        let selected = offers.first { $0.kind == model.keyProvider }
        OnboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("OR USE YOUR KEY")
                    .font(OnboardingTheme.mono(10, weight: .medium))
                    .tracking(1.2)
                    .foregroundColor(OnboardingTheme.faint)
                HStack(spacing: 8) {
                    ForEach(offers, id: \.kind) { offer in
                        tile(offer, selected: offer.kind == model.keyProvider)
                    }
                }
                if let selected { actions(selected) }
            }
        }
        .onChange(of: model.keyProvider) { _, _ in failure = nil; key = "" }
    }

    private func tile(_ offer: OnboardingSpeechOffer, selected: Bool) -> some View {
        Button {
            model.keyProvider = selected ? nil : offer.kind
        } label: {
            VStack(spacing: 5) {
                ProviderKindIcon(kind: offer.kind, size: 20)
                    .foregroundColor(OnboardingTheme.ink)
                Text(offer.kind.displayName)
                    .font(OnboardingTheme.sans(12, weight: .semibold))
                    .foregroundColor(OnboardingTheme.ink)
                    .lineLimit(1)
                Text(offer.short ?? "Paid")
                    .font(OnboardingTheme.sans(10.5, weight: offer.short == nil ? .regular : .medium))
                    .foregroundColor(offer.short == nil ? OnboardingTheme.faint : OnboardingTheme.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? OnboardingTheme.accent.opacity(0.14) : OnboardingTheme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? OnboardingTheme.accent.opacity(0.8) : OnboardingTheme.border,
                              lineWidth: selected ? 1.2 : 0.75))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(offer.detail ?? offer.kind.displayName)
        .accessibilityLabel(offer.short.map { "\(offer.kind.displayName), \($0)" } ?? offer.kind.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func actions(_ offer: OnboardingSpeechOffer) -> some View {
        let provider = offer.kind
        VStack(alignment: .leading, spacing: 8) {
            if model.keyAvailable(provider) {
                HStack(spacing: 10) {
                    Text("Your \(provider.displayName) key is saved.")
                        .font(OnboardingTheme.sans(12))
                        .foregroundColor(OnboardingTheme.muted)
                    Spacer(minLength: 0)
                    OnboardingOutlineButton(title: "Use for Drop") { model.useKey(provider) }
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("Paste your \(provider.displayName) key", text: $key)
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
            if let failure {
                OnboardingStageStatus(tone: .warning, text: failure)
            } else if let url = offer.url {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text("Get offer")
                        Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold))
                    }
                    .font(OnboardingTheme.sans(12, weight: .medium))
                    .foregroundColor(OnboardingTheme.ink2)
                }
                .buttonStyle(.plain)
                .help(offer.detail ?? "")
            }
        }
    }

    /// The same check and Keychain save as Settings -> API keys
    /// (`ProviderKeyForm.save` with the provider's account).
    private func save() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !saving, let provider = model.keyProvider else { return }
        saving = true
        failure = nil
        Task {
            let problem: String?
            if let account = OnboardingDropSpeech.account(for: provider) {
                problem = await models.replaceKey(candidate, for: account)
            } else {
                problem = await models.addKey(candidate, kind: provider)
            }
            saving = false
            if let problem {
                failure = problem
            } else {
                key = ""
                model.useKey(provider)
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
        OnboardingSplit(step: "Permissions", index: model.pageIndex, count: model.pages.count) {
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

    /// Optional, for Shot: never holds Continue. Allow is the same single
    /// request as Settings -> Permissions (`requestScreenRecording`); a
    /// second press opens System Settings.
    // WHY: .project-docs/decisions/2026-11-19-permission-request-before-settings.md
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
            } else if permissions.isRequestingScreenRecording {
                ProgressView().controlSize(.small).accessibilityLabel("Asking for Screen Recording")
            } else {
                OnboardingOutlineButton(title: permissions.screenRecordingRequested ? "Open Settings" : "Allow") {
                    Task { await permissions.requestScreenRecording() }
                }
                .accessibilityLabel(permissions.screenRecordingRequested
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
        /// The first page's promise.
        let pitch: String
        let pressVerb: String
        let pressDetail: String
        let releaseVerb: String
        let releaseDetail: String
        let placeholder: String

        init(shortcut: String, gesture: HotkeyGesture) {
            switch gesture {
            case .hold:
                pitch = "Hold \(shortcut), speak, let go."
                pressVerb = "Hold"
                pressDetail = "Speak while you hold it."
                releaseVerb = "Let go"
                releaseDetail = "The text appears at the cursor."
                placeholder = "Click here, hold \(shortcut) and say a sentence"
            case .tap:
                pitch = "Press \(shortcut), speak, press again."
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
        OnboardingSplit(step: "Try it", index: model.pageIndex, count: model.pages.count) {
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
        OnboardingSplit(step: "Customize", index: model.pageIndex, count: model.pages.count) {
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
        OnboardingSplit(step: "More", index: model.pageIndex, count: model.pages.count) {
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

/// Claude Code and Codex, when present: Connect gives them the Whytap plugin's
/// server, the same setup as Case -> Connect.
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
