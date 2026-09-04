import SwiftUI

/// Screen 05 of the onboarding flow — Choose your transcription
/// language. The left pane carries the two top-level affordances:
///
///   1. Auto-detect — kept as an option but no longer recommended.
///   2. Pick a language — RECOMMENDED, with a live-filter input that
///      narrows the right-pane grid as the user types.
///
/// The right pane shows the ~99 languages grouped by country flag
/// (`LanguageGroup`) — one tile per country, with a `+N` badge and a
/// tap-to-expand variant popover where several languages share a flag
/// (Spain, India, …). The grid scrolls. Typing in the filter flattens
/// the grid to individual language matches so an exact search lands
/// directly on the language.
///
/// Generic over a binding rather than a backing controller — the
/// Sidekey app binds straight to `PrivacyPreferences.shared.selectedLanguage`,
/// the preview drives it from local `@State`.
struct OnboardingLanguageScreen: View {
    @Binding var selected: AppLanguage?
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var query: String = ""
    /// Non-nil while a multi-language country tile is expanded into its
    /// variant popover (e.g. tapping 🇪🇸 to choose Español vs Català).
    @State private var expandedGroup: LanguageGroup? = nil
    /// Picks up whether the user has "engaged" the Pick-a-language
    /// card without picking a specific language yet. Three states:
    ///   - Auto highlighted        (selected == nil && !pickActive)
    ///   - Pick engaged, no lang   (selected == nil &&  pickActive)
    ///   - Pick engaged, has lang  (selected != nil — implies engaged)
    /// Initialised from the bound selection so re-opening the screen
    /// remembers the user's previous engagement.
    @State private var pickActive: Bool

    @EnvironmentObject private var locale: OnboardingLocale
    private var copy: OnboardingLanguageCopy { onboardingLanguageCopy(for: locale.language) }

    init(
        selected: Binding<AppLanguage?>,
        onBack: @escaping () -> Void,
        onContinue: @escaping () -> Void
    ) {
        self._selected = selected
        self.onBack = onBack
        self.onContinue = onContinue
        self._pickActive = State(initialValue: selected.wrappedValue != nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: OnboardingTheme.leftPaneWidth, alignment: .topLeading)
                .background(OnboardingTheme.bg)
                .overlay(
                    Rectangle().fill(OnboardingTheme.border).frame(width: 0.5),
                    alignment: .trailing
                )
            rightPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                headline
                Text(copy.subtitle)
                    .font(OnboardingTheme.sans(14))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AutoDetectCard(
                title: copy.autoDetectTitle,
                desc: copy.autoDetectDesc,
                selected: autoHighlighted,
                onTap: selectAuto
            )
            .padding(.top, 22)

            PickLanguageSection(
                title: copy.pickALanguage,
                recommendedBadge: copy.recommendedBadge,
                accuracyNote: copy.pickAccuracyNote,
                query: $query,
                selected: selected,
                state: pickState,
                onActivate: activatePick
            )
            .padding(.top, 14)

            if pickState == .ready {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(copy.pickToContinue)
                        .font(OnboardingTheme.sans(11.5, weight: .medium))
                }
                .foregroundColor(Color(red: 1.0, green: 0.42, blue: 0.42))
                .padding(.top, 8)
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(EdgeInsets(top: 40, leading: 36, bottom: 22, trailing: 28))
    }

