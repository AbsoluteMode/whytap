import Foundation

/// Deterministically strips user-defined filler words from drop text
/// before paste, tidying adjacent punctuation/whitespace. Pure and
/// side-effect free. See docs/specs/filler.md.
enum DropFillerFilter {
    /// Noncharacter sentinel left where a sentence-initial filler was
    /// removed, so `restoreSentenceCase` knows to capitalize the next word.
    /// U+FFFF never appears in real transcripts.
    private static let capMarker: Character = "\u{FFFF}"

    static func apply(_ text: String, removing terms: [String]) -> String {
        let prepared = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !prepared.isEmpty, let regex = makeRegex(prepared) else { return text }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = text
        // Replace from the end so earlier ranges stay valid.
        for match in matches.reversed() {
            let initial = isSentenceInitial(ns, location: match.range.location)
            result = (result as NSString).replacingCharacters(
                in: match.range,
                with: initial ? String(capMarker) : ""
            )
        }
        result = normalize(result)
        return restoreSentenceCase(result)
    }

    private static func makeRegex(_ terms: [String]) -> NSRegularExpression? {
        // Longest-first so multi-word phrases win over their substrings.
        let alternation = terms
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try? NSRegularExpression(
            pattern: "\\b(?:\(alternation))\\b",
            options: [.caseInsensitive]
        )
    }

    /// True when only whitespace separates `location` from the start of
    /// text or a sentence terminator (`.`, `!`, `?`).
    private static func isSentenceInitial(_ ns: NSString, location: Int) -> Bool {
        var i = location - 1
        while i >= 0 {
            guard let scalar = UnicodeScalar(ns.character(at: i)) else { return false }
            let c = Character(scalar)
            if c == " " || c == "\t" || c == "\n" { i -= 1; continue }
            return c == "." || c == "!" || c == "?"
        }
        return true
    }

    private static func normalize(_ input: String) -> String {
        var s = input
        // Marker swallows punctuation/space immediately to its right.
        s = s.replacingOccurrences(of: "\(capMarker)[ \\t,;:]*", with: String(capMarker), options: .regularExpression)
        // Space(s) before punctuation -> drop the space.
        s = s.replacingOccurrences(of: "[ \\t]+([,.!?;:])", with: "$1", options: .regularExpression)
        // Doubled separator left by removal -> single.
        s = s.replacingOccurrences(of: "([,;:])\\1+", with: "$1", options: .regularExpression)
        // Runs of spaces/tabs -> one.
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        // Orphan leading punctuation/space.
        s = s.replacingOccurrences(of: "^[ \\t,;:]+", with: "", options: .regularExpression)
        // Orphan trailing comma/semicolon/colon left by a removal at the very
        // end. Keep . ! ? — those are legitimate sentence enders / ellipsis.
        s = s.replacingOccurrences(of: "[ \\t]*[,;:]+[ \\t]*$", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func restoreSentenceCase(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var capitalizeNext = false
        for char in input {
            if char == capMarker {
                capitalizeNext = true
                continue
            }
            if capitalizeNext, char.isLetter {
                result.append(contentsOf: char.uppercased())
                capitalizeNext = false
            } else {
                if char != " " && char != "\t" && char != "\n" {
                    capitalizeNext = false
                }
                result.append(char)
            }
        }
        return result
    }
}
