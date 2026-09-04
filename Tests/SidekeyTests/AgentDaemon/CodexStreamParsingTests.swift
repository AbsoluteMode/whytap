import XCTest
@testable import Sidekey

final class CodexStreamParsingTests: XCTestCase {
    func testThreadStarted() {
        let line = #"{"type":"thread.started","thread_id":"abc-123"}"#
        XCTAssertEqual(CodexStreamJSONParser.parse(line: line), .threadStarted(threadID: "abc-123"))
    }
    func testAgentMessage() {
        let line = #"{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"hi there"}}"#
        XCTAssertEqual(CodexStreamJSONParser.parse(line: line), .agentMessage(text: "hi there"))
    }
    func testCommandStarted() {
        let line = #"{"type":"item.started","item":{"id":"i5","type":"command_execution","command":"/bin/zsh -lc 'echo hi'","status":"in_progress"}}"#
        XCTAssertEqual(CodexStreamJSONParser.parse(line: line), .commandStarted(command: "/bin/zsh -lc 'echo hi'"))
    }
    func testTurnCompleted() {
        let line = #"{"type":"turn.completed","usage":{"input_tokens":1}}"#
        XCTAssertEqual(CodexStreamJSONParser.parse(line: line), .turnCompleted)
    }
    func testDeprecationErrorIsIgnored() {
        let line = #"{"type":"item.completed","item":{"id":"i0","type":"error","message":"`[features].codex_hooks` is deprecated. Use `[features].hooks`."}}"#
        XCTAssertNil(CodexStreamJSONParser.parse(line: line))
    }
    func testUnderDevelopmentWarningIsIgnored() {
        // child_agents_md & co. — Codex emits these as type:error but the turn
        // still completes (agent answers). Must NOT surface, else the client
        // tears the turn down for nothing.
        let line = #"{"type":"item.completed","item":{"id":"i0","type":"error","message":"Under-development features enabled: child_agents_md. Under-development features are incomplete and may behave unpredictably. To suppress this warning, set `suppress_unstable_features_warning = true` in /Users/maxim/.codex/config.toml."}}"#
        XCTAssertNil(CodexStreamJSONParser.parse(line: line))
    }
    func testRealItemErrorStillSurfaces() {
        // A genuine failure carries none of the benign markers — must surface.
        let line = #"{"type":"item.completed","item":{"id":"i0","type":"error","message":"model not supported"}}"#
        XCTAssertEqual(CodexStreamJSONParser.parse(line: line), .streamError("model not supported"))
    }
    func testPlainTextLineIgnored() {
        XCTAssertNil(CodexStreamJSONParser.parse(line: "Reading additional input from stdin..."))
    }

    func testParsesTodoListUpdate() {
        let line = #"{"type":"item.updated","item":{"id":"item_1","type":"todo_list","items":[{"text":"Inspect workspace","completed":true},{"text":"Create files","completed":false}]}}"#
        XCTAssertEqual(
            CodexStreamJSONParser.parse(line: line),
            .todoListUpdated(items: [
                CodexTodoItem(text: "Inspect workspace", completed: true),
                CodexTodoItem(text: "Create files", completed: false),
            ])
        )
    }

    func testTodoListCompletedItemEventIgnored() {
        let line = #"{"type":"item.completed","item":{"id":"item_1","type":"todo_list","items":[{"text":"a","completed":true}]}}"#
        XCTAssertNil(CodexStreamJSONParser.parse(line: line))
    }

    func testParsesFileChangeStarted() {
        let line = #"{"type":"item.started","item":{"id":"item_4","type":"file_change","changes":[{"path":"/tmp/x/index.html","kind":"add"},{"path":"/tmp/x/style.css","kind":"add"}],"status":"in_progress"}}"#
        XCTAssertEqual(
            CodexStreamJSONParser.parse(line: line),
            .fileChangeStarted(paths: ["/tmp/x/index.html", "/tmp/x/style.css"], kind: "add")
        )
    }

    func testFileChangeCompletedIgnored() {
        let line = #"{"type":"item.completed","item":{"id":"item_4","type":"file_change","changes":[{"path":"/tmp/x/a.css","kind":"update"}],"status":"completed"}}"#
        XCTAssertNil(CodexStreamJSONParser.parse(line: line))
    }
}

final class CodexEventMapperTests: XCTestCase {
    func testMapperAgentMessageToFinalAnswer() {
        // "hello" has no sentence terminator, so firstSentence returns the full
        // text — narration and finalAnswer carry the same string.
        let events = CodexEventMapper.map(.agentMessage(text: "hello"))
        XCTAssertEqual(events, [.finalAnswer(text: "hello")])
    }
    func testMapperCommandToToolExecuting() {
        XCTAssertEqual(CodexEventMapper.map(.commandStarted(command: "/bin/zsh -lc 'grep -rn foo .'")),
                       [.toolExecuting(tool: "Shell", label: "Searching")])
    }
    func testMapperTurnCompletedToDone() {
        XCTAssertEqual(CodexEventMapper.map(.turnCompleted), [.done(sources: [])])
    }
    func testMapperThreadStartedEmitsNothing() {
        XCTAssertEqual(CodexEventMapper.map(.threadStarted(threadID: "x")), [])
    }

    func testCodexAgentMessageEmitsOnlyAnswerContent() {
        let events = CodexEventMapper.map(.agentMessage(text: "I'll inspect the project layout first. Then tests."))
        XCTAssertEqual(events, [.finalAnswer(text: "I'll inspect the project layout first. Then tests.")])
    }

    func testTodoListMapsToProgressLabel() {
        XCTAssertEqual(
            CodexEventMapper.map(.todoListUpdated(items: [
                CodexTodoItem(text: "Inspect workspace", completed: true),
                CodexTodoItem(text: "Create static clock files", completed: false),
                CodexTodoItem(text: "Verify files exist", completed: false),
            ])),
            [.toolExecuting(tool: "Plan", label: "Working on plan (2/3)")]
        )
    }

    func testTodoListAllCompletedShowsPlanComplete() {
        XCTAssertEqual(
            CodexEventMapper.map(.todoListUpdated(items: [CodexTodoItem(text: "a", completed: true)])),
            [.toolExecuting(tool: "Plan", label: "Plan complete (1/1)")]
        )
    }

    func testFileChangeMapsToBasenameLabel() {
        XCTAssertEqual(
            CodexEventMapper.map(.fileChangeStarted(paths: ["/tmp/x/index.html"], kind: "add")),
            [.toolExecuting(tool: "Files", label: "Creating index.html")]
        )
        XCTAssertEqual(
            CodexEventMapper.map(.fileChangeStarted(paths: ["/a/1.css", "/a/2.js", "/a/3.html"], kind: "update")),
            [.toolExecuting(tool: "Files", label: "Editing 3 files")]
        )
    }
}
