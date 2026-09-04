import AppKit
import SwiftUI

// MARK: - Copy provider (ROO-261)

/// Localized copy for the Try Drop screen. English is retained for:
/// - the brand word "Drop" (the headline tail; the product's name for
///   the feature, never translated/transliterated),
/// - the hotkey gesture vocabulary surfaced by the gesture switcher
///   (`voiceTitle` → "Hold"/"Tap"/"Toggle") and the Drop keycaps, which
///   mirror the live Settings hotkey UI and come from
///   `HotkeyConfiguration` as a single source of truth (invariant #6),
/// - product nouns in the subtitle (Whytap) and brand app names,
/// - the embedded language picker's `AppLanguage.displayName` values
///   (native-script language names) — only the chrome around the picker
///   (section label, "Auto-detect", search placeholder) localizes.
protocol OnboardingTryDropCopy {
    /// Upright serif lead-in ("Try "). The italic tail ("Drop.") stays
    /// the English brand word and is rendered separately with the plain
    /// (non-language) serifItalic so it never falls into Cyrillic serif.
    var headlineLead: String { get }
    /// `keyName` is the live Drop key name (`dropVoiceShortcut.title`,
    /// e.g. "Space" / "⌥ D") — running texts that mention the key take it
    /// as a parameter so a rebind updates them too.
    func subtitle(keyName: String) -> String

    // Three "how to try it" steps on the left pane.
    var step1Label: String { get }
    var step1Desc: String { get }
    /// Step 2 verb. `gestureWord` is the live hotkey verb
    /// ("hold"/"tap"/"toggle"), already lowercased; mapped to a display
    /// label per locale.
    func step2Label(gestureWord: String) -> String
    func step2Desc(keyName: String) -> String
    var step3Label: String { get }
    var step3Desc: String { get }

    // Input-language picker chrome (NOT the language names themselves).
    var inputLanguageLabel: String { get }
    var autoDetect: String { get }
    var searchLanguage: String { get }

    // Drop-hotkey rebind row chrome.
    var dropHotkeyLabel: String { get }
    var rebind: String { get }
    var pressKeys: String { get }
    var switchGestureHelp: String { get }
    var holdSpaceOnlyHelp: String { get }

    // Rebind footnote.
    var rebindNote: String { get }

    // Two-mode (Fast / Smart) picker.
    var twoVoiceModesLabel: String { get }
    var fast: String { get }
    var smart: String { get }
    var fastDesc: String { get }
    var smartDesc: String { get }

    // Right-pane Try field.
    var tryItLabel: String { get }
    func fieldPlaceholder(keyName: String) -> String

    var back: String { get }
    var ccontinue: String { get }
}

struct OnboardingTryDropCopyEN: OnboardingTryDropCopy {
    let headlineLead = "Try "
    func subtitle(keyName: String) -> String {
        "Click the field, hold \(keyName), say something, then let go. Whytap pastes the transcript right into the field."
    }

    let step1Label = "Focus"
    let step1Desc = "Click the field on the right."
    func step2Label(gestureWord: String) -> String { gestureWord.capitalized }
    func step2Desc(keyName: String) -> String {
        "Hold \(keyName) to start, release to stop."
    }
    let step3Label = "Read"
    let step3Desc = "Whytap types the transcript at your cursor."

    let inputLanguageLabel = "INPUT LANGUAGE"
    let autoDetect = "Auto-detect"
    let searchLanguage = "Search language"

    let dropHotkeyLabel = "DROP HOTKEY"
    let rebind = "rebind"
    let pressKeys = "press keys…"
    let switchGestureHelp = "Switch tap / hold"
    let holdSpaceOnlyHelp = "Hold Space is hold-only"

    let rebindNote = "If you want, you can rebind these in Settings later."

    let twoVoiceModesLabel = "TWO VOICE MODES"
    let fast = "Fast"
    let smart = "Smart"
    let fastDesc = "Fast — instant, word-for-word."
    let smartDesc = "Smart — punctuated, polished, and can translate."

    let tryItLabel = "TRY IT"
    func fieldPlaceholder(keyName: String) -> String {
        "Click here, then hold \(keyName) and speak."
    }

    let back = "Back"
    let ccontinue = "Continue"
}

struct OnboardingTryDropCopyRU: OnboardingTryDropCopy {
    let headlineLead = "Попробуйте "
    func subtitle(keyName: String) -> String {
        "Кликните в поле, зажмите \(keyName), скажите что-нибудь и отпустите. Whytap вставит расшифровку прямо в поле."
    }

