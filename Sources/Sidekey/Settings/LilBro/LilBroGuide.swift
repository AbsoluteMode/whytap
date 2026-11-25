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
    case offline
    case limit
}

/// Who answers. Without answers from whytap.ai, the local guide finds
/// settings by name and says what each feature does from the catalog.
@MainActor
protocol LilBroBrain {
    func reply(to question: String) async -> LilBroReply
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

    func reply(to question: String) async -> LilBroReply {
        Self.match(question)
    }

    static func match(_ question: String) -> LilBroReply {
        let q = question.lowercased()
        // A macOS setting's name is the question only when no feature is
        // asked about besides it: "Where is Input Monitoring?" is Permissions,
        // "How do I dictate with my microphone?" is Drop. Its own words never
        // count as a feature's ("monitoring" is not Monitor).
        let named = settingNames.filter { q.contains($0) }
        let rest = named.reduce(q) { $0.replacingOccurrences(of: $1, with: " ") }
        // The feature words win over generic ones ("dictation shortcut" is Drop).
        if let feature = firstFeature(in: rest) {
            return .answer(answer(for: feature))
        }
        if !named.isEmpty {
            let destination = LilBroDestination.tab(.permissions)
            return .answer(LilBroAnswer(paragraphs: [line(for: destination)], destination: destination))
        }
        if let (_, destination) = tabWords.first(where: { q.contains($0.0) }) {
            return .answer(LilBroAnswer(paragraphs: [line(for: destination)], destination: destination))
        }
        return .unknown(suggestions: starters)
    }

    /// The feature a question names: a feature's exact name first (the
    /// longest, so "Google search" beats "search"), then the most specific
    /// alias, so "Google voice search" is Google search, not Drop's "voice".
    // WHY: .project-docs/decisions/2026-11-24-lil-bro.md
    static func firstFeature(in question: String) -> AppFeature? {
        let q = question.lowercased()
        func best(_ words: (AppFeature) -> [String]) -> AppFeature? {
            var found: (feature: AppFeature, length: Int)?
            for feature in AppFeature.allCases {
                for word in words(feature) where !word.isEmpty && q.contains(word) {
                    if word.count > (found?.length ?? 0) { found = (feature, word.count) }
                }
            }
            return found?.feature
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
