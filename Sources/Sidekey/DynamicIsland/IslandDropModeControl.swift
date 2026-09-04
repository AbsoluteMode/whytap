import CoreGraphics
import Foundation

enum IslandHoverPanelIconStyle {
    static let legacyCircleSize: CGFloat = 28
    static let circleSize: CGFloat = 48
    /// Used by hover-panel tiles when a row needs to fit six entries.
    /// 34pt keeps the orb visually centered inside the 48pt tile width.
    static let compactCircleSize: CGFloat = 34
    static let ringContentScale: CGFloat = 0.64
    static let ringSystemFontSize: CGFloat = 18.5
    static let ringFlagFontSize: CGFloat = 24
    static let dynamicSystemFontSize: CGFloat = 20
    static let dynamicFlagFontSize: CGFloat = 24
    static let fallbackSystemFontSize: CGFloat = 15
}

enum IslandGraphiteHoverControlStyle {
    static let tileSize: CGFloat = 44
    static let cornerRadius: CGFloat = 11
    static let magnetStrength: CGFloat = 8
    static let labelFontSize: CGFloat = 8
    static let labelTracking: CGFloat = 0.8
    static let iconFontSize: CGFloat = 18
    static let textIconFontSize: CGFloat = 16
    static let textIconFrameSize = CGSize(width: 40, height: 25)
    static let textIconOpticalYOffset: CGFloat = -0.5
    static let textIconUsesOffscreenRendering = true

    static func magneticPull(location: CGPoint, bounds: CGSize) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let dx = (location.x - bounds.width / 2) / bounds.width
        let dy = (location.y - bounds.height / 2) / bounds.height

        return CGSize(
            width: min(max(dx, -1), 1) * magnetStrength,
            height: min(max(dy, -1), 1) * magnetStrength
        )
    }
}

enum IslandDropModeControl {
    static let title = "Drop Mode"
    /// Hover panel height. Sized to accommodate the language-picker
    /// overlay (4 flag rows + input row); the single-row controls tile
    /// grid centres itself within this space.
    /// Minimum: edgeInset(5) + chipH(20) + startY(48) + 3*minimumStride(72) = 145.
    static let hoverPanelHeight: CGFloat = 145
    static let modeCircleSize: CGFloat = IslandHoverPanelIconStyle.circleSize
    /// Gap between the compact island and the detached hover panel.
    static let detachedPanelGap: CGFloat = 8
    /// Top gap between the Dynamic Island and the music strip. Matches
    /// `musicStripBottomGap` (strip → hover panel) so the player sits an equal
    /// distance from the island above and the controls panel below. Stays > 0 so
    /// a thin transparent slice remains inside the hover hit zone, letting the
    /// cursor travel island -> strip without collapsing the expansion. The
    /// band-height math (`hoverPanelHeight(for:musicActive:)`) is unaffected by
    /// this value: the hover panel below absorbs the difference, so the total
    /// drawer height stays `activeHoverPanelHeight`.
    static let musicStripTopGap: CGFloat = 8
    /// Height of the Now Playing player strip — the hover-gated player row
    /// that renders in the gap between the compact island and the hover
    /// panel while a track is active AND the island is hover-expanded.
    /// Houses the album-art tile + a one-line title · artist marquee +
    /// transport buttons. Compact (down from the old 52 pt always-on strip)
    /// so the row reads tight; the one-line layout fits comfortably.
    static let musicStripHeight: CGFloat = 42
    /// Gap BELOW the music strip, separating it from the hover panel so the
    /// player reads as its own floating card instead of fusing with the
    /// controls drawer (they used to sit flush, their rounded corners
    /// colliding). Added on top of the band height so the panel keeps its full
    /// size — the drawer grows by `musicStripHeight + musicStripBottomGap`.
    // WHY: docs/decisions/2026-06-16-island-music-progress-and-gap.md
    static let musicStripBottomGap: CGFloat = 8
    /// Hover band height while the History inline panel is on screen. The
    /// History content (mode row + 5 visible rows + hint) is ~267pt — far
    /// taller than the default 145pt band — so the band grows with the mode
    /// (and shrinks back on `.controls`). 8pt of bottom breathing room keeps
    /// the hint row off the band's clipped edge.
    static let historyHoverPanelHeight: CGFloat =
        detachedPanelGap + HistoryHoverView.requiredContentHeight + 8
    /// Uniform corner radius of the detached hover panel.
    static let detachedPanelCornerRadius: CGFloat = 16
    static let statusDisplaySeconds: TimeInterval = 3

    static func label(for mode: TranscriptionMode) -> String {
        switch mode {
        case .fast:
            return "Fast"
        case .smart:
            return "Smart"
        }
    }

    static let statusActiveLabel = "ON"

    static func statusModeLabel(for mode: TranscriptionMode) -> String {
        label(for: mode)
    }

    static func statusAccessibilityLabel(for mode: TranscriptionMode) -> String {
        "\(statusActiveLabel) \(statusModeLabel(for: mode))"
    }

    static func hoverTileLabel(for mode: TranscriptionMode) -> String? {
        nil
    }

    static func systemImage(for mode: TranscriptionMode) -> String {
        switch mode {
        case .fast:
            return "bolt"
        case .smart:
            return "sparkles"
        }
    }

