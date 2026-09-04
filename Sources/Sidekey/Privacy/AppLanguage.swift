/// Represents a transcription/agent response language.
///
/// `code` is the ISO 639-1 tag handed to the STT session (on-device or
/// BYOK) as the language hint for drops, meeting notes, and agent audio.
/// `displayName` is the native script label shown in the language UI.
/// `englishName` is the human-readable output-language label handed to the
/// LLM cleanup prompt so the model understands which language to respond in
/// regardless of its internal label lookup.
///
/// `all` is the menu set — the languages the streaming STT provider (Soniox
/// `stt-rt-v4`) recognises, so the onboarding picker and the Island drop picker
/// never offer a language that would silently fail (ROO-262). `everyKnownLanguage`
/// keeps the broader historical set purely so `find(code:)` still resolves a
/// value a user stored before the menu was trimmed — dropping a language from
/// the menu must not erase an existing selection.
/// Soniox realtime language source of truth:
/// https://soniox.com/docs/stt/concepts/supported-languages
struct AppLanguage: Equatable {
    let code: String
    let displayName: String
    let englishName: String

    /// ISO 639-1 codes Soniox `stt-rt-v4` recognises (the 60-language realtime
    /// table) intersected with the languages we model in `everyKnownLanguage`.
    /// Soniox also supports Albanian (`sq`) and Basque (`eu`), which we have
    /// never listed; ROO-262 only trims the menu, so they are not added.
    private static let sonioxSupportedCodes: Set<String> = [
        "ar", "be", "bg", "bn", "bs", "ca", "cs", "da", "de", "el",
        "en", "es", "et", "fa", "fi", "fr", "gu", "he", "hi", "hr",
        "hu", "id", "it", "ja", "kn", "ko", "lt", "lv", "mk", "ml",
        "mr", "ms", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sl",
        "sr", "sv", "ta", "te", "th", "tl", "tr", "uk", "ur", "vi",
        "zh", "af", "az", "cy", "gl", "kk", "pa", "sw",
    ]

    /// Languages advertised in every STT language menu — Soniox-supported only.
    static let all: [AppLanguage] = everyKnownLanguage.filter {
        sonioxSupportedCodes.contains($0.code)
    }

