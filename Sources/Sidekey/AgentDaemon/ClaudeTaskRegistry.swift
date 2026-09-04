import Foundation

/// Per-turn registry that reconstructs Claude's plan progress from the
/// TaskCreate / tool_result / TaskUpdate event flow, so the live line can show
/// "Создаю index.html (2/4)". TaskUpdate only carries a taskId — the
/// activeForm text lives in the TaskCreate input, and the numeric id only
/// appears in the TaskCreate *result* ("Task #N created"), hence the
/// two-step matching via tool_use_id.
///
/// Created fresh for every `run()`; mutated exclusively from the provider's
/// serial stdout bufferQueue, so no locking is needed (same contract as
/// `lastSessionID`).
final class ClaudeTaskRegistry {
    private var pendingCreates: [String: String] = [:]  // tool_use_id -> activeForm
    private var activeForms: [String: String] = [:]     // taskId -> activeForm
    private var createdCount = 0
    private var completedCount = 0

    func observe(_ event: ClaudeStreamEvent) {
        switch event {
        case .toolUse(let id, let name, let input) where name == "TaskCreate":
            // Parser falls back to id "" when a tool_use block lacks an id —
            // never register that key, two id-less creates would collide.
            if !id.isEmpty {
                pendingCreates[id] = input.activeForm ?? input.subject ?? ""
            }
            createdCount += 1
        case .toolResult(let toolUseId, let text):
            guard let form = pendingCreates.removeValue(forKey: toolUseId),
                  let taskId = Self.taskID(fromCreateResult: text) else { return }
            activeForms[taskId] = form
        case .toolUse(_, let name, let input) where name == "TaskUpdate" && input.status == "completed":
            completedCount += 1
        default:
            break
        }
    }

    /// App-owned label for TaskUpdate(in_progress). `activeForm` is authored by
    /// the model and may be in an unrelated language, so it is used only to
    /// match the task and is never rendered verbatim.
    func progressLabel(forTaskId taskId: String?) -> String? {
        guard let taskId, let form = activeForms[taskId], !form.isEmpty else { return nil }
        guard createdCount > 0 else { return "Planning" }
        let position = min(completedCount + 1, createdCount)
        return "Planning (\(position)/\(createdCount))"
    }

    /// "Task #12 created successfully: ..." -> "12"
    /// Requires the " created" suffix so non-creation results
    /// ("Task #12 deleted") never register an id.
    static func taskID(fromCreateResult text: String) -> String? {
        guard let match = text.range(of: #"Task #(\d+) created"#, options: .regularExpression) else { return nil }
        return String(text[match].dropFirst("Task #".count).dropLast(" created".count))
    }
}
