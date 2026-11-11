import Foundation

/// Removes the space a speech model leaves before closing punctuation
/// ("истёкшими ?" -> "истёкшими?"), typically where it dropped a filler or
/// committed the mark as its own segment. Pure and side-effect free.
///
/// Only ordinary spaces and tabs are removed, only after a letter, digit or
/// closing quote/bracket, and only when the punctuation run ends the word
/// (followed by whitespace, a closing quote/bracket or the end of the text).
/// That keeps " .env", " ...and" style tokens, " :)", list markers and the
/// no-break spaces of French typography untouched.
enum DropPunctuationSpacing {
    private static let regex = try? NSRegularExpression(
        pattern: "(?<=[\\p{L}\\p{N})\\]}»”\"'%])[ \\t]+(?![:;][()])([,.!?;:…]+)(?=[\\s)\\]}»”\"']|$)",
        options: [.anchorsMatchLines]
    )

    static func apply(_ text: String) -> String {
        guard let regex else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }
}