    // swiftlint:disable function_body_length
    /// Every language we have ever modelled (the broader ElevenLabs Scribe set).
    /// NOT shown in the picker — used only by `find(code:)` so a stored language
    /// that Soniox realtime cannot transcribe still resolves and the user keeps
    /// their prior selection instead of silently reverting to Auto.
    private static let everyKnownLanguage: [AppLanguage] = [
        AppLanguage(code: "ar", displayName: "\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064A}\u{0629}", englishName: "Arabic"),
        AppLanguage(code: "be", displayName: "\u{0411}\u{0435}\u{043B}\u{0430}\u{0440}\u{0443}\u{0441}\u{043A}\u{0430}\u{044F}", englishName: "Belarusian"),
        AppLanguage(code: "bg", displayName: "\u{0411}\u{044A}\u{043B}\u{0433}\u{0430}\u{0440}\u{0441}\u{043A}\u{0438}", englishName: "Bulgarian"),
        AppLanguage(code: "bn", displayName: "\u{09AC}\u{09BE}\u{0982}\u{09B2}\u{09BE}", englishName: "Bengali"),
        AppLanguage(code: "bs", displayName: "Bosanski", englishName: "Bosnian"),
        AppLanguage(code: "ca", displayName: "Catal\u{00E0}", englishName: "Catalan"),
        AppLanguage(code: "cs", displayName: "\u{010C}e\u{0161}tina", englishName: "Czech"),
        AppLanguage(code: "da", displayName: "Dansk", englishName: "Danish"),
        AppLanguage(code: "de", displayName: "Deutsch", englishName: "German"),
        AppLanguage(code: "el", displayName: "\u{0395}\u{03BB}\u{03BB}\u{03B7}\u{03BD}\u{03B9}\u{03BA}\u{03AC}", englishName: "Greek"),
        AppLanguage(code: "en", displayName: "English", englishName: "English"),
        AppLanguage(code: "es", displayName: "Espa\u{00F1}ol", englishName: "Spanish"),
        AppLanguage(code: "et", displayName: "Eesti", englishName: "Estonian"),
        AppLanguage(code: "fa", displayName: "\u{0641}\u{0627}\u{0631}\u{0633}\u{06CC}", englishName: "Persian"),
        AppLanguage(code: "fi", displayName: "Suomi", englishName: "Finnish"),
        AppLanguage(code: "fr", displayName: "Fran\u{00E7}ais", englishName: "French"),
        AppLanguage(code: "gu", displayName: "\u{0A97}\u{0AC1}\u{0A9C}\u{0AB0}\u{0ABE}\u{0AA4}\u{0AC0}", englishName: "Gujarati"),
        AppLanguage(code: "he", displayName: "\u{05E2}\u{05D1}\u{05E8}\u{05D9}\u{05EA}", englishName: "Hebrew"),
        AppLanguage(code: "hi", displayName: "\u{0939}\u{093F}\u{0928}\u{094D}\u{0926}\u{0940}", englishName: "Hindi"),
        AppLanguage(code: "hr", displayName: "Hrvatski", englishName: "Croatian"),
        AppLanguage(code: "hu", displayName: "Magyar", englishName: "Hungarian"),
        AppLanguage(code: "id", displayName: "Indonesia", englishName: "Indonesian"),
        AppLanguage(code: "it", displayName: "Italiano", englishName: "Italian"),
        AppLanguage(code: "ja", displayName: "\u{65E5}\u{672C}\u{8A9E}", englishName: "Japanese"),
        AppLanguage(code: "kn", displayName: "\u{0C95}\u{0CA8}\u{0CCD}\u{0CA8}\u{0CA1}", englishName: "Kannada"),
        AppLanguage(code: "ko", displayName: "\u{D55C}\u{AD6D}\u{C5B4}", englishName: "Korean"),
        AppLanguage(code: "lt", displayName: "Lietuvi\u{0173}", englishName: "Lithuanian"),
        AppLanguage(code: "lv", displayName: "Latvie\u{0161}u", englishName: "Latvian"),
        AppLanguage(code: "mk", displayName: "\u{041C}\u{0430}\u{043A}\u{0435}\u{0434}\u{043E}\u{043D}\u{0441}\u{043A}\u{0438}", englishName: "Macedonian"),
        AppLanguage(code: "ml", displayName: "\u{0D2E}\u{0D32}\u{0D2F}\u{0D3E}\u{0D33}\u{0D02}", englishName: "Malayalam"),
        AppLanguage(code: "mr", displayName: "\u{092E}\u{0930}\u{093E}\u{0920}\u{0940}", englishName: "Marathi"),
        AppLanguage(code: "ms", displayName: "Melayu", englishName: "Malay"),
        AppLanguage(code: "nl", displayName: "Nederlands", englishName: "Dutch"),
        AppLanguage(code: "no", displayName: "Norsk", englishName: "Norwegian"),
        AppLanguage(code: "pl", displayName: "Polski", englishName: "Polish"),
        AppLanguage(code: "pt", displayName: "Portugu\u{00EA}s", englishName: "Portuguese"),
        AppLanguage(code: "ro", displayName: "Rom\u{00E2}n\u{0103}", englishName: "Romanian"),
        AppLanguage(code: "ru", displayName: "\u{0420}\u{0443}\u{0441}\u{0441}\u{043A}\u{0438}\u{0439}", englishName: "Russian"),
        AppLanguage(code: "sk", displayName: "Sloven\u{010D}ina", englishName: "Slovak"),
        AppLanguage(code: "sl", displayName: "Slovens\u{010D}ina", englishName: "Slovenian"),
        AppLanguage(code: "sr", displayName: "\u{0421}\u{0440}\u{043F}\u{0441}\u{043A}\u{0438}", englishName: "Serbian"),
        AppLanguage(code: "sv", displayName: "Svenska", englishName: "Swedish"),
        AppLanguage(code: "ta", displayName: "\u{0BA4}\u{0BAE}\u{0BBF}\u{0BB4}\u{0BCD}", englishName: "Tamil"),
        AppLanguage(code: "te", displayName: "\u{0C24}\u{0C46}\u{0C32}\u{0C41}\u{0C17}\u{0C41}", englishName: "Telugu"),
        AppLanguage(code: "th", displayName: "\u{0E20}\u{0E32}\u{0E29}\u{0E32}\u{0E44}\u{0E17}\u{0E22}", englishName: "Thai"),
        AppLanguage(code: "tl", displayName: "Filipino", englishName: "Tagalog"),
        AppLanguage(code: "tr", displayName: "T\u{00FC}rk\u{00E7}e", englishName: "Turkish"),
        AppLanguage(code: "uk", displayName: "\u{0423}\u{043A}\u{0440}\u{0430}\u{0457}\u{043D}\u{0441}\u{044C}\u{043A}\u{0430}", englishName: "Ukrainian"),
        AppLanguage(code: "ur", displayName: "\u{0627}\u{0631}\u{062F}\u{0648}", englishName: "Urdu"),
        AppLanguage(code: "vi", displayName: "Ti\u{1EBF}ng Vi\u{1EC7}t", englishName: "Vietnamese"),
        AppLanguage(code: "zh", displayName: "\u{4E2D}\u{6587}", englishName: "Chinese"),
        // Expanded to the ElevenLabs Scribe set (~99 languages, the broadest
        // of the BYOK STT providers; each provider maps a language code to a
        // model that supports it). Autonyms in native script; the representative
        // country for the flag lives in the country maps in
        // `LanguageFlag` (onboarding) and `IslandDropModeControl`.
        AppLanguage(code: "af", displayName: "Afrikaans", englishName: "Afrikaans"),
        AppLanguage(code: "am", displayName: "አማርኛ", englishName: "Amharic"),
        AppLanguage(code: "as", displayName: "অসমীয়া", englishName: "Assamese"),
        AppLanguage(code: "ast", displayName: "Asturianu", englishName: "Asturian"),
        AppLanguage(code: "az", displayName: "Azərbaycan", englishName: "Azerbaijani"),
        AppLanguage(code: "ceb", displayName: "Cebuano", englishName: "Cebuano"),
        AppLanguage(code: "cy", displayName: "Cymraeg", englishName: "Welsh"),
        AppLanguage(code: "ff", displayName: "Fulfulde", englishName: "Fulah"),
        AppLanguage(code: "ga", displayName: "Gaeilge", englishName: "Irish"),
        AppLanguage(code: "gl", displayName: "Galego", englishName: "Galician"),
        AppLanguage(code: "ha", displayName: "Hausa", englishName: "Hausa"),
        AppLanguage(code: "ig", displayName: "Igbo", englishName: "Igbo"),
        AppLanguage(code: "is", displayName: "Íslenska", englishName: "Icelandic"),
        AppLanguage(code: "jv", displayName: "Basa Jawa", englishName: "Javanese"),
        AppLanguage(code: "ka", displayName: "ქართული", englishName: "Georgian"),
        AppLanguage(code: "kea", displayName: "Kabuverdianu", englishName: "Kabuverdianu"),
        AppLanguage(code: "kk", displayName: "Қазақ", englishName: "Kazakh"),
        AppLanguage(code: "km", displayName: "ខ្មែរ", englishName: "Khmer"),
        AppLanguage(code: "ku", displayName: "Kurdî", englishName: "Kurdish"),
        AppLanguage(code: "ky", displayName: "Кыргызча", englishName: "Kyrgyz"),
        AppLanguage(code: "lb", displayName: "Lëtzebuergesch", englishName: "Luxembourgish"),
        AppLanguage(code: "lg", displayName: "Luganda", englishName: "Ganda"),
        AppLanguage(code: "ln", displayName: "Lingála", englishName: "Lingala"),
        AppLanguage(code: "lo", displayName: "ລາວ", englishName: "Lao"),
        AppLanguage(code: "luo", displayName: "Dholuo", englishName: "Luo"),
        AppLanguage(code: "mi", displayName: "Māori", englishName: "Maori"),
        AppLanguage(code: "mn", displayName: "Монгол", englishName: "Mongolian"),
        AppLanguage(code: "mt", displayName: "Malti", englishName: "Maltese"),
        AppLanguage(code: "my", displayName: "မြန်မာ", englishName: "Burmese"),
        AppLanguage(code: "ne", displayName: "नेपाली", englishName: "Nepali"),
        AppLanguage(code: "nso", displayName: "Sesotho sa Leboa", englishName: "Northern Sotho"),
        AppLanguage(code: "ny", displayName: "Chichewa", englishName: "Chichewa"),
        AppLanguage(code: "oc", displayName: "Occitan", englishName: "Occitan"),
        AppLanguage(code: "or", displayName: "ଓଡ଼ିଆ", englishName: "Odia"),
        AppLanguage(code: "pa", displayName: "ਪੰਜਾਬੀ", englishName: "Punjabi"),
        AppLanguage(code: "ps", displayName: "پښتو", englishName: "Pashto"),
        AppLanguage(code: "sd", displayName: "سنڌي", englishName: "Sindhi"),
        AppLanguage(code: "sn", displayName: "ChiShona", englishName: "Shona"),
        AppLanguage(code: "so", displayName: "Soomaali", englishName: "Somali"),
        AppLanguage(code: "sw", displayName: "Kiswahili", englishName: "Swahili"),
        AppLanguage(code: "tg", displayName: "Тоҷикӣ", englishName: "Tajik"),
        AppLanguage(code: "umb", displayName: "Umbundu", englishName: "Umbundu"),
        AppLanguage(code: "uz", displayName: "Oʻzbekcha", englishName: "Uzbek"),
        AppLanguage(code: "wo", displayName: "Wolof", englishName: "Wolof"),
        AppLanguage(code: "xh", displayName: "isiXhosa", englishName: "Xhosa"),
        AppLanguage(code: "yo", displayName: "Yorùbá", englishName: "Yoruba"),
        AppLanguage(code: "yue", displayName: "粵語", englishName: "Cantonese"),
        AppLanguage(code: "zu", displayName: "isiZulu", englishName: "Zulu"),
    ]
    // swiftlint:enable function_body_length

    /// Curated subset shown as flag chips in the compact Island / Settings
    /// quick-picker. The full `all` stays reachable there via search; this keeps
    /// the chip grid to a sane ~4 rows. Filtered against `all` so it can never
    /// drift outside the Soniox-supported menu set.
    static let common: [AppLanguage] = {
        let codes: Set<String> = [
            "ar", "be", "bg", "bn", "bs", "ca", "cs", "da", "de", "el",
            "en", "es", "et", "fa", "fi", "fr", "gu", "he", "hi", "hr",
            "hu", "id", "it", "ja", "kn", "ko", "lt", "lv", "mk", "ml",
            "mr", "ms", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sl",
            "sr", "sv", "ta", "te", "th", "tl", "tr", "uk", "ur", "vi",
            "zh",
        ]
        return all.filter { codes.contains($0.code) }
    }()

    /// Returns the language matching the given ISO 639-1 code, or `nil` when the
    /// code is unknown. Searches the full historical set (`everyKnownLanguage`),
    /// not just the trimmed menu (`all`), so a language a user selected before
    /// ROO-262 narrowed the menu still resolves instead of vanishing.
    static func find(code: String) -> AppLanguage? {
        everyKnownLanguage.first { $0.code == code }
    }
}
