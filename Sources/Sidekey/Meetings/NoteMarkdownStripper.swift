import Foundation

/// Strips the inlined `## Transcript` section (and everything after it)
/// from a meeting's summary markdown before the Note tab renders it.
///
/// Older meeting summaries embed a transcript section at the bottom of
/// the LLM summary stored in `note.markdown`. The new
/// Transcribe tab already renders the same content from the separate
/// `transcriptJson` payload, so leaving the embedded section in place
/// would show the transcript twice. This helper only matches the
/// section as a real top-level heading (`## Transcript` on its own
/// line, possibly with trailing whitespace) — inline mentions of the
/// word stay intact.
///
/// Pure function — no I/O, no global state. Tested in
/// `NoteMarkdownStripperTests`.
enum NoteMarkdownStripper {

    static func stripTranscript(_ markdown: String) -> String {
        guard !markdown.isEmpty else { return "" }
        let lines = markdown.components(separatedBy: "\n")
        guard let cutIndex = lines.firstIndex(where: isTranscriptHeading) else {
            return markdown
        }
        // Drop the heading line itself + everything after it, then
        // trim trailing blank lines so the rendered Note doesn't end
        // with stray whitespace where the section used to start.
        let kept = lines.prefix(cutIndex)
        let trimmed = trimTrailingBlankLines(Array(kept))
        return trimmed.joined(separator: "\n")
    }

    // MARK: - Private

    /// `## Transcript` on its own line (optionally with trailing
    /// whitespace), nothing else. `### Transcript subsection` or inline
    /// usage stays unmatched.
    private static func isTranscriptHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "## Transcript"
    }

    private static func trimTrailingBlankLines(_ lines: [String]) -> [String] {
        var result = lines
        while let last = result.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeLast()
        }
        return result
    }
}