    private var headline: some View {
        (
            Text(copy.headlineLead).font(OnboardingTheme.serif(42, language: locale.language))
            + Text(copy.headlineTail).font(OnboardingTheme.serifItalic(42, language: locale.language))
        )
        .foregroundColor(OnboardingTheme.ink)
        .kerning(-0.6)
        .lineSpacing(-6)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text(copy.back)
                }
                .font(OnboardingTheme.sans(13, weight: .medium))
                .foregroundColor(OnboardingTheme.muted)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button(action: onContinue) {
                HStack(spacing: 6) {
                    Text(copy.ccontinue)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(OnboardingTheme.sans(13, weight: .medium))
                .foregroundColor(continueEnabled ? OnboardingTheme.bg : OnboardingTheme.muted)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    Capsule(style: .continuous)
                        .fill(continueEnabled ? OnboardingTheme.ink : OnboardingTheme.surface2)
                )
            }
            .buttonStyle(.plain)
            .disabled(!continueEnabled)
        }
    }

    private var continueEnabled: Bool {
        // The Pick card is engaged but no language was picked yet —
        // user has to either choose a language or fall back to Auto.
        // The inline red hint under the card explains why.
        pickState != .ready
    }

    // MARK: - Right pane

    private var rightPane: some View {
        ZStack {
            LanguageRightPaneBackdrop()
            ScrollView(.vertical, showsIndicators: false) {
                grid
                    .padding(EdgeInsets(top: 36, leading: 28, bottom: 36, trailing: 28))
            }
            if let expandedGroup, !isFiltering {
                LanguageVariantOverlay(
                    group: expandedGroup,
                    countLine: copy.variantCountLine(
                        country: expandedGroup.countryName,
                        count: expandedGroup.variants.count
                    ),
                    selected: selected,
                    onSelect: { language in
                        selectLanguage(language)
                        self.expandedGroup = nil
                    },
                    onDismiss: { self.expandedGroup = nil }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// While the filter is empty the grid shows one tile per country
    /// (`LanguageGroup`); typing flattens it to individual language
    /// matches so an exact search lands directly on the language.
    @ViewBuilder
    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)
        if isFiltering {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(filteredLanguages, id: \.code) { lang in
                    LanguageTile(
                        language: lang,
                        isSelected: selected == lang,
                        onTap: { selectLanguage(lang) }
                    )
                }
            }
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(languageGroups) { group in
                    LanguageGroupTile(
                        group: group,
                        isSelected: group.variants.contains { selected == $0 },
                        onTap: { tapGroup(group) }
                    )
                }
            }
        }
    }

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var languageGroups: [LanguageGroup] {
        LanguageGroup.grouped(AppLanguage.all, selected: selected)
    }

    private func tapGroup(_ group: LanguageGroup) {
        if group.hasVariants {
            withAnimation(.easeInOut(duration: 0.16)) { expandedGroup = group }
        } else {
            selectLanguage(group.representative)
        }
    }

    // MARK: - State derivations + actions

    private var autoHighlighted: Bool {
        selected == nil && !pickActive
    }

    private var pickState: PickLanguageSection.State {
        if selected != nil { return .hasLanguage }
        if pickActive { return .ready }
        return .inactive
    }

    private func selectAuto() {
        selected = nil
        pickActive = false
    }

    private func selectLanguage(_ language: AppLanguage) {
        selected = language
        // Picking a tile auto-promotes the Pick card into the
        // selected-with-language state — the user does not need to
        // click the card itself first.
        pickActive = true
    }

    private func activatePick() {
        pickActive = true
    }

    /// Live filter on `displayName` (native script), `englishName`,
    /// and the ISO code — covers users typing in their own language
    /// ("Русский"), the global English label ("Russian"), or even
    /// "ru" / "RU".
    private var filteredLanguages: [AppLanguage] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return AppLanguage.all }
        return AppLanguage.all.filter { lang in
            lang.displayName.localizedCaseInsensitiveContains(q)
                || lang.englishName.localizedCaseInsensitiveContains(q)
                || lang.code.localizedCaseInsensitiveContains(q)
        }
    }
}

// MARK: - Auto-detect card

private struct AutoDetectCard: View {
    let title: String
    let desc: String
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(selected ? OnboardingTheme.accent : OnboardingTheme.ink2)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? OnboardingTheme.accent.opacity(0.18) : OnboardingTheme.surface2)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(OnboardingTheme.sans(13.5, weight: .semibold))
                        .foregroundColor(OnboardingTheme.ink)
                    Text(desc)
                        .font(OnboardingTheme.sans(12))
                        .foregroundColor(OnboardingTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(OnboardingTheme.accent)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? OnboardingTheme.accent.opacity(0.10) : OnboardingTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? OnboardingTheme.accent.opacity(0.50) : OnboardingTheme.border, lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: selected)
    }
}

