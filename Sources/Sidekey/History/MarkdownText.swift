import SwiftUI

/// Inline-only markdown renderer used by history surfaces (agent cards
/// + expanded view). Wraps `AttributedString(markdown:options:)` with
/// `interpretedSyntax: .inlineOnlyPreservingWhitespace` so:
/// - **bold**, *italic*, `code`, [links](...) render correctly
/// - Line breaks and paragraph breaks survive (the markdown parser
///   defaults to collapsing whitespace, which broke the visual list
///   layout in Maxim's agent responses).
/// - Block-level constructs (`#` headings, fenced code blocks) stay
///   as inline text — we deliberately keep the rendering simple. If
///   block rendering becomes a requirement we'll swap in MarkdownUI.
///
/// Falls back to plain `Text` if the parser rejects the input
/// (malformed markdown shouldn't crash a card render).
struct MarkdownText: View {
    let raw: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attributed)
        } else {
            Text(raw)
        }
    }
}