    let step1Label = "Кликните"
    let step1Desc = "В поле справа."
    func step2Label(gestureWord: String) -> String {
        // Map the live English hotkey verb to its Russian display label.
        switch gestureWord.lowercased() {
        case "tap", "toggle": return "Нажмите"
        default: return "Зажмите"
        }
    }
    func step2Desc(keyName: String) -> String {
        "Зажмите \(keyName), чтобы начать, отпустите, чтобы остановить."
    }
    let step3Label = "Читайте"
    let step3Desc = "Whytap наберёт расшифровку у вашего курсора."

    let inputLanguageLabel = "ЯЗЫК ВВОДА"
    let autoDetect = "Автоопределение"
    let searchLanguage = "Поиск языка"

    let dropHotkeyLabel = "ГОРЯЧАЯ КЛАВИША DROP"
    let rebind = "переназначить"
    let pressKeys = "нажмите клавиши…"
    let switchGestureHelp = "Переключить нажатие / удержание"
    let holdSpaceOnlyHelp = "Space работает только на удержание"

    let rebindNote = "Переназначить их можно в настройках позже."

    let twoVoiceModesLabel = "ДВА ГОЛОСОВЫХ РЕЖИМА"
    let fast = "Быстрый"
    let smart = "Умный"
    let fastDesc = "Быстрый — мгновенно, слово в слово."
    let smartDesc = "Умный режим: безупречная пунктуация, максимальная точность."

    let tryItLabel = "ПОПРОБУЙТЕ"
    func fieldPlaceholder(keyName: String) -> String {
        "Кликните здесь, затем зажмите \(keyName) и говорите."
    }

    let back = "Назад"
    let ccontinue = "Продолжить"
}

private func onboardingTryDropCopy(for language: OnboardingUILanguage) -> OnboardingTryDropCopy {
    switch language {
    case .en: return OnboardingTryDropCopyEN()
    case .ru: return OnboardingTryDropCopyRU()
    }
}

/// Screen 06 of the onboarding flow — invite the user to actually
/// trigger Drop. The right pane is a single focused TextField the
/// dictated transcript can land in. If permissions are granted the
/// global hotkey works through the onboarding window — Sidekey pastes
/// into whichever app holds the cursor, which for this screen is the
/// TextField on the right.
struct OnboardingTryDropScreen: View {
    let onBack: () -> Void
    let onContinue: () -> Void

    @EnvironmentObject private var locale: OnboardingLocale
    private var copy: OnboardingTryDropCopy { onboardingTryDropCopy(for: locale.language) }

    /// The Drop shortcut keycaps, injected from the live hotkey config by
    /// the production flow (`OnboardingFlowView` passes
    /// `dropVoiceShortcut.contents`) so the chord chip never drifts from the
    /// binding. Defaults to the canonical hold-Space cap so the standalone
    /// onboarding preview executable — which has no `HotkeyPreferences` —
    /// still renders the right chord without depending on that type.
    let dropChord: [KeycapContent]
    /// Gesture verb for the Drop binding ("hold" / "tap"), injected from
    /// config by the production flow. Defaults to "hold" for the preview.
    let dropGestureWord: String

    /// Chord for the chip next to the try field. The injected `dropChord`
    /// is only the value at screen construction — a rebind done right here
    /// (keycapButton) must update this chip too, so production reads the
    /// live draft; the preview target has no `HotkeyPreferences` and keeps
    /// the injected caps.
    private var currentDropChord: [KeycapContent] {
        #if !ONBOARDING_PREVIEW
        hotkeyDraft.dropVoiceShortcut.contents
        #else
        dropChord
        #endif
    }

    /// Human-readable name of the current Drop key for running text
    /// (subtitle / step 02 / field placeholder) — same live source as
    /// `currentDropChord`, so a rebind updates the texts too. The preview
    /// target has no `HotkeyPreferences` and derives the name from the
    /// injected caps.
    private var currentDropKeyName: String {
        #if !ONBOARDING_PREVIEW
        hotkeyDraft.dropVoiceShortcut.title
        #else
        dropChord.map { cap in
            switch cap {
            case .text(let value): return value
            case .symbol(let name, let accessibilityLabel): return accessibilityLabel ?? name
            case .prefixedGlyph(let prefix, let glyph, _): return "\(prefix)\(glyph)"
            }
        }.joined(separator: " ")
        #endif
    }

