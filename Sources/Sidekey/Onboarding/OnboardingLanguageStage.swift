import SwiftUI

/// The language step (the design pass's screen 03): the wireframe globe,
/// one quiet field and the language under it. A click on a country and the
/// typed text are equal ways in: either turns the globe to the country and
/// lights it, and the line under the field offers its language, "Русский ·
/// Russian", or its languages side by side. Only languages the speech route
/// can take are offered; with nothing picked the line offers Auto-detect. No
/// checkmark until a language is chosen; then the step moves on by itself.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
struct OnboardingLanguageStage: View {
    @ObservedObject var model: OnboardingJourneyModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = OnboardingGlobeMotion()
    @State private var query = ""
    /// The country the text points to, and the language when it named one.
    @State private var matched: OnboardingGlobeMatch?
    /// The country clicked on the globe.
    @State private var picked: Int?
    @State private var hovered: Int?
    /// The language under the pointer in a row of several.
    @State private var hoveredLanguage: String?
    @FocusState private var focused: Bool

    private static let mesh = OnboardingGlobeMesh.shared
    private static let fieldInset: CGFloat = 44

    /// `query` and `country` start the step typed or picked (offscreen renders).
    init(model: OnboardingJourneyModel, query: String = "", country: String? = nil) {
        self.model = model
        _query = State(initialValue: query)
        _matched = State(initialValue: OnboardingGlobeSearch.best(query))
        // Back to a chosen language: its country is lit again.
        let picked = country.flatMap(Self.mesh.index(of:))
            ?? (query.isEmpty ? model.language.flatMap { OnboardingGlobeSearch.home(of: $0.code) } : nil)
        _picked = State(initialValue: picked)
    }

    private var active: Int? { picked ?? matched?.country }
    private var country: OnboardingGlobeCountry? { active.map { Self.mesh.countries[$0] } }
    private var supported: [AppLanguage] { model.speechLanguages }

    /// The languages the line offers for the lit country.
    private var choices: [AppLanguage] {
        if let code = matched?.language, picked == nil {
            return supported.filter { $0.code == code }
        }
        guard let country else { return [] }
        return country.languages.compactMap { code in supported.first { $0.code == code } }
    }

    /// The lit country's languages the speech route cannot take.
    private var unavailable: [AppLanguage] {
        if let code = matched?.language, picked == nil {
            return supported.contains { $0.code == code } ? [] : AppLanguage.find(code: code).map { [$0] } ?? []
        }
        guard let country, choices.isEmpty else { return [] }
        return country.languages.compactMap(AppLanguage.find(code:))
    }

    private var chosen: Bool { model.outcome(.language).isDone }
    /// The language Return takes: the one under the pointer, else the first.
    private var preferred: AppLanguage? {
        choices.first { $0.code == hoveredLanguage } ?? choices.first
    }

