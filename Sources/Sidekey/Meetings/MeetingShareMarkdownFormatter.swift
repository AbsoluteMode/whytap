import Foundation

/// Converts a meeting note into the portable Markdown we hand to the macOS
/// share sheet. Structured protocol notes are cleaned up for humans; legacy
/// freeform notes are shared as-is after trimming outer whitespace.
enum MeetingShareMarkdownFormatter {

    static func format(noteMarkdown: String) -> String {
        if let note = MeetingProtocolParser.parse(noteMarkdown) {
            return format(note)
        }
        return noteMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func format(_ note: MeetingProtocol) -> String {
        var blocks: [String] = []

        let name = note.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            blocks.append("# \(name)")
        }

        let description = note.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            blocks.append(description)
        }

        if !note.tasks.isEmpty {
            var lines = ["## \(note.header(at: 0, fallback: "Tasks"))"]
            for task in note.tasks {
                lines.append("- [ ] \(task.task)")
                appendMetadata("Assignee", task.assignee, to: &lines)
                appendMetadata("Deadline", task.deadline, to: &lines)
                appendMetadata("Notes", task.comment, to: &lines)
            }
            blocks.append(lines.joined(separator: "\n"))
        }

        if !note.decisions.isEmpty {
            blocks.append(section(
                title: note.header(at: 1, fallback: "Decisions"),
                items: note.decisions
            ))
        }

        if !note.other.isEmpty {
            blocks.append(section(
                title: note.header(at: 2, fallback: "Other"),
                items: note.other
            ))
        }

        return blocks.joined(separator: "\n\n")
    }

    private static func section(title: String, items: [MeetingProtocolItem]) -> String {
        var lines = ["## \(title)"]
        for item in items {
            lines.append("- \(item.text)")
            appendMetadata(nil, item.comment, to: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func appendMetadata(_ label: String?, _ value: String?, to lines: inout [String]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return
        }
        if let label {
            lines.append("  - \(label): \(value)")
        } else {
            lines.append("  - \(value)")
        }
    }
}