    /// Bundled PDF orb (no SF Symbol background circle) used by the
    /// hover-panel control when `IslandHoverPanelControl` is rendered in
    /// PDF-orb mode. Converted from Maxim's hand-drawn SVGs in
    /// `svg v2/` via `rsvg-convert -f pdf`; loaded through
    /// `IslandControlIcon.image()`.
    static func pdfResource(for mode: TranscriptionMode) -> String {
        switch mode {
        case .fast:
            return "island-drop-fast"
        case .smart:
            return "island-drop-smart"
        }
    }

    static func nextMode(after mode: TranscriptionMode) -> TranscriptionMode {
        switch mode {
        case .fast:
            return .smart
        case .smart:
            return .fast
        }
    }
}

/// Hand-crafted liquid-glass styling for the detached hover panel.
///
/// Why hand-crafted: `NSGlassEffectView` cannot refract content BEHIND a
/// transparent borderless window — it silently degrades to the same frosted
/// blur as `NSVisualEffectView` (verified empirically June 2026: tint and
/// contentView probes invisible, in-window backdrop sandwich changed
/// nothing; matches cmux#3508 / ghostty#10170). The full liquid effect is
/// reserved for in-window backdrops, so the panel builds the look manually:
/// frosted blur + depth wash + top specular + edge lens + crisp rim. Bonus:
/// identical rendering on macOS 14/15 too.
enum IslandDetachedHoverPanelGlassStyle {
    /// Vertical darkening — glass reads thicker toward the bottom.
    static let depthWashTopOpacity: Double = 0.05
    static let depthWashBottomOpacity: Double = 0.16
    /// Soft ceiling-light reflection hugging the top edge.
    static let specularOpacity: Double = 0.11
    static let specularHeight: CGFloat = 58
    static let specularBlurRadius: CGFloat = 14
    /// Wide blurred inner stroke — imitates the bent-light band a real
    /// glass slab shows along its edges.
    static let lensStrokeTopOpacity: Double = 0.30
    static let lensStrokeBottomOpacity: Double = 0.07
    static let lensStrokeWidth: CGFloat = 2.2
    static let lensBlurRadius: CGFloat = 1.6
    /// Crisp 0.8px rim on the very edge — the facet cut.
    static let rimTopOpacity: Double = 0.48
    static let rimBottomOpacity: Double = 0.12
    static let rimWidth: CGFloat = 0.8
}

enum IslandDropModeStatusStyle {
    static let usesContainerChrome = false
    static let activeUsesSimpleRing = true
    static let activeRingSize: CGFloat = 20
    static let activeRingLineWidth: CGFloat = 0.9
    static let activeRed: Double = 0.34
    static let activeGreen: Double = 0.94
    static let activeBlue: Double = 0.58
    static let activeOpacity: Double = 0.96
}

enum IslandMeetingCountdown {
    static let ringLineWidth: CGFloat = 2
    static let backgroundRingOpacity: Double = 0.22
    static let foregroundRingOpacity: Double = 0.92
    static let textFontSize: CGFloat = 9.2
    static let verticalOffset: CGFloat = -1

    static func remainingSeconds(now: Date, deadline: Date) -> Int {
        Int(ceil(max(0, deadline.timeIntervalSince(now))))
    }

    static func progress(now: Date, deadline: Date, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(deadline.timeIntervalSince(now) / duration, 0), 1)
    }

    static func circleSize(forCompactHeight compactHeight: CGFloat) -> CGFloat {
        min(26, max(20, compactHeight - 12))
    }
}

struct IslandMeetingRecordingSnapshot: Equatable {
    let duration: TimeInterval
    let levels: [Double]
    let isPaused: Bool
}

enum IslandMeetingRecordingSlot {
    static let width: CGFloat = 64
    static let topHeight: CGFloat = 12
    static let waveHeight: CGFloat = 10
    static let verticalSpacing: CGFloat = 2
    static let stopButtonSize: CGFloat = 12
    static let stopCornerRadius: CGFloat = 3
    static let timerFontSize: CGFloat = 11
    static let barCount = 12
    static let barWidth: CGFloat = 2
    static let minimumVisibleLevel: Double = 0.1
    static let verticalOffset: CGFloat = -1

    static var totalHeight: CGFloat {
        topHeight + verticalSpacing + waveHeight
    }

