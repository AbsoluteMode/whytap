import Foundation

/// Where Lil Bro takes the person: a feature's screen or row, a sidebar tab,
/// or the API keys.
enum LilBroDestination: Equatable {
    case feature(AppFeature)
    case tab(SettingsWindowTab)
    case apiKeys

    var title: String {
        switch self {
        case .feature(let feature): return FeatureCatalog.info(for: feature).name
        case .tab(let tab): return tab.resolved.title
        case .apiKeys: return "API keys"
        }
    }
}

/// An answer: a few sentences, optional points, the place he opens, and
/// follow-up questions.
struct LilBroAnswer: Equatable {
    var paragraphs: [String]
    var bullets: [String] = []
    var destination: LilBroDestination?
    var followUps: [String] = []
}

/// What came back for one question.
enum LilBroReply: Equatable {
    case answer(LilBroAnswer)
    /// Nothing matched; he offers questions he can answer.
    case unknown(suggestions: [String])
    /// whytap.ai could not be reached: no internet or it did not answer in time.
    case offline
    /// whytap.ai answered with an error of its own; trying again later may work.
    case unavailable
    /// Today's questions are used up, for this Mac or for everyone.
    case limit
}

/// One question with what he knows around it: the screen the person is on
/// (`tab` or `tab/feature` raw ids) and up to three earlier exchanges.
struct LilBroQuestion: Equatable {
    struct Exchange: Equatable {
        let question: String
        let answer: String
    }

    var text: String
    var screen: String = ""
    var history: [Exchange] = []
}

/// Who answers. Without answers from whytap.ai, the local guide finds
/// settings by name and says what each feature does from the catalog.
@MainActor
protocol LilBroBrain {
    func reply(to question: LilBroQuestion) async -> LilBroReply
}

/// Answers without the network, from the feature catalog and the tab names.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md
struct LilBroLocalGuide: LilBroBrain {
    static let starters = ["Set up dictation", "Turn on meeting notes", "What can the Agent do?"]

    /// Words people use for a feature besides its name.
    private static let aliases: [AppFeature: [String]] = [
        .drop: ["dictat", "voice", "speak", "speech", "transcri", "type with"],
        .agent: ["agent", "assistant", "opencode", "quick task"],
        .meetings: ["meeting", "notes", "call", "zoom"],
        .googleSearch: ["google", "search"],
        .translateSubtitles: ["translat", "subtitle", "caption"],
        .screenshots: ["screenshot", "screen shot", "capture", "blur"],
        .hover: ["hover", "island tool", "toolbox"],
        .notify: ["notif", "notify", "alert"],
        .monitor: ["monitor", "dashboard"],
    ]

    /// macOS settings people name exactly. They mean Permissions even when a
    /// word in them is also a feature's ("Input Monitoring" is not Monitor).
    private static let settingNames = [
        "input monitoring", "accessibility", "keyboard control", "screen recording",
        "microphone", "system audio", "post event",
    ]

    private static let tabWords: [(String, LilBroDestination)] = [
        // Before "key": a hotkey is not an API key.
        ("hotkey", .tab(.hotkeys)), ("shortcut", .tab(.hotkeys)),
        ("api key", .apiKeys), ("key", .apiKeys), ("model", .tab(.apiAndModels)),
        ("permission", .tab(.permissions)), ("allow", .tab(.permissions)), ("access", .tab(.permissions)),
        ("backup", .tab(.backup)), ("integration", .tab(.integrations)),
    ]

    func reply(to question: LilBroQuestion) async -> LilBroReply {
        Self.match(question.text)
    }

    /// Pages to open when whytap.ai cannot answer: the place the words name,
    /// or Features and API keys.
    static func closestPlaces(for question: String) -> [LilBroDestination] {
        if case .answer(let answer) = match(question), let destination = answer.destination {
            return [destination]
        }
        return [.tab(.features), .apiKeys]
    }

