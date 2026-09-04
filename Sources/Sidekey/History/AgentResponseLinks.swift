import Foundation

/// Pulls every http(s) URL out of an agent response's markdown body so
/// the history strip's Agent card can render link chips alongside the
/// chat title + response. Detects both bare URLs (`https://example.com`)
/// and markdown-style links (`[label](https://example.com)`). Falls back
/// to no chips if the body has no recognisable URLs.
enum AgentResponseLinks {
    /// Order: first-appearance, with later duplicates suppressed.
    /// `NSDataDetector` would have given us extra URL kinds (mailto, tel,
    /// etc.) but those aren't useful as link chips in this surface; the
    /// regex below is intentionally narrow.
    static func extract(from text: String) -> [URL] {
        guard !text.isEmpty else { return [] }

        // Strategy: walk the text once, recording URLs in order of
        // appearance. Two regexes — markdown bracket form and bare form —
        // are merged so we don't double-count an https URL that sits
        // inside a markdown link.
        var seen = Set<URL>()
        var ordered: [URL] = []

        for url in candidates(in: text) {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                continue
            }
            if seen.insert(url).inserted {
                ordered.append(url)
            }
        }
        return ordered
    }

    private static func candidates(in text: String) -> [URL] {
        let nsText = text as NSString
        var results: [(Int, URL)] = []  // (location, URL) for ordering

        // 1. Markdown links: [label](https://…). Capture the URL inside
        //    the parentheses. The label is irrelevant for chip surface.
        if let regex = try? NSRegularExpression(
            pattern: #"\[[^\]]*\]\((https?://[^)\s]+)\)"#,
            options: []
        ) {
            let range = NSRange(location: 0, length: nsText.length)
            regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard
                    let match = match,
                    match.numberOfRanges >= 2,
                    let url = url(from: match.range(at: 1), in: nsText)
                else { return }
                results.append((match.range.location, url))
            }
        }

        // 2. Bare URLs: https://example.com (no brackets). Stops at
        //    whitespace, closing parens (so markdown form's `)` isn't
        //    eaten when the bare match overlaps), or end-of-line. The
        //    trailing-punctuation stripper below handles ".", ",", etc.
        if let regex = try? NSRegularExpression(
            pattern: #"https?://[^\s)\]]+"#,
            options: []
        ) {
            let range = NSRange(location: 0, length: nsText.length)
            regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match = match,
                      let url = url(from: match.range, in: nsText)
                else { return }
                results.append((match.range.location, url))
            }
        }

        // Sort by appearance order, then dedupe by URL absoluteString
        // (caller's set check handles dedupe but stable sort keeps
        // "first appearance" semantics).
        results.sort { lhs, rhs in lhs.0 < rhs.0 }
        return results.map(\.1)
    }

    /// Pulls a URL out of an NSString sub-range, stripping common
    /// trailing punctuation that the regex would otherwise glue onto
    /// the path. ("https://example.com." → "https://example.com").
    private static func url(from range: NSRange, in text: NSString) -> URL? {
        var str = text.substring(with: range)
        while let last = str.last, ".,;:!?".contains(last) {
            str.removeLast()
        }
        guard let url = URL(string: str) else { return nil }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
}