    static func formattedElapsed(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        if seconds >= 3_600 {
            return String(format: "%d:%02d", seconds / 3_600, (seconds % 3_600) / 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func normalizedLevel(_ level: Double) -> Double {
        min(1, max(minimumVisibleLevel, level))
    }

    static func appendingLevel(
        to existing: [Double],
        level: Double
    ) -> [Double] {
        let history = Array(existing.suffix(max(0, barCount - 1)))
        let padding = Array(
            repeating: minimumVisibleLevel,
            count: max(0, barCount - 1 - history.count)
        )
        return padding + history + [normalizedLevel(level)]
    }

    static func displayLevels(_ levels: [Double]) -> [Double] {
        let history = Array(levels.suffix(barCount))
        let padding = Array(
            repeating: minimumVisibleLevel,
            count: max(0, barCount - history.count)
        )
        return padding + history
    }
}

struct IslandLanguageOption: Identifiable, Equatable {
    let id: String
    let language: AppLanguage?
    let label: String
    let flag: String
    let searchText: String
    let countryCode: String?
    let variantLanguages: [AppLanguage]

    init(
        id: String,
        language: AppLanguage?,
        label: String,
        flag: String,
        searchText: String,
        countryCode: String? = nil,
        variantLanguages: [AppLanguage] = []
    ) {
        self.id = id
        self.language = language
        self.label = label
        self.flag = flag
        self.searchText = searchText
        self.countryCode = countryCode
        self.variantLanguages = variantLanguages
    }

    var hasLanguageVariants: Bool {
        variantLanguages.count > 1
    }
}

enum IslandHoverIconPresentation: Equatable {
    case pdfResource(String)
    case systemImage(String)
    case flag(String)
    case text(String)
    case pdfRingedSystemImage(ringResource: String, systemImage: String)
    case pdfRingedFlag(ringResource: String, flag: String)
}

extension IslandGraphiteHoverControlStyle {
    static func magneticPull(
        location: CGPoint,
        bounds: CGSize,
        presentation: IslandHoverIconPresentation?
    ) -> CGSize {
        magneticPull(location: location, bounds: bounds)
    }
}

enum IslandLanguageControl {
    static let title = "Input Language"
    static let systemImage = "globe"
    static let circleSize: CGFloat = IslandHoverPanelIconStyle.circleSize
    /// Bundled PDF orb used in PDF-mode (see `IslandHoverPanelControl`).
    static let pdfResource = "island-language"
    static let ringOnlyPdfResource = "island-language-ring"
    static let autoOptionID = "auto"
    static let placeholderIntervalSeconds: TimeInterval = 1.8
    static let placeholderSamples = [
        "en",
        "ru",
        "zh",
        "es",
        "ja",
        "de",
        "fr",
    ].compactMap { AppLanguage.find(code: $0)?.displayName }

    private static let languageCountryCodes: [String: String] = [
        "ar": "SA",
        "be": "BY",
        "bg": "BG",
        "bn": "BD",
        "bs": "BA",
        "ca": "ES",
        "cs": "CZ",
        "da": "DK",
        "de": "DE",
        "el": "GR",
        "en": "US",
        "es": "ES",
        "et": "EE",
        "fa": "IR",
        "fi": "FI",
        "fr": "FR",
        "gu": "IN",
        "he": "IL",
        "hi": "IN",
        "hr": "HR",
        "hu": "HU",
        "id": "ID",
        "it": "IT",
        "ja": "JP",
        "kn": "IN",
        "ko": "KR",
        "lt": "LT",
        "lv": "LV",
        "mk": "MK",
        "ml": "IN",
        "mr": "IN",
        "ms": "MY",
        "nl": "NL",
        "no": "NO",
        "pl": "PL",
        "pt": "PT",
        "ro": "RO",
        "ru": "RU",
        "sk": "SK",
        "sl": "SI",
        "sr": "RS",
        "sv": "SE",
        "ta": "IN",
        "te": "IN",
        "th": "TH",
        "tl": "PH",
        "tr": "TR",
        "uk": "UA",
        "ur": "PK",
        "vi": "VN",
        "zh": "CN",
        // Expanded ElevenLabs Scribe set. Keep in sync with
        // `LanguageFlag.countryCodes` in OnboardingLanguageScreen.
        "af": "ZA", "am": "ET", "as": "IN", "ast": "ES", "az": "AZ",
        "ceb": "PH", "cy": "GB", "ff": "SN", "ga": "IE", "gl": "ES",
        "ha": "NG", "ig": "NG", "is": "IS", "jv": "ID", "ka": "GE",
        "kea": "CV", "kk": "KZ", "km": "KH", "ku": "IQ", "ky": "KG",
        "lb": "LU", "lg": "UG", "ln": "CD", "lo": "LA", "luo": "KE",
        "mi": "NZ", "mn": "MN", "mt": "MT", "my": "MM", "ne": "NP",
        "nso": "ZA", "ny": "MW", "oc": "FR", "or": "IN", "pa": "IN",
        "ps": "AF", "sd": "PK", "sn": "ZW", "so": "SO", "sw": "TZ",
        "tg": "TJ", "umb": "AO", "uz": "UZ", "wo": "SN", "xh": "ZA",
        "yo": "NG", "yue": "HK", "zu": "ZA",
    ]

    private static let preferredRepresentativeLanguageCodes: [String: String] = [
        "ES": "es",
        "IN": "hi",
        "ZA": "zu",
        "NG": "ha",
    ]

    static func label(for language: AppLanguage?) -> String {
        language?.displayName ?? "Auto"
    }

    static func hoverTileLabel(for language: AppLanguage?) -> String? {
        nil
    }

    static func hoverIconPresentation(for language: AppLanguage?) -> IslandHoverIconPresentation {
        guard let language else {
            return .systemImage(systemImage)
        }
        return .text(languageCodeBadge(for: language))
    }

    static func options(
        languages: [AppLanguage] = AppLanguage.all,
        leading: IslandLanguageOption? = nil
    ) -> [IslandLanguageOption] {
        [leading ?? autoOption()] + languages.map { option(for: $0) }
    }

    static func pickerOptions(
        selectedLanguage: AppLanguage? = nil,
        languages: [AppLanguage] = AppLanguage.common,
        leading: IslandLanguageOption? = nil
    ) -> [IslandLanguageOption] {
        var languages = languages
        // Keep the active selection visible even when it's a long-tail
        // language outside the curated common set (reached via search).
        if let selectedLanguage, !languages.contains(selectedLanguage) {
            languages.append(selectedLanguage)
        }
        let groupedLanguages = Dictionary(grouping: languages) {
            countryCode(forLanguageCode: $0.code)
        }
        var seenCountryCodes: Set<String> = []
        let countryCodes = languages.compactMap { language -> String? in
            let countryCode = countryCode(forLanguageCode: language.code)
            guard seenCountryCodes.insert(countryCode).inserted else { return nil }
            return countryCode
        }
        let languageOptions = countryCodes.compactMap { countryCode -> IslandLanguageOption? in
            guard let variants = groupedLanguages[countryCode], !variants.isEmpty else {
                return nil
            }
            let representative = representativeLanguage(
                forCountryCode: countryCode,
                variants: variants,
                selectedLanguage: selectedLanguage
            )
            let orderedVariants = orderedVariantLanguages(
                variants,
                representative: representative
            )
            return groupedOption(
                countryCode: countryCode,
                representative: representative,
                variants: orderedVariants
            )
        }

        return [leading ?? autoOption()] + languageOptions
    }

    static func variantOptions(for option: IslandLanguageOption) -> [IslandLanguageOption] {
        guard option.hasLanguageVariants else {
            return [option]
        }

        return option.variantLanguages.map { language in
            self.option(
                for: language,
                countryCode: option.countryCode ?? countryCode(forLanguageCode: language.code)
            )
        }
    }

    static func filteredOptions(
        query: String,
        languages: [AppLanguage] = AppLanguage.all,
        leading: IslandLanguageOption? = nil
    ) -> [IslandLanguageOption] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else {
            return options(languages: languages, leading: leading)
        }
        return options(languages: languages, leading: leading).filter {
            $0.searchText.contains(normalizedQuery)
        }
    }

    static func placeholder(at time: TimeInterval) -> String {
        guard !placeholderSamples.isEmpty else {
            return title
        }

        let interval = max(placeholderIntervalSeconds, 0.1)
        let boundedTime = max(time, 0)
        let sampleIndex = Int(boundedTime / interval) % placeholderSamples.count
        let sample = placeholderSamples[sampleIndex]
        let progress = (boundedTime.truncatingRemainder(dividingBy: interval)) / interval
        let characters = Array(sample)
        let typedProgress = min(progress / 0.72, 1)
        let visibleCount = max(1, Int(ceil(Double(characters.count) * typedProgress)))

        return String(characters.prefix(min(visibleCount, characters.count)))
    }

    static func countryCode(forLanguageCode languageCode: String) -> String {
        languageCountryCodes[languageCode] ?? languageCode.uppercased()
    }

    static func flag(forLanguageCode languageCode: String) -> String {
        flag(forCountryCode: countryCode(forLanguageCode: languageCode))
    }

    static func flag(forCountryCode countryCode: String) -> String {
        let base: UInt32 = 127397
        let scalars = countryCode.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value)
        }
        guard scalars.count == 2 else { return countryCode.uppercased() }
        return String(String.UnicodeScalarView(scalars))
    }