// MARK: - Pick a language section (search field + recommended badge)

private struct PickLanguageSection: View {
    enum State { case inactive, ready, hasLanguage }

    let title: String
    let recommendedBadge: String
    let accuracyNote: String
    @Binding var query: String
    let selected: AppLanguage?
    let state: State
    let onActivate: () -> Void
    @FocusState private var fieldFocused: Bool

    private var fillColor: Color {
        switch state {
        case .inactive: return OnboardingTheme.surface
        case .ready: return OnboardingTheme.surface
        case .hasLanguage: return OnboardingTheme.accent.opacity(0.10)
        }
    }

    private var strokeColor: Color {
        switch state {
        case .inactive: return OnboardingTheme.border
        case .ready: return OnboardingTheme.borderStrong
        case .hasLanguage: return OnboardingTheme.accent.opacity(0.55)
        }
    }

    private var strokeWidth: CGFloat {
        state == .inactive ? 0.5 : 0.75
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(OnboardingTheme.sans(13.5, weight: .semibold))
                    .foregroundColor(OnboardingTheme.ink)
                Text(recommendedBadge)
                    .font(OnboardingTheme.mono(9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundColor(OnboardingTheme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(OnboardingTheme.accent.opacity(0.18))
                    )
                Spacer(minLength: 0)
                if let selected {
                    Text(selected.displayName)
                        .font(OnboardingTheme.sans(11.5, weight: .medium))
                        .foregroundColor(OnboardingTheme.accent)
                        .lineLimit(1)
                }
            }

            Text(accuracyNote)
                .font(OnboardingTheme.sans(11.5))
                .foregroundColor(OnboardingTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            // Inner search field — sits nested inside the card; its
            // own fill (surface2) reads as a sub-affordance against the
            // outer card surface so the structure is "card → input".
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(fieldFocused ? OnboardingTheme.accent : OnboardingTheme.ink2)
                TextField("Type to filter — English, Русский, ja…", text: $query)
                    .textFieldStyle(.plain)
                    .font(OnboardingTheme.sans(14, weight: .medium))
                    .foregroundColor(OnboardingTheme.ink)
                    .focused($fieldFocused)
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(OnboardingTheme.faint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(OnboardingTheme.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(fieldFocused ? OnboardingTheme.accent.opacity(0.55) : OnboardingTheme.border, lineWidth: 0.75)
            )
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(strokeColor, lineWidth: strokeWidth)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            onActivate()
            fieldFocused = true
        }
        .animation(.easeInOut(duration: 0.18), value: state)
        .animation(.easeInOut(duration: 0.18), value: fieldFocused)
    }
}

// MARK: - Language tile (right pane grid cell)

private struct LanguageTile: View {
    let language: AppLanguage
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(LanguageFlag.emoji(forLanguageCode: language.code))
                    .font(.system(size: 22))
                Text(language.displayName)
                    .font(OnboardingTheme.sans(10, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(OnboardingTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? OnboardingTheme.accent.opacity(0.14) : OnboardingTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? OnboardingTheme.accent.opacity(0.60) : OnboardingTheme.border, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.16), value: isSelected)
    }
}

// MARK: - Country grouping (Scheme A)

/// One country flag grouping the 1+ languages that share it — e.g.
/// Spain → Español, Català; India → हिन्दी + 6 more. Mirrors the Dynamic
/// Island's `pickerOptions` grouping (same ES→es / IN→hi representative
/// preference) so the grid shows one flag per country and reveals the
/// languages underneath on tap. Kept local to the onboarding so the
/// `OnboardingPreview` SPM target stays free of Island dependencies.
struct LanguageGroup: Identifiable, Equatable {
    let countryCode: String
    let flag: String
    let representative: AppLanguage
    /// Representative first, then the remaining variants in list order.
    let variants: [AppLanguage]

    var id: String { countryCode }
    var hasVariants: Bool { variants.count > 1 }

    /// Localised country name for the variant popover header ("Spain"),
    /// falling back to the raw region code.
    var countryName: String {
        Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode
    }

    private static let preferredRepresentative: [String: String] = [
        "ES": "es",   // Spanish over Catalan/Galician/Asturian
        "IN": "hi",   // Hindi over the other Indian languages
        "ZA": "zu",   // Zulu over Afrikaans/Xhosa/Northern Sotho
        "NG": "ha",   // Hausa over Igbo/Yoruba
    ]

    static func grouped(
        _ languages: [AppLanguage],
        selected: AppLanguage?
    ) -> [LanguageGroup] {
        var order: [String] = []
        var byCountry: [String: [AppLanguage]] = [:]
        for language in languages {
            let code = LanguageFlag.countryCode(forLanguageCode: language.code)
            if byCountry[code] == nil {
                order.append(code)
                byCountry[code] = []
            }
            byCountry[code]?.append(language)
        }
        return order.compactMap { code in
            guard let variants = byCountry[code], !variants.isEmpty else { return nil }
            let representative = representative(
                forCountryCode: code,
                variants: variants,
                selected: selected
            )
            let ordered = [representative] + variants.filter { $0 != representative }
            return LanguageGroup(
                countryCode: code,
                flag: LanguageFlag.emoji(forCountryCode: code),
                representative: representative,
                variants: ordered
            )
        }
    }

    private static func representative(
        forCountryCode code: String,
        variants: [AppLanguage],
        selected: AppLanguage?
    ) -> AppLanguage {
        if let selected,
           LanguageFlag.countryCode(forLanguageCode: selected.code) == code,
           variants.contains(selected) {
            return selected
        }
        if let preferred = preferredRepresentative[code],
           let match = variants.first(where: { $0.code == preferred }) {
            return match
        }
        return variants[0]
    }
}

// MARK: - Country group tile (right pane grid cell)

private struct LanguageGroupTile: View {
    let group: LanguageGroup
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(group.flag)
                    .font(.system(size: 22))
                Text(group.representative.displayName)
                    .font(OnboardingTheme.sans(10, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(OnboardingTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? OnboardingTheme.accent.opacity(0.14) : OnboardingTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? OnboardingTheme.accent.opacity(0.60) : OnboardingTheme.border, lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if group.hasVariants {
                    Text("+\(group.variants.count - 1)")
                        .font(OnboardingTheme.mono(8, weight: .semibold))
                        .foregroundColor(OnboardingTheme.accent)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule(style: .continuous).fill(OnboardingTheme.surface3))
                        .padding(5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.16), value: isSelected)
    }
}

// MARK: - Variant popover (expanded multi-language country)

private struct LanguageVariantOverlay: View {
    let group: LanguageGroup
    /// Pre-localized header count line (e.g. "Spain · 3 languages" /
    /// "Испания · 3 языка"), built by the parent so the natural plural
    /// matches the active onboarding UI language.
    let countLine: String
    let selected: AppLanguage?
    let onSelect: (AppLanguage) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
            card
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.flag)
                    .font(.system(size: 17))
                Text(countLine)
                    .font(OnboardingTheme.mono(10, weight: .medium))
                    .tracking(0.4)
                    .foregroundColor(OnboardingTheme.faint)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)

            ForEach(group.variants, id: \.code) { language in
                Button(action: { onSelect(language) }) {
                    HStack(spacing: 8) {
                        Text(language.displayName)
                            .font(OnboardingTheme.sans(13, weight: selected == language ? .semibold : .regular))
                            .foregroundColor(OnboardingTheme.ink)
                        Spacer(minLength: 0)
                        if selected == language {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(OnboardingTheme.accent)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected == language ? OnboardingTheme.accent.opacity(0.14) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(selected == language ? OnboardingTheme.accent.opacity(0.45) : Color.clear, lineWidth: 0.5)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OnboardingTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OnboardingTheme.borderStrong, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 14)
        // Swallow taps on the card so they don't fall through to dismiss.
        .onTapGesture {}
    }
}

// MARK: - Right pane backdrop

private struct LanguageRightPaneBackdrop: View {
    var body: some View {
        OnboardingTheme.surface2
            .overlay(
                ZStack {
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: OnboardingTheme.accent.opacity(0.18), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.80, y: 0.10),
                        startRadius: 0,
                        endRadius: 620
                    )
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.03), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.10, y: 1.0),
                        startRadius: 0,
                        endRadius: 520
                    )
                }
            )
    }
}