    static func match(_ question: String) -> LilBroReply {
        let q = withoutInCase(question)
        // WHY: a macOS setting's name is the question when the person asks to
        // find or allow it ("Where do I allow Microphone for Drop?") or names
        // it before any feature ("screen recording for screenshots"); it is
        // context when a feature comes first ("dictate with my microphone",
        // "use Drop after enabling Accessibility"). Its own words never count
        // as a feature's ("monitoring" is not Monitor).
        // .project-docs/decisions/2026-11-24-lil-bro.md
        let named = settingNames.compactMap { name in offset(of: name, in: q).map { (name, $0) } }
        if !named.isEmpty {
            let rest = named.reduce(q) { blank($0, pattern: NSRegularExpression.escapedPattern(for: $1.0)) }
            let settingAt = named.map(\.1).min() ?? 0
            if !asksForSetting(q, named: named.map(\.0)),
               let found = featureMatch(in: rest), found.offset < settingAt {
                return .answer(answer(for: found.feature))
            }
            let destination = LilBroDestination.tab(.permissions)
            return .answer(LilBroAnswer(paragraphs: [line(for: destination)], destination: destination))
        }
        // The feature words win over generic ones ("dictation shortcut" is Drop).
        if let found = featureMatch(in: q) {
            return .answer(answer(for: found.feature))
        }
        if let (_, destination) = tabWords.first(where: { q.contains($0.0) }) {
            return .answer(LilBroAnswer(paragraphs: [line(for: destination)], destination: destination))
        }
        return .unknown(suggestions: starters)
    }

    /// "allow / grant / enable / find / where is … <setting>", within a few
    /// words, and not "after enabling …".
    private static func asksForSetting(_ q: String, named: [String]) -> Bool {
        let verbs = "allow|grant|give|permit|enable|turn on|switch on|find|open|where is|where's|where are"
        return named.contains { name in
            let pattern = "(?<!after |once |when |before )\\b(\(verbs))\\b(?:\\s+\\S+){0,3}?\\s+"
                + NSRegularExpression.escapedPattern(for: name)
            return q.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Where a word starts in the question, at a word start ("showcase" is
    /// not Case; "dictat" still finds "dictation").
    private static func offset(of word: String, in q: String) -> Int? {
        guard !word.isEmpty,
              let range = q.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word), options: .regularExpression)
        else { return nil }
        return q.distance(from: q.startIndex, to: range.lowerBound)
    }

    /// Replaces matches with spaces of the same length, so offsets still line up.
    private static func blank(_ q: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return q }
        let text = NSMutableString(string: q)
        for match in regex.matches(in: q, range: NSRange(location: 0, length: text.length)).reversed() {
            text.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        return text as String
    }

    static func firstFeature(in question: String) -> AppFeature? {
        featureMatch(in: withoutInCase(question))?.feature
    }

    /// Lowercased, with the phrase "in case" blanked: "in case I need it" is
    /// not the Case feature, while "keys in Case" (capital C, its name) is.
    private static func withoutInCase(_ question: String) -> String {
        blank(question, pattern: "\\b(?:[Jj]ust )?[Ii]n case\\b").lowercased()
    }

    /// The feature a question names, and where: a feature's exact name first
    /// (the longest, so "Google search" beats "search"), then the most
    /// specific alias, so "Google voice search" is Google search, not Drop's
    /// "voice".
    // WHY: .project-docs/decisions/2026-11-24-lil-bro.md
    static func featureMatch(in q: String) -> (feature: AppFeature, offset: Int)? {
        func best(_ words: (AppFeature) -> [String]) -> (feature: AppFeature, offset: Int)? {
            var found: (feature: AppFeature, offset: Int, length: Int)?
            for feature in AppFeature.allCases {
                for word in words(feature) {
                    if let at = offset(of: word, in: q), word.count > (found?.length ?? 0) {
                        found = (feature, at, word.count)
                    }
                }
            }
            return found.map { ($0.feature, $0.offset) }
        }
        // Not `kind`: several tools share "Island tools".
        return best { [FeatureCatalog.info(for: $0).name.lowercased()] }
            ?? best { aliases[$0] ?? [] }
    }

    static func answer(for feature: AppFeature) -> LilBroAnswer {
        let info = FeatureCatalog.info(for: feature)
        let lead = info.about.isEmpty ? "\(info.name): \(info.line)" : info.about
        let examples = Array(info.examples.prefix(3))
        // The other starters, not the one that leads here.
        let followUps = starters.filter { firstFeature(in: $0) != feature }
        return LilBroAnswer(paragraphs: [lead], bullets: examples, destination: .feature(feature),
                            followUps: Array(followUps.prefix(2)))
    }

    private static func line(for destination: LilBroDestination) -> String {
        switch destination {
        case .apiKeys: return "Your provider keys live in API keys. They stay in this Mac's Keychain."
        case .tab(.apiAndModels): return "Each feature's model is chosen in \(destination.title)."
        case .tab(.permissions): return "Everything macOS lets Whytap do is listed in Permissions."
        case .tab(.hotkeys): return "Every shortcut is in Hotkeys; click one to record a new key."
        case .tab(.backup): return "Backup saves your settings to a file and brings them back."
        case .tab(.integrations): return "Integrations connect Whytap to your calendar and coding tools."
        case .tab, .feature: return "Here it is."
        }
    }
}
