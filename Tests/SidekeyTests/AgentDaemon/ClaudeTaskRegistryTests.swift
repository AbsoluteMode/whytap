import XCTest
@testable import Sidekey

final class ClaudeTaskRegistryTests: XCTestCase {
    private func create(_ registry: ClaudeTaskRegistry, toolUseId: String, activeForm: String, resultTaskNumber: Int) {
        registry.observe(.toolUse(id: toolUseId, name: "TaskCreate",
                                  input: ClaudeToolInput(activeForm: activeForm)))
        registry.observe(.toolResult(toolUseId: toolUseId,
                                     text: "Task #\(resultTaskNumber) created successfully: x"))
    }

    func testProgressLabelTracksActiveFormAndCounts() {
        let r = ClaudeTaskRegistry()
        create(r, toolUseId: "t1", activeForm: "Создаю index.html", resultTaskNumber: 1)
        create(r, toolUseId: "t2", activeForm: "Создаю style.css", resultTaskNumber: 2)
        create(r, toolUseId: "t3", activeForm: "Проверяю файлы", resultTaskNumber: 3)

        XCTAssertEqual(r.progressLabel(forTaskId: "1"), "Planning (1/3)")

        r.observe(.toolUse(id: "u1", name: "TaskUpdate",
                           input: ClaudeToolInput(taskId: "1", status: "completed")))
        XCTAssertEqual(r.progressLabel(forTaskId: "2"), "Planning (2/3)")
    }

    func testUnknownTaskIdReturnsNil() {
        let r = ClaudeTaskRegistry()
        XCTAssertNil(r.progressLabel(forTaskId: "7"))
        XCTAssertNil(r.progressLabel(forTaskId: nil))
    }

    func testUnmatchedToolResultIsIgnored() {
        let r = ClaudeTaskRegistry()
        r.observe(.toolResult(toolUseId: "stranger", text: "Task #1 created"))
        XCTAssertNil(r.progressLabel(forTaskId: "1"))
    }

    func testTaskIDExtraction() {
        XCTAssertEqual(ClaudeTaskRegistry.taskID(fromCreateResult: "Task #12 created successfully: y"), "12")
        XCTAssertNil(ClaudeTaskRegistry.taskID(fromCreateResult: "created"))
        XCTAssertNil(ClaudeTaskRegistry.taskID(fromCreateResult: "Task #12 deleted"))
    }

    func testProgressPositionTracksCompletedCountNotQueriedOrdinal() {
        let r = ClaudeTaskRegistry()
        create(r, toolUseId: "t1", activeForm: "A", resultTaskNumber: 1)
        create(r, toolUseId: "t2", activeForm: "B", resultTaskNumber: 2)
        create(r, toolUseId: "t3", activeForm: "C", resultTaskNumber: 3)
        create(r, toolUseId: "t4", activeForm: "D", resultTaskNumber: 4)
        r.observe(.toolUse(id: "u", name: "TaskUpdate", input: ClaudeToolInput(taskId: "1", status: "completed")))
        // task 3 in_progress while only task 1 done -> position = completed+1 = 2, not task 3's ordinal
        XCTAssertEqual(r.progressLabel(forTaskId: "3"), "Planning (2/4)")
    }

    func testEmptyToolUseIdIsNeverRegistered() {
        let r = ClaudeTaskRegistry()
        r.observe(.toolUse(id: "", name: "TaskCreate",
                           input: ClaudeToolInput(activeForm: "Призрачный таск")))
        r.observe(.toolResult(toolUseId: "", text: "Task #1 created successfully: x"))
        XCTAssertNil(r.progressLabel(forTaskId: "1"))
    }
}
