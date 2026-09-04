import Foundation

/// Turns a multi-sentence agent message into a single short status phrase for
/// the live progress line: markdown markers stripped, cut at the first
/// sentence terminator (or first line), clipped with a typographic ellipsis.
enum StatusPhrase {
    static let defaultLimit = 80

    static func firstSentence(_ text: String, limit: Int = StatusPhrase.defaultLimit) -> String {
        let stripped = text
            .replacingOccurrences(of: "[*_`#>]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return "" }
        let firstLine = stripped
            .split(whereSeparator: \.isNewline)
            .first.map(String.init) ?? stripped
        var sentence = firstLine
        // Cut at the EARLIEST terminator followed by a space — ". " mid-path
        // (e.g. "file.py") does not match because the space is required.
        let cut = [". ", "! ", "? "]
            .compactMap { firstLine.range(of: $0)?.lowerBound }
            .min()
        if let cut {
            sentence = String(firstLine[...cut])  // keep the punctuation mark
        }
        return clip(sentence.trimmingCharacters(in: .whitespaces), limit: limit)
    }

    static func clip(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
