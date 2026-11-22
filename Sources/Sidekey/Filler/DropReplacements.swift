import Foundation

/// One user rule: what the provider writes (`heard`) and what the user wants
/// pasted instead (`wanted`). Created only by the user's Y on a learning
/// suggestion. WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
struct DropReplacement: Equatable, Hashable, Codable {
    let heard: String
    let wanted: String
}

/// Local list of Drop replacements. A new key: `sidekey.replace.terms` is the
/// Filler list's legacy name. Each entry is "heard<US>wanted" in a string array,
/// so backup and settings sync carry it like the Vocab and Filler lists.
struct DropReplacementStore {
    static let key = "sidekey.drop.replacements.v1"
    static let maxCount = 200
    static let maxHeardLength = 50
    static let maxWantedLength = 100
    static let maxHeardWords = 5
    private static let separator = "\u{1F}"

    enum Rejection: Equatable { case empty, tooLong, duplicate, tooMany, identical }
    enum AddResult: Equatable { case added, rejected(Rejection) }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func replacements() -> [DropReplacement] {
        (defaults.stringArray(forKey: Self.key) ?? []).compactMap(Self.decode)
    }

    static func validate(_ rule: DropReplacement, against current: [DropReplacement]) -> AddResult {
        let heard = rule.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = rule.wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !wanted.isEmpty,
              !heard.contains(separator), !wanted.contains(separator),
              !heard.contains("\n"), !wanted.contains("\n") else { return .rejected(.empty) }
        guard heard.count <= maxHeardLength, wanted.count <= maxWantedLength,
              heard.split(whereSeparator: \.isWhitespace).count <= maxHeardWords else { return .rejected(.tooLong) }
        guard heard != wanted else { return .rejected(.identical) }
        guard !current.contains(where: { $0.heard.caseInsensitiveCompare(heard) == .orderedSame }) else {
            return .rejected(.duplicate)
        }
        guard current.count < maxCount else { return .rejected(.tooMany) }
        return .added
    }

    @discardableResult
    func add(_ rule: DropReplacement) -> AddResult {
        var current = replacements()
        let result = Self.validate(rule, against: current)
        guard result == .added else { return result }
        current.append(DropReplacement(
            heard: rule.heard.trimmingCharacters(in: .whitespacesAndNewlines),
            wanted: rule.wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        save(current)
        return .added
    }

    func remove(heard: String) {
        save(replacements().filter { $0.heard.caseInsensitiveCompare(heard) != .orderedSame })
    }

    private func save(_ rules: [DropReplacement]) {
        defaults.set(rules.map { $0.heard + Self.separator + $0.wanted }, forKey: Self.key)
    }

    private static func decode(_ stored: String) -> DropReplacement? {
        let parts = stored.components(separatedBy: separator)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return DropReplacement(heard: parts[0], wanted: parts[1])
    }
}

/// Applies replacements in one pass: a replaced text is never matched again
/// (no cascades), the longest `heard` wins, and word boundaries are lookarounds
/// on letters/digits/underscore, so "C++" or ".NET" match while "Сева" inside
/// "Севастополь" does not. Code, links and e-mail addresses stay literal.
/// WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
enum DropReplaceFilter {
    struct Result: Equatable {
        let text: String
        /// Rules that changed this take, for the reverse suggestion.
        let fired: [DropReplacement]
    }

    static func apply(_ text: String, rules: [DropReplacement]) -> Result {
        let prepared = rules.filter { !$0.heard.isEmpty }
        guard !prepared.isEmpty, !text.isEmpty else { return Result(text: text, fired: []) }
        let ordered = prepared.sorted { $0.heard.count > $1.heard.count }
        let alternation = ordered.map { NSRegularExpression.escapedPattern(for: $0.heard) }.joined(separator: "|")
        let word = "[\\p{L}\\p{N}_]"
        guard let regex = try? NSRegularExpression(
            pattern: "(?<!\(word))(?:\(alternation))(?!\(word))", options: [.caseInsensitive]
        ) else { return Result(text: text, fired: []) }
        let ns = text as NSString
        let protected = protectedRanges(in: text)
        var output = text
        var fired: [DropReplacement] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let found = ns.substring(with: match.range)
            guard let rule = ordered.first(where: { $0.heard.caseInsensitiveCompare(found) == .orderedSame }) else { continue }
            let initial = isSentenceInitial(ns, at: match.range.location)
            output = (output as NSString).replacingCharacters(
                in: match.range, with: initial ? capitalizedFirst(rule.wanted, like: found) : rule.wanted
            )
            if !fired.contains(rule) { fired.append(rule) }
        }
        return Result(text: output, fired: fired.reversed())
    }

    /// A sentence-initial match keeps its capital; elsewhere the rule's text
    /// is literal (names, "iOS", "cpp").
    private static func capitalizedFirst(_ wanted: String, like found: String) -> String {
        guard let first = found.first, first.isUppercase,
              let target = wanted.first, target.isLowercase else { return wanted }
        return target.uppercased() + wanted.dropFirst()
    }

    private static func isSentenceInitial(_ ns: NSString, at location: Int) -> Bool {
        var i = location - 1
        while i >= 0 {
            guard let scalar = UnicodeScalar(ns.character(at: i)) else { return false }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if scalar == "\n" { return true }
                i -= 1; continue
            }
            return ".!?".unicodeScalars.contains(scalar)
        }
        return true
    }

    static func protectedRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges = SmartMarkdownProtection.literalRanges(in: text)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            ranges += detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        }
        if let mail = try? NSRegularExpression(pattern: "[^\\s@]+@[^\\s@]+\\.[^\\s@]+") {
            ranges += mail.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        }
        return ranges
    }
}
