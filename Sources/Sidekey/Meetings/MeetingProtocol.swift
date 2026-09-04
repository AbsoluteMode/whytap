import Foundation

/// A single task extracted from a meeting — a **first-class object**, not just
/// a line of text. This is the foundation for the future "push this task to
/// Linear / Jira / Asana" action: the renderer draws each task as a discrete
/// unit carrying its fields + a stable `id`, so a tap-handler + per-task
/// integration state slot can be added later without reshaping the data.
///
/// `id` is content-derived for now (deterministic across launches for the same
/// note). A store-assigned id can replace it later
/// without touching the render/data layer.
struct MeetingTask: Identifiable, Equatable {
    let id: String
    let task: String
    let assignee: String?
    let deadline: String?
    let comment: String?
}

/// A decision or "other" item: free text + optional model comment. Shared shape
/// for the `accepted_decisions` and `another_question` sections.
struct MeetingProtocolItem: Identifiable, Equatable {
    let id: String
    let text: String
    let comment: String?
}

/// Structured meeting protocol parsed from the canonical note markdown the
/// summary LLM emits (see `MeetingProtocolParser`). Mirrors the schema:
/// `meeting_name`, `meeting_description`, `tasks`, `accepted_decisions`,
/// `another_question`.
struct MeetingProtocol: Equatable {
    let name: String
    let description: String
    let tasks: [MeetingTask]
    let decisions: [MeetingProtocolItem]
    let other: [MeetingProtocolItem]
    /// The H2 labels as the model emitted them, in order (tasks, decisions,
    /// other). Localized by the summary LLM per meeting language; the view shows
    /// them verbatim with an English fallback.
    let sectionHeaders: [String]

    func header(at index: Int, fallback: String) -> String {
        guard sectionHeaders.indices.contains(index) else { return fallback }
        let h = sectionHeaders[index].trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? fallback : h
    }
}

/// Parses the canonical protocol markdown into a `MeetingProtocol`.
///
/// Canonical format (LLM-generated; also human-editable). The leading HTML
/// comment marker reliably distinguishes a structured protocol from a legacy /
/// freely-edited note — without it, `parse` returns nil and the caller falls
/// back to the generic markdown renderer.
///
/// ```
/// <!-- protocol:v1 -->
/// # Meeting name
///
/// Short description of what the meeting was about.
///
/// ## Tasks
/// - Ship the onboarding PR — Maxim — Fri Jun 13
///   - needs design review first
/// - Draft the pricing doc — Anna
///
/// ## Decisions
/// - Go with Paddle for billing
///   - revisit fees in Q4
///
/// ## Other
/// - Open question: do we need SOC2 this year?
/// ```
///
/// Sections are keyed by **order** (1st H2 = tasks, 2nd = decisions, 3rd =
/// other) so localized headers (Задачи / Решения / Прочее) parse identically;
/// the summary prompt always emits the three sections in this order. Task fields are
/// split on " — " (task — assignee — deadline; trailing fields optional).
/// Indented sub-bullets attach as the preceding item's comment.
enum MeetingProtocolParser {

    static let marker = "<!-- protocol:v1 -->"
    static let fieldDelimiter = " — "

    static func parse(_ markdown: String) -> MeetingProtocol? {
        let rawLines = markdown.components(separatedBy: .newlines)
        guard rawLines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) else {
            return nil
        }

        var name = ""
        var descriptionLines: [String] = []
        // Section buckets in canonical order: 0 tasks, 1 decisions, 2 other.
        var sections: [[(text: String, comment: String?)]] = []
        var headers: [String] = []
        var currentSection = -1  // -1 = before first H2 (description region)

        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == marker || trimmed.isEmpty { continue }

            if trimmed.hasPrefix("# ") {
                name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.hasPrefix("## ") {
                headers.append(String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces))
                sections.append([])
                currentSection = sections.count - 1
                continue
            }

            // Indented sub-bullet -> comment on the preceding item.
            let isIndented = raw.first == " " || raw.first == "\t"
            if isIndented, let bulletText = bulletBody(trimmed),
               currentSection >= 0, !sections[currentSection].isEmpty {
                let last = sections[currentSection].count - 1
                let item = sections[currentSection][last]
                sections[currentSection][last] = (item.text, bulletText)
                continue
            }

            if let bulletText = bulletBody(trimmed) {
                if currentSection >= 0 {
                    sections[currentSection].append((bulletText, nil))
                }
                continue
            }

            // Plain prose before the first section = description.
            if currentSection == -1 {
                descriptionLines.append(trimmed)
            }
        }

        let tasks = (sections.indices.contains(0) ? sections[0] : []).enumerated().map { idx, entry in
            makeTask(index: idx, text: entry.text, comment: entry.comment)
        }
        let decisions = (sections.indices.contains(1) ? sections[1] : []).enumerated().map { idx, entry in
            MeetingProtocolItem(id: "decision-\(idx)-\(entry.text)", text: entry.text, comment: entry.comment)
        }
        let other = (sections.indices.contains(2) ? sections[2] : []).enumerated().map { idx, entry in
            MeetingProtocolItem(id: "other-\(idx)-\(entry.text)", text: entry.text, comment: entry.comment)
        }

        return MeetingProtocol(
            name: name,
            description: descriptionLines.joined(separator: " "),
            tasks: tasks,
            decisions: decisions,
            other: other,
            sectionHeaders: headers
        )
    }

    // MARK: - Helpers

    /// Strip a leading bullet marker (`- `, `* `, `+ `); nil if not a bullet.
    private static func bulletBody(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func makeTask(index: Int, text: String, comment: String?) -> MeetingTask {
        let parts = text.components(separatedBy: fieldDelimiter)
        let task = parts[0].trimmingCharacters(in: .whitespaces)
        let assignee = parts.count > 1 ? nonEmpty(parts[1]) : nil
        let deadline = parts.count > 2 ? nonEmpty(parts[2]) : nil
        return MeetingTask(
            id: "task-\(index)-\(task)",
            task: task,
            assignee: assignee,
            deadline: deadline,
            comment: comment
        )
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
