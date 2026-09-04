import Foundation

/// One rendered block of a meeting protocol. The native `MeetingNoteView`
/// renders these; `MeetingNoteMarkdownParser` produces them from the note /
/// transcript markdown. Inline emphasis (bold / italic / code / links) is
/// carried inside the `AttributedString` via markdown inline-presentation
/// intents, so the view applies only base font + colour and SwiftUI renders
/// the emphasis on top.
enum NoteBlock: Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case bullet(AttributedString)
    case numbered(index: Int, text: AttributedString)
    case checkbox(checked: Bool, text: AttributedString)
    case divider
}

/// Line-based markdown → `[NoteBlock]`. Deliberately small: it covers exactly
/// what the summary LLM emits for meeting summaries (headings, paragraphs,
/// bulleted / numbered lists, task checkboxes, dividers, inline emphasis) and
/// the diarized transcript shape (`**Speaker [mm:ss-mm:ss]:** text`). Pure
/// function, no I/O — tested in `MeetingNoteMarkdownParserTests`.
enum MeetingNoteMarkdownParser {

    static func parse(_ markdown: String) -> [NoteBlock] {
        var blocks: [NoteBlock] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline(paragraph.joined(separator: " "))))
            paragraph.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty { flush(); continue }
            if let heading = parseHeading(line) { flush(); blocks.append(heading); continue }
            if isDivider(line) { flush(); blocks.append(.divider); continue }
            if let checkbox = parseCheckbox(line) { flush(); blocks.append(checkbox); continue }
            if let bullet = parseBullet(line) { flush(); blocks.append(bullet); continue }
            if let numbered = parseNumbered(line) { flush(); blocks.append(numbered); continue }

            paragraph.append(line)
        }
        flush()
        return blocks
    }

    /// Parse inline-only markdown (bold / italic / code / links), preserving
    /// whitespace. Falls back to a plain attributed string if the line is not
    /// valid markdown so a stray `*` never blanks a paragraph.
    static func inline(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: string, options: options) {
            return parsed
        }
        return AttributedString(string)
    }

    // MARK: - Line parsers

    private static func parseHeading(_ line: String) -> NoteBlock? {
        for level in 1...6 {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                let text = String(line.dropFirst(prefix.count))
                // Cap at 3: the LLM rarely goes deeper and the view only
                // styles three heading tiers.
                return .heading(level: min(level, 3), text: inline(text))
            }
        }
        return nil
    }

    private static func parseCheckbox(_ line: String) -> NoteBlock? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let rest = line.dropFirst(marker.count)
            if rest.hasPrefix("[ ] ") {
                return .checkbox(checked: false, text: inline(String(rest.dropFirst(4))))
            }
            if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
                return .checkbox(checked: true, text: inline(String(rest.dropFirst(4))))
            }
        }
        return nil
    }

    private static func parseBullet(_ line: String) -> NoteBlock? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return .bullet(inline(String(line.dropFirst(marker.count))))
        }
        return nil
    }

    private static func parseNumbered(_ line: String) -> NoteBlock? {
        guard let dot = line.range(of: ". ") else { return nil }
        let numberPart = line[line.startIndex..<dot.lowerBound]
        guard !numberPart.isEmpty,
              numberPart.allSatisfy(\.isNumber),
              let index = Int(numberPart) else { return nil }
        return .numbered(index: index, text: inline(String(line[dot.upperBound...])))
    }

    private static func isDivider(_ line: String) -> Bool {
        line == "---" || line == "***" || line == "___"
    }
}