    static func flagAssetResourceName(forCountryCode countryCode: String) -> String {
        "flag_\(countryCode.lowercased())"
    }

    static func languageCodeBadge(for language: AppLanguage) -> String {
        language.code
            .split(separator: "-")
            .first
            .map { String($0).uppercased() }
            ?? language.code.uppercased()
    }

    static func autoOption() -> IslandLanguageOption {
        IslandLanguageOption(
            id: autoOptionID,
            language: nil,
            label: "Auto",
            flag: "auto",
            searchText: normalizedSearchText(["auto", "automatic", "detect"])
        )
    }

    static func offOption() -> IslandLanguageOption {
        IslandLanguageOption(
            id: "off",
            language: nil,
            label: "Off",
            flag: "off",
            searchText: normalizedSearchText(["off", "none", "same", "no translation"])
        )
    }

    private static func option(
        for language: AppLanguage,
        countryCode: String? = nil
    ) -> IslandLanguageOption {
        let resolvedCountryCode = countryCode ?? Self.countryCode(forLanguageCode: language.code)
        return IslandLanguageOption(
            id: language.code,
            language: language,
            label: language.displayName,
            flag: flag(forCountryCode: resolvedCountryCode),
            searchText: normalizedSearchText([
                language.code,
                language.displayName,
                language.englishName,
            ]),
            countryCode: resolvedCountryCode,
            variantLanguages: [language]
        )
    }

    private static func groupedOption(
        countryCode: String,
        representative: AppLanguage,
        variants: [AppLanguage]
    ) -> IslandLanguageOption {
        IslandLanguageOption(
            id: "country-\(countryCode)",
            language: representative,
            label: representative.displayName,
            flag: flag(forCountryCode: countryCode),
            searchText: normalizedSearchText(
                variants.flatMap { [$0.code, $0.displayName, $0.englishName] }
            ),
            countryCode: countryCode,
            variantLanguages: variants
        )
    }