// MARK: - Emoji flags

/// Converts an ISO-639-1 language code into the matching Unicode
/// regional-indicator emoji flag. Maps each language to its
/// representative country (e.g. `en → US`, `fr → FR`, `hi → IN`) —
/// the table mirrors `IslandDropModeControl.languageCountryCodes`.
/// We use emoji rather than the bundled PNG flags here so the
/// onboarding works in both the Sidekey app (no asset wiring) and
/// the `OnboardingPreview` SPM target (no resource copy needed).
enum LanguageFlag {
    /// Representative ISO 3166-1 country for a language code, used both
    /// for the flag emoji and for grouping languages that share a flag
    /// (`LanguageGroup`). Falls back to the uppercased language code.
    static func countryCode(forLanguageCode code: String) -> String {
        countryCodes[code] ?? code.uppercased()
    }

    static func emoji(forLanguageCode code: String) -> String {
        emoji(forCountryCode: countryCode(forLanguageCode: code))
    }

    static func emoji(forCountryCode countryCode: String) -> String {
        countryCode.uppercased().unicodeScalars
            .compactMap { Unicode.Scalar(127397 + $0.value) }
            .map { String($0) }
            .joined()
    }

    private static let countryCodes: [String: String] = [
        "ar": "SA", "be": "BY", "bg": "BG", "bn": "BD", "bs": "BA",
        "ca": "ES", "cs": "CZ", "da": "DK", "de": "DE", "el": "GR",
        "en": "US", "es": "ES", "et": "EE", "fa": "IR", "fi": "FI",
        "fr": "FR", "gu": "IN", "he": "IL", "hi": "IN", "hr": "HR",
        "hu": "HU", "id": "ID", "it": "IT", "ja": "JP", "kn": "IN",
        "ko": "KR", "lt": "LT", "lv": "LV", "mk": "MK", "ml": "IN",
        "mr": "IN", "ms": "MY", "nl": "NL", "no": "NO", "pl": "PL",
        "pt": "PT", "ro": "RO", "ru": "RU", "sk": "SK", "sl": "SI",
        "sr": "RS", "sv": "SE", "ta": "IN", "te": "IN", "th": "TH",
        "tl": "PH", "tr": "TR", "uk": "UA", "ur": "PK", "vi": "VN",
        "zh": "CN",
        // Expanded ElevenLabs Scribe set. Keep in sync with
        // `IslandDropModeControl.languageCountryCodes`.
        "af": "ZA", "am": "ET", "as": "IN", "ast": "ES", "az": "AZ",
        "ceb": "PH", "cy": "GB", "ff": "SN", "ga": "IE", "gl": "ES",
        "ha": "NG", "ig": "NG", "is": "IS", "jv": "ID", "ka": "GE",
        "kea": "CV", "kk": "KZ", "km": "KH", "ku": "IQ", "ky": "KG",
        "lb": "LU", "lg": "UG", "ln": "CD", "lo": "LA", "luo": "KE",
        "mi": "NZ", "mn": "MN", "mt": "MT", "my": "MM", "ne": "NP",
        "nso": "ZA", "ny": "MW", "oc": "FR", "or": "IN", "pa": "IN",
        "ps": "AF", "sd": "PK", "sn": "ZW", "so": "SO", "sw": "TZ",
        "tg": "TJ", "umb": "AO", "uz": "UZ", "wo": "SN", "xh": "ZA",
        "yo": "NG", "yue": "HK", "zu": "ZA"
    ]
}