    @State private var tryText: String = ""
    @State private var smartMode: Bool = false
    @State private var selectedLanguage: AppLanguage?
    @State private var languagePickerOpen = false
    @State private var languageQuery = ""
    #if !ONBOARDING_PREVIEW
    @State private var hotkeyDraft = HotkeyPreferences.shared.configuration
    @State private var hotkeyRecorder = HotkeyShortcutRecorder()
    @State private var hotkeyRecording = false
    @State private var hotkeyRecordingContents: [KeycapContent] = []
    @State private var hotkeyEventMonitor: Any?
    #endif
    @FocusState private var tryFocused: Bool

    init(
        onBack: @escaping () -> Void,
        onContinue: @escaping () -> Void,
        dropChord: [KeycapContent] = [.text("Space")],
        dropGestureWord: String = "hold"
    ) {
        self.onBack = onBack
        self.onContinue = onContinue
        self.dropChord = dropChord
        self.dropGestureWord = dropGestureWord
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
        .task {
            tryFocused = true
            #if !ONBOARDING_PREVIEW
            smartMode = (UserPreferencesCache.shared.currentMode == .smart)
            selectedLanguage = PrivacyPreferences.shared.selectedLanguage
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .sidekeyOnboardingDropTranscript)) { note in
            guard let transcript = note.userInfo?["text"] as? String else { return }
            receiveDropTranscript(transcript)
        }
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                headline
                Text(copy.subtitle(keyName: currentDropKeyName))
                    .font(OnboardingTheme.sans(14))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                TryStepRow(n: 1, label: copy.step1Label, desc: copy.step1Desc, language: locale.language)
                TryStepRow(n: 2, label: copy.step2Label(gestureWord: dropGestureWord), desc: copy.step2Desc(keyName: currentDropKeyName), language: locale.language)
                TryStepRow(n: 3, label: copy.step3Label, desc: copy.step3Desc, language: locale.language)
            }
            .padding(.top, 20)

            Spacer(minLength: 0)

            hotkeyRow
                .padding(.bottom, 10)

            RebindNote(text: copy.rebindNote)
                .padding(.bottom, 10)

            footer
        }
        .padding(EdgeInsets(top: 32, leading: 36, bottom: 18, trailing: 28))
    }

    private var headline: some View {
        (
            Text(copy.headlineLead).font(OnboardingTheme.serif(42, language: locale.language))
            + Text("Drop.").font(OnboardingTheme.serifItalic(42))
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
                .foregroundColor(OnboardingTheme.bg)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .fixedSize(horizontal: true, vertical: false)
                .background(Capsule(style: .continuous).fill(OnboardingTheme.ink))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Input language picker (compact)

    private var languageRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(copy.inputLanguageLabel)
                .font(OnboardingTheme.mono(9, weight: .semibold))
                .tracking(0.7)
                .foregroundColor(OnboardingTheme.faint)
            Button(action: { languagePickerOpen.toggle() }) {
                HStack(spacing: 8) {
                    Text(languageFlagEmoji).font(.system(size: 14))
                    Text(languageDisplayName)
                        .font(OnboardingTheme.sans(13, weight: .medium))
                        .foregroundColor(OnboardingTheme.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(OnboardingTheme.muted)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(OnboardingTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(OnboardingTheme.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $languagePickerOpen, arrowEdge: .bottom) {
                languageDropdown
            }
        }
    }

    private var languageFlagEmoji: String {
        guard let selectedLanguage else { return "🌐" }
        return LanguageFlag.emoji(forLanguageCode: selectedLanguage.code)
    }

    private var languageDisplayName: String {
        selectedLanguage?.displayName ?? copy.autoDetect
    }

    private var filteredLanguages: [AppLanguage] {
        let q = languageQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return AppLanguage.all }
        return AppLanguage.all.filter {
            $0.displayName.lowercased().contains(q)
                || $0.englishName.lowercased().contains(q)
                || $0.code.contains(q)
        }
    }

    private var languageDropdown: some View {
        VStack(spacing: 0) {
            TextField(copy.searchLanguage, text: $languageQuery)
                .textFieldStyle(.plain)
                .font(OnboardingTheme.sans(12.5))
                .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
            Rectangle().fill(OnboardingTheme.border).frame(height: 0.5)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    languageOption(nil, name: copy.autoDetect, flag: "🌐")
                    ForEach(filteredLanguages, id: \.code) { lang in
                        languageOption(lang, name: lang.displayName, flag: LanguageFlag.emoji(forLanguageCode: lang.code))
                    }
                }
            }
            .frame(maxHeight: 230)
        }
        .frame(width: 244)
        .background(OnboardingTheme.surface2)
    }

    private func languageOption(_ lang: AppLanguage?, name: String, flag: String) -> some View {
        let isSel = selectedLanguage?.code == lang?.code
        return Button(action: { selectLanguage(lang) }) {
            HStack(spacing: 9) {
                Text(flag).font(.system(size: 13))
                Text(name)
                    .font(OnboardingTheme.sans(12.5))
                    .foregroundColor(OnboardingTheme.ink)
                Spacer(minLength: 0)
                if isSel {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(OnboardingTheme.accent)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSel ? OnboardingTheme.accent.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func selectLanguage(_ lang: AppLanguage?) {
        selectedLanguage = lang
        languageQuery = ""
        languagePickerOpen = false
        #if !ONBOARDING_PREVIEW
        PrivacyPreferences.shared.selectedLanguage = lang
        #endif
    }

    // MARK: - Drop hotkey rebind (compact) — same recorder as Settings

    private var hotkeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(copy.dropHotkeyLabel)
                .font(OnboardingTheme.mono(9, weight: .semibold))
                .tracking(0.7)
                .foregroundColor(OnboardingTheme.faint)
            HStack(spacing: 7) {
                gestureSwitcher
                keycapButton
            }
        }
    }

    #if !ONBOARDING_PREVIEW
    private var gestureSwitcher: some View {
        let gesture = hotkeyDraft.normalizedDropGesture
        let switchable = hotkeyDraft.dropVoiceShortcut != .holdSpace
        return Button(action: {
            guard switchable else { return }
            hotkeyDraft.dropVoiceGesture = (gesture == .tap ? .hold : .tap)
            applyHotkeyDraft()
        }) {
            Text(gesture.voiceTitle)
                .font(OnboardingTheme.sans(11.5, weight: .semibold))
                .foregroundColor(switchable ? OnboardingTheme.ink : OnboardingTheme.muted)
                .frame(width: 62, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(OnboardingTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(OnboardingTheme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!switchable)
        .help(switchable ? copy.switchGestureHelp : copy.holdSpaceOnlyHelp)
    }

    private var keycapButton: some View {
        let contents = hotkeyRecording ? hotkeyRecordingContents : hotkeyDraft.dropVoiceShortcut.contents
        return Button(action: { startHotkeyRecording() }) {
            HStack(spacing: 7) {
                HotkeyHintView(contents: contents, compact: true)
                Text(hotkeyRecording ? copy.pressKeys : copy.rebind)
                    .font(OnboardingTheme.sans(11, weight: .medium))
                    .foregroundColor(hotkeyRecording ? OnboardingTheme.accent : OnboardingTheme.muted)
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hotkeyRecording ? OnboardingTheme.accent.opacity(0.12) : OnboardingTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(hotkeyRecording ? OnboardingTheme.accent.opacity(0.55) : OnboardingTheme.border, lineWidth: hotkeyRecording ? 0.75 : 0.5))
        }
        .buttonStyle(.plain)
    }

    private func startHotkeyRecording() {
        stopHotkeyRecording()
        hotkeyRecorder = HotkeyShortcutRecorder(shortcut: hotkeyDraft.dropVoiceShortcut)
        hotkeyRecordingContents = hotkeyDraft.dropVoiceShortcut.contents
        hotkeyRecording = true
        hotkeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            handleHotkeyEvent(event)
        }
    }

    private func stopHotkeyRecording() {
        if let monitor = hotkeyEventMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyEventMonitor = nil
        }
        hotkeyRecording = false
    }

    private func handleHotkeyEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 { // Escape
            stopHotkeyRecording()
            return nil
        }
        guard event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged else { return nil }
        if let shortcut = hotkeyRecorder.record(event) {
            hotkeyDraft.setDropShortcut(shortcut)
            applyHotkeyDraft()
            stopHotkeyRecording()
        }
        hotkeyRecordingContents = hotkeyRecorder.contents
        return nil
    }

    private func applyHotkeyDraft() {
        try? HotkeyPreferences.shared.apply(hotkeyDraft)
    }
    #else
    private var gestureSwitcher: some View {
        Text(dropGestureWord.capitalized)
            .font(OnboardingTheme.sans(11.5, weight: .semibold))
            .foregroundColor(OnboardingTheme.muted)
            .frame(width: 62, height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(OnboardingTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(OnboardingTheme.border, lineWidth: 0.5))
    }

    private var keycapButton: some View {
        HStack(spacing: 7) {
            HotkeyHintView(contents: dropChord, compact: true)
            Text(copy.rebind)
                .font(OnboardingTheme.sans(11, weight: .medium))
                .foregroundColor(OnboardingTheme.muted)
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(OnboardingTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(OnboardingTheme.border, lineWidth: 0.5))
    }
    #endif

    // MARK: - Right pane

    private var rightPane: some View {
        ZStack {
            TryDropBackdrop()
            VStack(spacing: 14) {
                DropModeToggle(
                    isSmart: smartMode,
                    onChange: setSmartMode,
                    sectionLabel: copy.twoVoiceModesLabel,
                    fastTitle: copy.fast,
                    smartTitle: copy.smart,
                    fastDesc: copy.fastDesc,
                    smartDesc: copy.smartDesc
                )
                languageRow
                TryTextField(
                    text: $tryText,
                    focused: $tryFocused,
                    placeholder: copy.fieldPlaceholder(keyName: currentDropKeyName),
                    chord: currentDropChord,
                    tryItLabel: copy.tryItLabel,
                    language: locale.language
                )
                .padding(.top, 6)
            }
            .frame(maxWidth: 420)
            .padding(EdgeInsets(top: 40, leading: 28, bottom: 40, trailing: 28))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Persists the chosen Drop mode. The real app writes through
    /// `UserPreferencesCache`; the preview target only flips the cosmetic
    /// segmented state.
    private func setSmartMode(_ on: Bool) {
        smartMode = on
        #if !ONBOARDING_PREVIEW
        UserPreferencesCache.shared.setMode(on ? .smart : .fast)
        #endif
    }

    private func receiveDropTranscript(_ transcript: String) {
        // Demo field shows the latest take fresh — each drop replaces the
        // previous result rather than appending it on a new line.
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        tryText = normalized
        tryFocused = true
    }
}

// MARK: - Rebind note

/// Tiny footnote shown on both Try screens after the Hotkeys
/// overview was retired — the user still needs to know the chord
/// is configurable, just at a quieter volume than a dedicated
/// screen would carry.
struct RebindNote: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape")
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(OnboardingTheme.sans(11.5))
        }
        .foregroundColor(OnboardingTheme.muted)
    }
}

// MARK: - Fast / Smart mode toggle

/// Two-mode picker shown above the Try field. Fast = instant,
/// word-for-word; Smart = LLM cleanup (on-device or your own provider —
/// punctuation, polish, and translation). Selection is persisted by the
/// parent through `UserPreferencesCache` (skipped in the preview target,
/// which has no preferences stack).
private struct DropModeToggle: View {
    let isSmart: Bool
    let onChange: (Bool) -> Void
    let sectionLabel: String
    let fastTitle: String
    let smartTitle: String
    let fastDesc: String
    let smartDesc: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(sectionLabel)
                .font(OnboardingTheme.mono(9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(OnboardingTheme.faint)
            HStack(spacing: 4) {
                segment(title: fastTitle, icon: "bolt.fill", on: !isSmart) { onChange(false) }
                segment(title: smartTitle, icon: "sparkles", on: isSmart) { onChange(true) }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(OnboardingTheme.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(OnboardingTheme.border, lineWidth: 0.5)
            )
            Text(isSmart ? smartDesc : fastDesc)
                .font(OnboardingTheme.sans(11.5))
                .foregroundColor(OnboardingTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func segment(title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(OnboardingTheme.sans(12.5, weight: on ? .semibold : .regular))
            }
            .foregroundColor(on ? OnboardingTheme.ink : OnboardingTheme.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(on ? OnboardingTheme.surface3 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Backdrop (blue accent wash for the Drop trial)

private struct TryDropBackdrop: View {
    var body: some View {
        OnboardingTheme.surface2
            .overlay(
                ZStack {
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(red: 0.55, green: 0.79, blue: 1.0).opacity(0.18), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.18, y: 0.18),
                        startRadius: 0,
                        endRadius: 560
                    )
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.03), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.85, y: 0.85),
                        startRadius: 0,
                        endRadius: 520
                    )
                }
            )
    }
}

// MARK: - Shared row helper (small step rows on the left pane)

struct TryStepRow: View {
    let n: Int
    let label: String
    let desc: String
    /// Active onboarding UI language so the italic-serif step label
    /// renders Cyrillic in the bundled Cyrillic serif. Defaults to `.en`
    /// for the preview target.
    var language: OnboardingUILanguage = .en

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(String(format: "%02d", n))
                .font(OnboardingTheme.mono(10.5))
                .tracking(0.6)
                .foregroundColor(OnboardingTheme.faint)
                .frame(width: 18, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(label).")
                    .font(OnboardingTheme.serifItalic(20, language: language))
                    .foregroundColor(OnboardingTheme.ink)
                Text(desc)
                    .font(OnboardingTheme.sans(12.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Try-it TextField

/// Multiline TextField the user can focus and type / dictate into.
/// The label above lists the chord that triggers the gesture; when
/// permissions are granted the real Drop hotkey pastes the
/// transcript right into the bound `text` because the field holds
/// the keyboard focus.
struct TryTextField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let placeholder: String
    let chord: [KeycapContent]
    let tryItLabel: String
    /// Active onboarding UI language, so the italic-serif placeholder
    /// renders Cyrillic in the bundled Cyrillic serif (Instrument Serif
    /// has no Cyrillic glyphs). Defaults to `.en` for the preview target.
    var language: OnboardingUILanguage = .en

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(tryItLabel)
                    .font(OnboardingTheme.mono(9.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(OnboardingTheme.faint)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    ForEach(Array(chord.enumerated()), id: \.offset) { _, cap in
                        TryChordCap(content: cap)
                    }
                }
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(OnboardingTheme.serifItalic(15, language: language))
                        .foregroundColor(OnboardingTheme.faint)
                        .padding(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
                        .allowsHitTesting(false)
                }
                TryPasteTextEditor(
                    text: $text,
                    isFocused: focused.wrappedValue
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OnboardingTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(focused.wrappedValue ? OnboardingTheme.accent.opacity(0.55) : OnboardingTheme.border, lineWidth: 0.75)
            )
            .animation(.easeInOut(duration: 0.18), value: focused.wrappedValue)
        }
        .frame(maxWidth: 420)
    }
}

/// Editable, paste-aware text view. Internal (not private) so the merged
/// `OnboardingDropScreen` can embed the same live field its Try field uses.
struct TryPasteTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay

        let textView = TryPasteTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text
        textView.shouldAutoFocusOnWindowAttach = isFocused
        Self.configure(textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TryPasteTextView else { return }
        context.coordinator.parent = self
        textView.delegate = context.coordinator
        textView.shouldAutoFocusOnWindowAttach = isFocused
        Self.configure(textView)

        if textView.string != text {
            textView.string = text
        }

        guard isFocused, textView.window?.firstResponder !== textView else { return }
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private static func configure(_ textView: TryPasteTextView) {
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesFindBar = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor(
            red: 0.925,
            green: 0.925,
            blue: 0.965,
            alpha: 1
        )
        textView.insertionPointColor = NSColor(
            red: 0.70,
            green: 0.48,
            blue: 1.0,
            alpha: 1
        )
        textView.font = NSFont(name: "InstrumentSerif-Regular", size: 15)
            ?? NSFont.systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 4, height: 5)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TryPasteTextEditor

        init(parent: TryPasteTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

@MainActor
private final class TryPasteTextView: NSTextView {
    var shouldAutoFocusOnWindowAttach = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard shouldAutoFocusOnWindowAttach, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
    }
}

extension Notification.Name {
    /// Posted by AppDelegate only while the user is on the onboarding
    /// Try Drop screen. The real product still uses global paste; this
    /// path writes the trial transcript directly into the onboarding
    /// field so the demo does not depend on macOS focus handoff.
    static let sidekeyOnboardingDropTranscript = Notification.Name("sidekey.onboarding.dropTranscript")
}

private struct TryChordCap: View {
    let content: KeycapContent

    var body: some View {
        Group {
            switch content {
            case .text(let value):
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
            case .symbol(let name, _):
                Image(systemName: name)
                    .font(.system(size: 11, weight: .semibold))
            case .prefixedGlyph(let prefix, let glyph, _):
                HStack(spacing: 3) {
                    Text(prefix)
                        .font(.system(size: 9, weight: .medium))
                        .opacity(0.85)
                    Text(glyph)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
        }
        .foregroundColor(OnboardingTheme.ink)
        .frame(minWidth: 30, minHeight: 26)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(OnboardingTheme.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(OnboardingTheme.borderStrong, lineWidth: 0.75)
        )
    }
}