    private static func representativeLanguage(
        forCountryCode countryCode: String,
        variants: [AppLanguage],
        selectedLanguage: AppLanguage?
    ) -> AppLanguage {
        if let selectedLanguage,
           Self.countryCode(forLanguageCode: selectedLanguage.code) == countryCode,
           variants.contains(selectedLanguage) {
            return selectedLanguage
        }
        if let preferredCode = preferredRepresentativeLanguageCodes[countryCode],
           let preferred = variants.first(where: { $0.code == preferredCode }) {
            return preferred
        }
        return variants[0]
    }

    private static func orderedVariantLanguages(
        _ variants: [AppLanguage],
        representative: AppLanguage
    ) -> [AppLanguage] {
        [representative] + variants.filter { $0 != representative }
    }

    private static func normalizedSearchText(_ parts: [String]) -> String {
        normalize(parts.joined(separator: " "))
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
    }
}

/// Output (target) language tile: reuses `IslandLanguageControl` for the
/// flag/badge icon and the picker option list, but owns the tile title, the
/// Fast-mode notice copy, and the tap behaviour (Smart opens the picker; Fast
/// shows a "Smart only" notice instead).
enum IslandOutputLanguageControl {
    static let title = "Output Language"
    static let smartOnlyNotice = "Available in Smart mode"

    enum Tap: Equatable {
        case openPicker
        case showSmartOnlyNotice
    }

    static func tap(for mode: TranscriptionMode) -> Tap {
        mode == .smart ? .openPicker : .showSmartOnlyNotice
    }
}

enum IslandLanguageFlagChipStyle {
    static let autoHoverScale: CGFloat = 1.08
    static let languageHoverScale: CGFloat = 1.16
    static let autoFontSize: CGFloat = 9
    static let languageFontSize: CGFloat = 22
    static let filteredAutoFontSize: CGFloat = 12
    static let filteredLanguageFontSize: CGFloat = 24
    static let variantLanguageFontSize: CGFloat = 9
    static let pngOpacity: Double = 0.96
    static let pngSaturation: Double = 0.92
    static let pngBrightness: Double = -0.02

    static func usesCapsuleChrome(for option: IslandLanguageOption) -> Bool {
        option.language == nil
    }

    static func hoverScale(for option: IslandLanguageOption) -> CGFloat {
        usesCapsuleChrome(for: option) ? autoHoverScale : languageHoverScale
    }

    static func fontSize(for option: IslandLanguageOption, enlarged: Bool) -> CGFloat {
        switch (option.language == nil, enlarged) {
        case (true, true):
            return filteredAutoFontSize
        case (true, false):
            return autoFontSize
        case (false, true):
            return filteredLanguageFontSize
        case (false, false):
            return languageFontSize
        }
    }
}

enum IslandLanguageInputStyle {
    static let cursorWidth: CGFloat = 0.75
    static let cursorWhiteComponent: CGFloat = 0.62
    static let cursorAlpha: CGFloat = 0.9
}

enum IslandLanguagePickerLayout {
    static let inputSize = CGSize(width: 98, height: 18)
    static let maxInputWidth: CGFloat = 170
    static let flagChipSize = CGSize(width: 24, height: 20)
    static let autoChipSize = CGSize(width: 34, height: 20)
    static let filteredFlagChipSize = CGSize(width: 34, height: 26)
    static let variantChipSize = CGSize(width: 72, height: 22)
    static let edgeInset: CGFloat = 5
    static let chipSpacing: CGFloat = 1
    static let filteredChipSpacing: CGFloat = 4
    static let variantChipSpacing: CGFloat = 5
    static let inputHorizontalGap: CGFloat = 5
    private static let inputTopInset: CGFloat = 24
    private static let inputToFlagGap: CGFloat = 6
    private static let flagRowCount = 4
    private static let rowVerticalSpacing: CGFloat = 4

    static func inputFrame(
        panelSize: CGSize,
        optionCount: Int? = nil,
        anchorsToFullGrid: Bool = true
    ) -> CGRect {
        guard let optionCount else {
            return centeredInputFrame(panelSize: panelSize, width: inputSize.width)
        }

        guard anchorsToFullGrid else {
            return filteredRows(panelSize: panelSize, count: optionCount).input
        }

        return rows(panelSize: panelSize, count: optionCount).input
    }

    static func flagFrames(
        panelSize: CGSize,
        count: Int,
        anchorsToFullGrid: Bool = true
    ) -> [CGRect] {
        guard anchorsToFullGrid else {
            return filteredRows(panelSize: panelSize, count: count).flagFrames
        }

        return rows(panelSize: panelSize, count: count).flagFrames
    }

    static func variantFrames(panelSize: CGSize, count: Int) -> [CGRect] {
        choiceRows(
            panelSize: panelSize,
            count: count,
            chipSize: variantChipSize(panelSize: panelSize, count: count),
            spacing: variantChipSpacing,
            centersRows: true
        ).flagFrames
    }

    private struct Rows {
        let top: [CGRect]
        let middle: [CGRect]
        let bottom: [CGRect]
        let input: CGRect

        var flagFrames: [CGRect] {
            top + middle + bottom
        }
    }

