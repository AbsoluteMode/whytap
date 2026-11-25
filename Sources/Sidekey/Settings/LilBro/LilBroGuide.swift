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

    /// A keyword guide, not a parser of English: its contract is
    /// LilBroLocalGuideTests. A new phrasing answered wrongly goes into those
    /// tests as its own task.
    // WHY: .project-docs/decisions/2026-11-24-lil-bro.md ("Contract for the local guide")
    static func match(_ question: String) -> LilBroReply {
        let q = withoutInCase(question)
        // WHY: a macOS setting's name is context in a subordinate part of the
        // question ("Where is Drop after enabling Accessibility?", "dictate
        // with my microphone"): the feature opens. Otherwise it is the
        // question when the person asks to find or allow it ("Where do I
        // allow Microphone for Drop?", "For Drop, where can I find
        // Microphone?") or names it before any feature ("Screen Recording for
        // Screenshots"). Its own words never count as a feature's
        // ("monitoring" is not Monitor).
        // .project-docs/decisions/2026-11-24-lil-bro.md
        let named = settingNames.flatMap { name in offsets(of: name, in: q).map { (name, $0) } }
        if !named.isEmpty {
            let rest = named.reduce(q) { blank($0, pattern: NSRegularExpression.escapedPattern(for: $1.0)) }
            let found = featureMatch(in: rest)
            let direct = named.filter { !isContext(at: $0.1, in: q) }
            let permissions = LilBroDestination.tab(.permissions)
            let toPermissions = LilBroAnswer(paragraphs: [line(for: permissions)], destination: permissions)
            // Every setting is context ("after enabling …", "with my …"): the feature.
            guard !direct.isEmpty else {
                return found.map { .answer(answer(for: $0.feature)) } ?? .answer(toPermissions)
            }
            // Asked for directly ("allow …", "where can I find …"), or named
            // before any feature ("Screen Recording for Screenshots").
            if asksForSetting(q, at: direct) { return .answer(toPermissions) }
            if let found, found.offset < (direct.map(\.1).min() ?? 0) { return .answer(answer(for: found.feature)) }
            return .answer(toPermissions)
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

    /// Words that put a setting in a subordinate part of the question.
    private static let contextMarkers: Set<String> = [
        "after", "once", "when", "whenever", "while", "before", "with", "without", "using", "if", "until",
        "since",
    ]

    /// Where the main question starts after a leading part: "can I", "do I",
    /// "where", "how" ("With Drop can I enable Microphone?", "If I use Agent,
    /// where is Accessibility?").
    private static let mainClause = "\\b(?:(?:can|could|do|does|did|should|shall|will|would|may|must)\\s+(?:i|you|we|it|whytap)"
        + "|(?:where|how|what|which)\\s+(?:can|could|do|does|did|should|is|are|would|will)|is there|are there"
        + "|show me|tell me)\\b"

    /// A marker before the setting in the same part of the sentence, with
    /// the main question not yet started between them: "after enabling",
    /// "once I allow Whytap to use", "with my", "without having to enable".
    /// A main question after the marker ("With Drop can I enable
    /// Microphone?", "When using Screenshots can I allow …") ends that part,
    /// so the setting is the question again.
    private static func isContext(at offset: Int, in q: String) -> Bool {
        let before = Array(q.prefix(offset))
        let clauseStart = before.lastIndex { ",;:.?!".contains($0) }.map { $0 + 1 } ?? 0
        var markerEnd: Int?
        var index = clauseStart
        while index < before.count {
            guard before[index].isLetter || before[index] == "'" else { index += 1; continue }
            let start = index
            while index < before.count, before[index].isLetter || before[index] == "'" { index += 1 }
            if contextMarkers.contains(String(before[start..<index])) { markerEnd = index }
        }
        guard let markerEnd else { return false }
        let between = String(before[markerEnd...])
        return between.range(of: mainClause, options: .regularExpression) == nil
    }

    /// "allow / grant / enable / find / where is <setting>": the verb takes
    /// the setting itself. Between them only an article or possessive, who
    /// gets it ("Whytap", "it", "the app", "Whytap to use", "access to") or
    /// where it lives ("macOS", "System"): "open the macOS Accessibility
    /// settings", "grant Whytap Microphone access", "allow Whytap to use
    /// Screen Recording".
    private static func asksForSetting(_ q: String, at direct: [(String, Int)]) -> Bool {
        let verbs = "allow|grant|permit|enable|disable|revoke|find|open|where is|where's|where are"
        let article = "(?:(?:the|my|a|an|its|your)\\s+)?"
        let recipient = "(?:(?:whytap's|whytap|it|the app|this app)\\s+)?"
        let reach = "(?:(?:to use|access to|permission to use|permission for)\\s+)?"
        let place = "(?:(?:macos|mac|system|apple)\\s+)?"
        // The person does it: "turn …" and "give …" right after I / we / to /
        // you / please, or as an instruction at the start of the question or
        // of a part of it ("For Drop, turn on Microphone."), not "Does Drop
        // turn on Microphone automatically?".
        let person = "(?<actor>^\\s*|[,;:.?!]\\s*|\\b(?:i|we|to|you|me|please|let's|lets|us)\\s+)"
        // "I can't enable Microphone access" explains, it does not ask.
        let notNegated = "(?<!can't |cannot |don't |didn't |won't |couldn't |can not |do not )"
        return direct.contains { name, at in
            let setting = "(?<setting>" + NSRegularExpression.escapedPattern(for: name) + ")"
            let patterns = [
                notNegated + "\\b(?:\(verbs))\\s+" + article + recipient + reach + article + place + setting,
                // "turn on Microphone", "turn Microphone on", "switch the Accessibility permission off"
                person + "(?:turn|switch)\\s+(?:on|off)\\s+" + article + recipient + place + setting,
                person + "(?:turn|switch)\\s+" + article + recipient + place + setting
                    + "\\s+(?:(?:access|permission|setting)\\s+)?(?:on|off)\\b",
                // "give Drop access to the Microphone", "give Drop Microphone access"
                person + "(?:give|grant)\\s+(?:[\\w']+\\s+){1,2}(?:access|permission)\\s+(?:to|for)\\s+"
                    + article + place + setting,
                person + "(?:give|grant)\\s+(?:[\\w']+\\s+){0,2}" + setting + "\\s+(?:access|permission)\\b",
            ]
            // The verb must take this mention, not the same name elsewhere.
            return patterns.contains { pattern in
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
                return regex.matches(in: q, range: NSRange(q.startIndex..., in: q)).contains { match in
                    guard let range = Range(match.range(withName: "setting"), in: q),
                          q.distance(from: q.startIndex, to: range.lowerBound) == at
                    else { return false }
                    return !isSomeoneElsesAction(match, in: q)
                }
            }
        }
    }

    /// An instruction after a comma inside a question about what something
    /// else does is that thing's action: "Does Drop, by default, turn on
    /// Microphone?", "On this Mac, does Drop, by default, turn on …?",
    /// "Doesn't Drop …", "I wonder whether Drop can start, give another app
    /// access to …". Any part of the sentence before it may hold that
    /// question; its subject is the feature, it or Whytap. "Don't open Drop,
    /// turn on Microphone." (a verb after "don't"), a statement before the
    /// comma ("Drop is installed, turn on …") or an ended sentence ("Does
    /// Drop work? Turn on …") leaves an instruction.
    private static func isSomeoneElsesAction(_ match: NSTextCheckingResult, in q: String) -> Bool {
        let actorRange = match.range(withName: "actor")
        guard actorRange.location != NSNotFound, let actor = Range(actorRange, in: q) else { return false }
        let mark = q[actor].trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a comma-like mark inside a sentence; the start of the
        // question, ". ", "? " or "! " begins a new instruction.
        guard mark.count == 1, ",;:".contains(mark) else { return false }
        let before = q[..<actor.lowerBound]
        let sentence = before.lastIndex { ".?!".contains($0) }.map { before[before.index(after: $0)...] } ?? before
        let asks = "^(?:(?:and|or|but|so)\\s+)?(?:(?:how|why|when|where|what)\\s+)?(?:" + auxiliaries + ")\\s+"
        let wonders = "\\b(?:whether|if)\\s+"
        return sentence.split { ",;:".contains($0) }.contains { part in
            let part = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let opening = part.range(of: asks, options: .regularExpression),
               startsWithAppSubject(part[opening.upperBound...]) { return true }
            guard let opening = part.range(of: wonders, options: .regularExpression) else { return false }
            let rest = part[opening.upperBound...]
            return startsWithAppSubject(rest)
                && rest.range(of: "\\b(?:" + auxiliaries + ")\\b", options: .regularExpression) != nil
        }
    }

    /// The question is about the app: it opens with a feature (by name or
    /// alias, "Subtitles"), it, or Whytap, not a verb ("Don't open Drop").
    private static func startsWithAppSubject(_ text: Substring) -> Bool {
        // Its first three words, so a feature later in the part does not count.
        let text = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).prefix(3)
            .joined(separator: " ")
        if text.range(of: "^(?:it|this|that|whytap|the app|lil bro|he)\\b", options: .regularExpression) != nil {
            return true
        }
        guard let found = featureMatch(in: text) else { return false }
        let lead = text.prefix(found.offset)
        return lead.trimmingCharacters(in: .whitespaces).isEmpty || lead.range(of: "^(?:the|my)\\s+$", options: .regularExpression) != nil
    }

    private static let auxiliaries = "does|do|did|will|would|can|could|is|are|should|may|might|"
        + "doesn't|don't|didn't|won't|wouldn't|can't|couldn't|isn't|aren't|shouldn't"


    /// Every place a setting's name starts: the same setting can be context
    /// once and asked for later ("… with Microphone disabled. Where do I
    /// enable Microphone?").
    private static func offsets(of word: String, in q: String) -> [Int] {
        guard !word.isEmpty,
              let regex = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: word))
        else { return [] }
        return regex.matches(in: q, range: NSRange(q.startIndex..., in: q)).compactMap { match in
            Range(match.range, in: q).map { q.distance(from: q.startIndex, to: $0.lowerBound) }
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

    /// Lowercased, typographic apostrophes made plain ("Can’t" is "can't"),
    /// with the phrase "in case" blanked: "in case I need it" is
    /// not the Case feature, while "keys in Case" (capital C, its name) is.
    private static func withoutInCase(_ question: String) -> String {
        blank(question.replacingOccurrences(of: "\u{2019}", with: "'"), pattern: "\\b(?:[Jj]ust )?[Ii]n case\\b")
            .lowercased()
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
