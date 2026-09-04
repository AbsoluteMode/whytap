import XCTest
@testable import Sidekey

final class StreamJSONParserTests: XCTestCase {

    // MARK: - Existing tests (adapted: single event -> array, nil -> [])

    func testParsesTextDelta() {
        let line = #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hi"}}}"#
        XCTAssertEqual(StreamJSONParser.parse(line: line), [.textDelta("Hi")])
    }

    func testParsesInitSessionID() {
        let line = #"{"type":"system","subtype":"init","session_id":"abc123"}"#
        XCTAssertEqual(StreamJSONParser.parse(line: line), [.initSession(sessionID: "abc123")])
    }

    func testParsesApiRetryError() {
        let line = #"{"type":"system","subtype":"api_retry","error":"authentication_failed"}"#
        XCTAssertEqual(StreamJSONParser.parse(line: line), [.errorCategory("authentication_failed")])
    }

    func testParsesResult() {
        let line = #"{"type":"result","subtype":"success","session_id":"abc","is_error":false,"total_cost_usd":0.01}"#
        let events = StreamJSONParser.parse(line: line)
        guard case .result(let id, let isError, let cost, _)? = events.first else {
            return XCTFail("expected result event")
        }
        XCTAssertEqual(id, "abc")
        XCTAssertFalse(isError)
        XCTAssertEqual(cost, 0.01)
    }

    func testParsesResultFinalAnswerText() {
        let line = #"{"type":"result","subtype":"success","session_id":"abc","is_error":false,"result":"The final answer."}"#
        let events = StreamJSONParser.parse(line: line)
        guard case .result(_, _, _, let text)? = events.first else {
            return XCTFail("expected result event")
        }
        XCTAssertEqual(text, "The final answer.")
    }

    func testIgnoresUnknownAndBlank() {
        XCTAssertEqual(StreamJSONParser.parse(line: ""), [])
        XCTAssertEqual(StreamJSONParser.parse(line: #"{"type":"whatever"}"#), [])
    }

    // MARK: - New tests

    func testParsesToolUseWithBashDescription() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"python3 -m pytest","description":"Run the test suite with pytest"}}]}}"#
        XCTAssertEqual(
            StreamJSONParser.parse(line: line),
            [.toolUse(id: "toolu_01", name: "Bash",
                      input: ClaudeToolInput(
                        description: "Run the test suite with pytest",
                        command: "python3 -m pytest"
                      ))]
        )
    }

    func testParsesToolUseWithFilePathAndTaskFields() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_02","name":"TaskCreate","input":{"subject":"Создать index.html","description":"HTML-страница","activeForm":"Создаю index.html"}}]}}"#
        XCTAssertEqual(
            StreamJSONParser.parse(line: line),
            [.toolUse(id: "toolu_02", name: "TaskCreate",
                      input: ClaudeToolInput(description: "HTML-страница", subject: "Создать index.html", activeForm: "Создаю index.html"))]
        )
    }

    func testParsesAssistantTextBlock() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Сначала разберусь со структурой проекта и запущу тесты."}]}}"#
        XCTAssertEqual(
            StreamJSONParser.parse(line: line),
            [.assistantText("Сначала разберусь со структурой проекта и запущу тесты.")]
        )
    }

    func testSkipsEmptyAndThinkingBlocksAndEmitsMultipleBlocks() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"","signature":"x"},{"type":"text","text":"  "},{"type":"text","text":"Фикс внесён."},{"type":"tool_use","id":"toolu_03","name":"Read","input":{"file_path":"/tmp/a/calculator.py"}}]}}"#
        XCTAssertEqual(
            StreamJSONParser.parse(line: line),
            [.assistantText("Фикс внесён."),
             .toolUse(id: "toolu_03", name: "Read", input: ClaudeToolInput(filePath: "/tmp/a/calculator.py"))]
        )
    }

    func testParsesToolResultStringContent() {
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_02","content":"Task #4 created successfully: Создать index.html"}]}}"#
        XCTAssertEqual(
            StreamJSONParser.parse(line: line),
            [.toolResult(toolUseId: "toolu_02", text: "Task #4 created successfully: Создать index.html")]
        )
    }

    func testParsesToolResultBlockArrayContent() {
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_05","content":[{"type":"text","text":"total 24"}]}]}}"#
        XCTAssertEqual(
            StreamJSONParser.parse(line: line),
            [.toolResult(toolUseId: "toolu_05", text: "total 24")]
        )
    }

    func testTaskUpdateNumericTaskIdParsesAsString() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_06","name":"TaskUpdate","input":{"taskId":1,"status":"in_progress"}}]}}"#
        XCTAssertEqual(
            StreamJSONParser.parse(line: line),
            [.toolUse(id: "toolu_06", name: "TaskUpdate",
                      input: ClaudeToolInput(taskId: "1", status: "in_progress"))]
        )
    }
}