    private static func rows(panelSize: CGSize, count: Int) -> Rows {
        guard count > 0 else {
            return choiceRows(
                panelSize: panelSize,
                count: count,
                chipSize: flagChipSize,
                spacing: chipSpacing
            )
        }

        let languageRows = choiceRows(
            panelSize: panelSize,
            count: count - 1,
            chipSize: flagChipSize,
            spacing: chipSpacing
        )
        let autoFrame = leadingInputChipFrame(
            panelSize: panelSize,
            input: languageRows.input,
            chipSize: autoChipSize
        )

        return Rows(
            top: [autoFrame] + languageRows.flagFrames,
            middle: [],
            bottom: [],
            input: languageRows.input
        )
    }

    private static func choiceRows(
        panelSize: CGSize,
        count: Int,
        chipSize: CGSize,
        spacing: CGFloat,
        centersRows: Bool = false
    ) -> Rows {
        let input = topInputFrame(panelSize: panelSize, width: maxInputWidth)
        guard count > 0 else {
            return Rows(top: [], middle: [], bottom: [], input: input)
        }

        let fullRowCount = rowCapacity(
            availableWidth: panelSize.width - 2 * edgeInset,
            chipSize: chipSize,
            spacing: spacing
        )
        guard fullRowCount > 0 else {
            return Rows(top: [], middle: [], bottom: [], input: input)
        }

        let startY = input.maxY + inputToFlagGap
        let normalRowStride = rowStride(
            panelSize: panelSize,
            startY: startY,
            chipHeight: chipSize.height
        )
        let minX = edgeInset
        let maxX = panelSize.width - edgeInset
        let rowCount = Int(ceil(Double(count) / Double(fullRowCount)))
        let top = balancedMultiRowFrames(
            startY: startY,
            rowCounts: balancedRowCounts(total: count, rowCount: rowCount),
            minX: minX,
            maxX: maxX,
            rowStride: normalRowStride,
            chipSize: chipSize,
            spacing: spacing,
            centersRows: centersRows
        )

        return Rows(
            top: top,
            middle: [],
            bottom: [],
            input: input
        )
    }

    private static func variantChipSize(panelSize: CGSize, count: Int) -> CGSize {
        guard count > 1 else { return variantChipSize }

        let availableWidth = panelSize.width - 2 * edgeInset
        let singleRowWidth = floor(
            (availableWidth - CGFloat(count - 1) * variantChipSpacing) / CGFloat(count)
        )
        let resolvedWidth = max(36, min(variantChipSize.width, singleRowWidth))

        return CGSize(width: resolvedWidth, height: variantChipSize.height)
    }

    private static func filteredRows(panelSize: CGSize, count: Int) -> Rows {
        let input = topInputFrame(panelSize: panelSize, width: maxInputWidth)
        guard count > 0 else {
            return Rows(top: [], middle: [], bottom: [], input: input)
        }

        let fullRowCount = rowCapacity(
            availableWidth: panelSize.width - 2 * edgeInset,
            chipSize: filteredFlagChipSize,
            spacing: filteredChipSpacing
        )
        guard fullRowCount > 0 else {
            return Rows(top: [], middle: [], bottom: [], input: input)
        }

        let startY = input.maxY + inputToFlagGap
        let top = count <= fullRowCount
            ? centeredRowFrames(
                y: startY,
                count: count,
                minX: edgeInset,
                maxX: panelSize.width - edgeInset,
                chipSize: filteredFlagChipSize,
                spacing: filteredChipSpacing
            )
            : multiRowFrames(
                startY: startY,
                count: count,
                rowCapacity: fullRowCount,
                minX: edgeInset,
                maxX: panelSize.width - edgeInset,
                rowStride: rowStride(
                    panelSize: panelSize,
                    startY: startY,
                    chipHeight: filteredFlagChipSize.height
                ),
                chipSize: filteredFlagChipSize,
                spacing: filteredChipSpacing
            )

        return Rows(
            top: top,
            middle: [],
            bottom: [],
            input: input
        )
    }

    private static func centeredInputFrame(panelSize: CGSize, width: CGFloat) -> CGRect {
        let panelMax = max(
            inputSize.width,
            panelSize.width - 2 * (edgeInset + inputHorizontalGap)
        )
        let resolvedWidth = min(width, panelMax)
        return CGRect(
            x: (panelSize.width - resolvedWidth) / 2,
            y: (panelSize.height - inputSize.height) / 2,
            width: resolvedWidth,
            height: inputSize.height
        )
    }

    private static func topInputFrame(panelSize: CGSize, width: CGFloat) -> CGRect {
        let panelMax = max(
            inputSize.width,
            panelSize.width - 2 * (edgeInset + inputHorizontalGap)
        )
        let resolvedWidth = min(width, panelMax)
        return CGRect(
            x: (panelSize.width - resolvedWidth) / 2,
            y: min(inputTopInset, max(edgeInset, panelSize.height - edgeInset - inputSize.height)),
            width: resolvedWidth,
            height: inputSize.height
        )
    }

    private static func leadingInputChipFrame(
        panelSize: CGSize,
        input: CGRect,
        chipSize: CGSize
    ) -> CGRect {
        let preferredX = input.minX - inputHorizontalGap - chipSize.width
        return CGRect(
            x: max(edgeInset, preferredX),
            y: input.midY - chipSize.height / 2,
            width: chipSize.width,
            height: chipSize.height
        )
    }

