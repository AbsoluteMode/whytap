import Foundation

/// Removes the space a speech model leaves before closing punctuation
/// ("истёкшими ?" -> "истёкшими?"), typically where it dropped a filler or
/// committed the mark as its own segment. Pure and side-effect free.
///
/// Only ordinary spaces and tabs are removed, only after a letter, digit,
/// closing quote/bracket or inline code ("`ls` ?" -> "`ls`?"), and only when
/// the punctuation run ends the word (followed by whitespace, a closing
/// quote/bracket or the end of the text). That keeps " .env", " ...and"
/// style tokens, " :)", list markers and the no-break spaces of French
/// typography untouched.
///
/// A mark is never attached to a link: "https://example.com/a?b=1 ?" keeps
/// its space, because "…b=1?" is a different address to every URL detector.
/// Matches inside `protecting` ranges (Markdown code) are left alone.
enum DropPunctuationSpacing {
    private static let regex = try? NSRegularExpression(
        pattern: "(?<=[\\p{L}\\p{N}`)\\]}»”\"'%])[ \\t]+(?![:;][()])([,.!?;:…]+)(?=[\\s)\\]}»”\"']|$)",
        options: [.anchorsMatchLines]
    )

    static func apply(_ text: String, protecting protected: [NSRange] = []) -> String {
        guard let regex else { return text }
        let ns = text as NSString
        var result = text
        // From the end, so earlier ranges stay valid.
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let range = match.range
            if protected.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
            if followsLink(ns, at: range.location) { continue }
            result = (result as NSString).replacingCharacters(in: range, with: ns.substring(with: match.range(at: 1)))
        }
        return result
    }

    /// True when the whitespace-delimited token ending at `location` is a link
    /// (bare or inside Markdown): attaching a mark could change its target.
    private static func followsLink(_ ns: NSString, at location: Int) -> Bool {
        var start = location
        while start > 0 {
            guard let scalar = UnicodeScalar(ns.character(at: start - 1)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            start -= 1
        }
        let token = ns.substring(with: NSRange(location: start, length: location - start)).lowercased()
        return token.contains("://") || token.hasPrefix("www.") || token.contains("(www.")
    }
}