    private var light: OnboardingGlobeLight {
        var siblings: [Int] = []
        if let code = matched?.language, picked == nil {
            siblings = Self.mesh.countries.indices.filter {
                $0 != active && Self.mesh.countries[$0].languages.first == code
            }
        }
        let confirmed = chosen && (model.language.map { language in choices.contains { $0 == language } } ?? false)
        return OnboardingGlobeLight(active: active, siblings: siblings, hovered: hovered, confirmed: confirmed)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("What language do you speak?")
                .font(OnboardingTheme.serifItalic(31))
                .foregroundColor(OnboardingTheme.ink)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            ZStack(alignment: .bottom) {
                OnboardingGlobe(motion: motion, light: light, pick: pick, hover: { hovered = $0 })
                // The country under the pointer, a whisper under the globe.
                Text(hovered.flatMap { $0 == active ? nil : Self.mesh.countries[$0].name } ?? " ")
                    .font(OnboardingTheme.sans(11))
                    .foregroundColor(OnboardingTheme.faint)
                    .offset(y: 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(height: 170)
            field
                .padding(.horizontal, Self.fieldInset)
                .padding(.top, 8)
            line
                .frame(height: 44, alignment: .top)
                .padding(.horizontal, Self.fieldInset)
                .padding(.top, 12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            motion.aim(at: country)
            focused = true
        }
        .onChange(of: active) { _, _ in motion.aim(at: country) }
    }

    // MARK: The field

    private var placeholder: String {
        if let country, picked != nil { return "\(country.name) — or type another…" }
        return "Language or country, or click the globe…"
    }

    private var field: some View {
        HStack(spacing: 10) {
            TextField("", text: $query, prompt: Text(placeholder).foregroundColor(OnboardingTheme.faint))
                .textFieldStyle(.plain)
                .font(OnboardingTheme.sans(14))
                .foregroundColor(OnboardingTheme.ink)
                .focused($focused)
                .onSubmit(submit)
                .onChange(of: query) { _, new in
                    picked = nil
                    hoveredLanguage = nil
                    matched = OnboardingGlobeSearch.best(new, languages: AppLanguage.all)
                }
                .accessibilityLabel("Language or country")
            let ready = preferred != nil || (query.isEmpty && active == nil && model.speechDetectsLanguage)
            Button(action: submit) {
                Image(systemName: light.confirmed ? "checkmark" : "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(light.confirmed ? OnboardingTheme.green : ready ? .black : OnboardingTheme.muted)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(light.confirmed ? OnboardingTheme.green.opacity(0.16)
                                              : ready ? Color.white : Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(!ready || light.confirmed)
            .accessibilityLabel(light.confirmed ? "Language chosen" : preferred.map { "Use \($0.englishName)" } ?? "Choose")
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(height: 50)
        .background(Capsule().fill(Color(red: 0.086, green: 0.086, blue: 0.098)))
        .overlay(Capsule().strokeBorder(light.confirmed ? OnboardingTheme.green.opacity(0.55)
                                        : Color.white.opacity(focused ? 0.16 : 0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 10)
        .animation(OnboardingMotion.resolve(OnboardingMotion.pressRelease, reduceMotion: reduceMotion), value: light.confirmed)
    }

    // MARK: The line under the field

    @ViewBuilder private var line: some View {
        if let first = choices.first, choices.count == 1 {
            Button { choose(first) } label: {
                HStack(spacing: 8) {
                    names(first, strong: true)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(OnboardingTheme.muted)
                        .opacity(light.confirmed ? 0 : 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(light.confirmed)
            .accessibilityLabel("Use \(first.englishName)")
        } else if choices.count > 1 {
            // A country of several languages: each one its own choice.
            HStack(spacing: 14) {
                ForEach(Array(choices.enumerated()), id: \.element.code) { index, language in
                    if index > 0 {
                        Text("·").foregroundColor(OnboardingTheme.faint).accessibilityHidden(true)
                    }
                    Button { choose(language) } label: {
                        short(language, strong: language == preferred)
                            .padding(.bottom, 4)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(OnboardingTheme.ink.opacity(language == preferred ? 0.55 : 0))
                                    .frame(height: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(light.confirmed)
                    .onHover { inside in
                        if inside { hoveredLanguage = language.code } else if hoveredLanguage == language.code { hoveredLanguage = nil }
                    }
                    .accessibilityLabel("Use \(language.englishName)")
                }
            }
        } else if let language = unavailable.first {
            VStack(spacing: 5) {
                Text("\(language.displayName) · \(language.englishName) \(model.speechLanguageLimit)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .font(OnboardingTheme.sans(12.5))
                    .foregroundColor(OnboardingTheme.muted)
                autoDetect
            }
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty, active == nil {
            Text("No country or language called “\(query.trimmingCharacters(in: .whitespaces))”")
                .font(OnboardingTheme.sans(12.5))
                .foregroundColor(OnboardingTheme.faint)
                .lineLimit(1)
        } else if active == nil {
            autoDetect
        }
    }

    @ViewBuilder private var autoDetect: some View {
        if model.speechDetectsLanguage {
            Button { choose(nil) } label: {
                HStack(spacing: 6) {
                    Text("Auto-detect any language")
                    Image(systemName: "arrow.right").font(.system(size: 10.5, weight: .medium))
                }
                .font(OnboardingTheme.sans(13))
                .foregroundColor(chosen && model.language == nil ? OnboardingTheme.green : OnboardingTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auto-detect any language")
        }
    }

    private func names(_ language: AppLanguage, strong: Bool) -> some View {
        HStack(spacing: 8) {
            Text(language.displayName)
                .font(OnboardingTheme.sans(15.5, weight: .semibold))
                .foregroundColor(light.confirmed ? OnboardingTheme.green : strong ? OnboardingTheme.ink : OnboardingTheme.muted)
            if language.displayName != language.englishName {
                Text("·").foregroundColor(OnboardingTheme.faint)
                Text(language.englishName)
                    .font(OnboardingTheme.sans(15.5))
                    .foregroundColor(OnboardingTheme.muted)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// One of several: the native name and the language code, like the
    /// prototype's "Brasil BR · Portugal PT"; the English name on hover.
    private func short(_ language: AppLanguage, strong: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(language.displayName)
                .font(OnboardingTheme.sans(15, weight: strong ? .semibold : .regular))
                .foregroundColor(light.confirmed ? OnboardingTheme.green : strong ? OnboardingTheme.ink : OnboardingTheme.muted)
            Text(language.code.uppercased())
                .font(OnboardingTheme.sans(10.5, weight: .medium))
                .foregroundColor(OnboardingTheme.faint)
        }
        .lineLimit(1)
        .fixedSize()
        .help(language.englishName)
    }

    // MARK: Actions

    private func pick(_ index: Int) {
        query = ""
        matched = nil
        hoveredLanguage = nil
        picked = index
        focused = true
    }

    private func submit() {
        if let preferred { return choose(preferred) }
        if query.trimmingCharacters(in: .whitespaces).isEmpty, active == nil, model.speechDetectsLanguage { choose(nil) }
    }

    private func choose(_ language: AppLanguage?) {
        if let language, picked == nil, matched == nil, let home = OnboardingGlobeSearch.home(of: language.code) {
            picked = home
        }
        model.setLanguage(language)
    }
}