    private static func anchoredInputFrame(
        panelSize: CGSize,
        middleLeft: [CGRect],
        middleRight: [CGRect]
    ) -> CGRect {
        guard let leftFrame = middleLeft.last,
              let rightFrame = middleRight.first else {
            return centeredInputFrame(panelSize: panelSize, width: inputSize.width)
        }

        let minX = leftFrame.maxX + inputHorizontalGap
        let maxX = rightFrame.minX - inputHorizontalGap
        let width = maxX - minX
        guard width >= inputSize.width else {
            return centeredInputFrame(panelSize: panelSize, width: maxInputWidth)
        }

        return CGRect(
            x: minX,
            y: (panelSize.height - inputSize.height) / 2,
            width: width,
            height: inputSize.height
        )
    }

    private static func rowCapacity(
        availableWidth: CGFloat,
        chipSize: CGSize = flagChipSize,
        spacing: CGFloat = chipSpacing
    ) -> Int {
        guard availableWidth >= chipSize.width else { return 0 }
        return Int((availableWidth + spacing) / (chipSize.width + spacing))
    }

    private static func rowFrames(
        y: CGFloat,
        count: Int,
        minX: CGFloat,
        maxX: CGFloat,
        chipSize: CGSize = flagChipSize,
        spacing minimumSpacing: CGFloat = chipSpacing
    ) -> [CGRect] {
        guard count > 0 else { return [] }

        if count == 1 {
            return [
                CGRect(
                    x: (minX + maxX - chipSize.width) / 2,
                    y: y,
                    width: chipSize.width,
                    height: chipSize.height
                ),
            ]
        }

        let availableWidth = maxX - minX
        let spacing = max(
            minimumSpacing,
            (availableWidth - CGFloat(count) * chipSize.width) / CGFloat(count - 1)
        )

        return (0..<count).map { index in
            CGRect(
                x: minX + CGFloat(index) * (chipSize.width + spacing),
                y: y,
                width: chipSize.width,
                height: chipSize.height
            )
        }
    }

    private static func multiRowFrames(
        startY: CGFloat,
        count: Int,
        rowCapacity: Int,
        minX: CGFloat,
        maxX: CGFloat,
        rowStride: CGFloat,
        chipSize: CGSize = flagChipSize,
        spacing minimumSpacing: CGFloat = chipSpacing
    ) -> [CGRect] {
        guard count > 0, rowCapacity > 0 else { return [] }

        var rows: [CGRect] = []
        var remaining = count
        var rowIndex = 0
        while remaining > 0 {
            let rowCount = min(remaining, rowCapacity)
            rows += rowFrames(
                y: startY + CGFloat(rowIndex) * rowStride,
                count: rowCount,
                minX: minX,
                maxX: maxX,
                chipSize: chipSize,
                spacing: minimumSpacing
            )
            remaining -= rowCount
            rowIndex += 1
        }
        return rows
    }

    private static func balancedMultiRowFrames(
        startY: CGFloat,
        rowCounts: [Int],
        minX: CGFloat,
        maxX: CGFloat,
        rowStride: CGFloat,
        chipSize: CGSize,
        spacing: CGFloat,
        centersRows: Bool
    ) -> [CGRect] {
        rowCounts.enumerated().flatMap { rowIndex, rowCount in
            let y = startY + CGFloat(rowIndex) * rowStride
            if centersRows {
                return centeredRowFrames(
                    y: y,
                    count: rowCount,
                    minX: minX,
                    maxX: maxX,
                    chipSize: chipSize,
                    spacing: spacing
                )
            }

            return rowFrames(
                y: y,
                count: rowCount,
                minX: minX,
                maxX: maxX,
                chipSize: chipSize,
                spacing: spacing
            )
        }
    }

    private static func balancedRowCounts(total: Int, rowCount: Int) -> [Int] {
        guard total > 0, rowCount > 0 else { return [] }

        let resolvedRowCount = min(total, rowCount)
        let baseCount = total / resolvedRowCount
        let remainder = total % resolvedRowCount

        return (0..<resolvedRowCount).map { index in
            baseCount + (index < remainder ? 1 : 0)
        }
    }

    private static func rowStride(
        panelSize: CGSize,
        startY: CGFloat,
        chipHeight: CGFloat
    ) -> CGFloat {
        let minimumStride = chipHeight + rowVerticalSpacing
        let bottomY = panelSize.height - edgeInset - chipHeight
        let available = max(0, bottomY - startY)
        let evenStride = available / CGFloat(max(1, flagRowCount - 1))

        return max(minimumStride, evenStride)
    }

    private static func centeredRowFrames(
        y: CGFloat,
        count: Int,
        minX: CGFloat,
        maxX: CGFloat,
        chipSize: CGSize,
        spacing: CGFloat
    ) -> [CGRect] {
        guard count > 0 else { return [] }
        let rowWidth = widthForChips(count: count, chipSize: chipSize, spacing: spacing)
        let x = max(minX, (minX + maxX - rowWidth) / 2)

        return fixedSpacingRowFrames(
            y: y,
            count: count,
            x: min(x, maxX - rowWidth),
            chipSize: chipSize,
            spacing: spacing
        )
    }

    private static func trailingRowFrames(
        y: CGFloat,
        count: Int,
        maxX: CGFloat,
        minLimitX: CGFloat,
        chipSize: CGSize,
        spacing: CGFloat
    ) -> [CGRect] {
        guard count > 0 else { return [] }
        let rowWidth = widthForChips(count: count, chipSize: chipSize, spacing: spacing)
        return fixedSpacingRowFrames(
            y: y,
            count: count,
            x: max(minLimitX, maxX - rowWidth),
            chipSize: chipSize,
            spacing: spacing
        )
    }

    private static func leadingRowFrames(
        y: CGFloat,
        count: Int,
        minX: CGFloat,
        maxLimitX: CGFloat,
        chipSize: CGSize,
        spacing: CGFloat
    ) -> [CGRect] {
        guard count > 0 else { return [] }
        let rowWidth = widthForChips(count: count, chipSize: chipSize, spacing: spacing)
        return fixedSpacingRowFrames(
            y: y,
            count: count,
            x: min(minX, maxLimitX - rowWidth),
            chipSize: chipSize,
            spacing: spacing
        )
    }

    private static func fixedSpacingRowFrames(
        y: CGFloat,
        count: Int,
        x: CGFloat,
        chipSize: CGSize,
        spacing: CGFloat
    ) -> [CGRect] {
        (0..<count).map { index in
            CGRect(
                x: x + CGFloat(index) * (chipSize.width + spacing),
                y: y,
                width: chipSize.width,
                height: chipSize.height
            )
        }
    }

    private static func widthForChips(
        count: Int,
        chipSize: CGSize,
        spacing: CGFloat
    ) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * chipSize.width + CGFloat(count - 1) * spacing
    }

    private static func frames(
        from source: ArraySlice<CGRect>,
        y: CGFloat
    ) -> [CGRect] {
        source.map {
            CGRect(x: $0.minX, y: y, width: $0.width, height: $0.height)
        }
    }
}

enum IslandHoverPolicy {
    /// Allow hover expansion (showing trigger orbs and the lower drop-mode
    /// panel) unless the short pre-accept meeting *suggestion* window is
    /// up — that window owns the right band briefly and must not be
    /// visually overrun by hover-trigger orbs.
    ///
    /// Active *recording* does NOT block expansion. The user explicitly
    /// asked for drop, agent, and hover to keep working during a meeting;
    /// the meeting recording slot defends its visible area via
    /// `.contentShape(Capsule())` on the slot view, so hover events in
    /// the rest of the island route through normally without overlap.
    ///
    /// The lower drop-mode panel (Drop Mode / Integrations / Language)
    /// must remain reachable in all other states — including while the
    /// update-available pill is shown — so update visibility does NOT
    /// participate in this gate either. Trigger-orb visibility is
    /// instead suppressed at the row level when the update pill is
    /// active (see `IslandWrapRow.showsTriggerOrbs`).
    ///
    /// An active agent flow (wing / answer panel on screen) ALSO blocks
    /// expansion: the island has grown rightward + downward for the agent
    /// surfaces, and the lower Drop Mode drawer would collide with the
    /// agent answer column. The agent owns the enlarged window for its
    /// duration.
    static func allowsExpansion(
        meetingSuggestionActive: Bool,
        meetingRecordingActive: Bool = false,
        agentFlowActive: Bool = false
    ) -> Bool {
        _ = meetingRecordingActive
        return !meetingSuggestionActive && !agentFlowActive
    }
}

/// Resolves the Dynamic Island hover-drawer open state from the two raw
/// `.onHover` signals plus the prior open state. Pure so it is unit-tested
/// without spinning up the panel.
///
/// The hover drawer has two hover-tracking regions: the compact pill
/// (`pillHovering`) and the rendered drawer below it (`panelHovering`). The
/// drawer must stay open while the cursor travels pill → transparent gap →
/// drawer, so STAY-open honours either signal.
///
/// ROO-259 (bug B — premature open): the drawer used to open on
/// `pillHovering || panelHovering` unconditionally. While the drawer faded out
/// after a close, its panel hover tracking area was still mounted ~145pt below
/// the visible pill; moving the cursor back toward the island re-entered that
/// stale band and re-opened the drawer BEFORE the cursor reached the pill. The
/// OPEN edge therefore requires the visible pill: a panel-only hover can never
/// open a closed drawer, so the fading drawer's lingering region cannot
/// re-trigger it.
enum IslandHoverGate {
    /// Whether the mouse should hold the hover drawer expanded.
    ///
    /// - `wasExpanded == false` (closed): open ONLY when the cursor is over the
    ///   visible compact pill (`pillHovering`). A panel-only hover is ignored —
    ///   you cannot legitimately reach the drawer area without first crossing
    ///   the pill, so a panel-only signal on a closed drawer is the stale
    ///   fade-out band, not a real entry.
    /// - `wasExpanded == true` (open): stay open while EITHER region is hovered,
    ///   so the cursor can leave the pill and move down into the drawer/tiles
    ///   without collapsing.
    static func mouseExpanded(
        pillHovering: Bool,
        panelHovering: Bool,
        wasExpanded: Bool
    ) -> Bool {
        if wasExpanded {
            return pillHovering || panelHovering
        }
        return pillHovering
    }
}
