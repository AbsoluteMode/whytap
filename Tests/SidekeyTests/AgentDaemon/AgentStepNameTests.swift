import XCTest
@testable import Sidekey

/// `AgentStepName` turns a raw agent action into a short human label for the
/// response pill: Codex streams the full shell command (wrapped as
/// `/bin/zsh -lc '<cmd>'`), Claude streams the tool name. Both collapse to
/// the same friendly verbs; an unknown shell command never shows its raw
/// command line.
final class AgentStepNameTests: XCTestCase {
    // MARK: - Codex shell commands

    func testUnwrapsShellWrapperAndLabelsSearch() {
        XCTAssertEqual(AgentStepName.forShellCommand("/bin/zsh -lc 'grep -rn foo .'"), "Searching")
    }

    func testRipgrepIsSearching() {
        XCTAssertEqual(AgentStepName.forShellCommand("rg pattern"), "Searching")
    }

    func testCatIsReading() {
        XCTAssertEqual(AgentStepName.forShellCommand("cat file.txt"), "Reading")
    }

    func testSedIsEditing() {
        XCTAssertEqual(AgentStepName.forShellCommand("/bin/bash -lc \"sed -i s/a/b/ f\""), "Editing")
    }

    func testApplyPatchIsEditing() {
        XCTAssertEqual(AgentStepName.forShellCommand("apply_patch"), "Editing")
    }

    func testLsIsBrowsingFiles() {
        XCTAssertEqual(AgentStepName.forShellCommand("ls -la"), "Browsing files")
    }

    func testFindIsBrowsingFiles() {
        XCTAssertEqual(AgentStepName.forShellCommand("find . -name x"), "Browsing files")
    }

    func testSwiftTestIsRunningTests() {
        XCTAssertEqual(AgentStepName.forShellCommand("swift test"), "Running tests")
    }

    func testNpmTestIsRunningTests() {
        XCTAssertEqual(AgentStepName.forShellCommand("npm test"), "Running tests")
    }

    func testPytestIsRunningTests() {
        XCTAssertEqual(AgentStepName.forShellCommand("pytest tests/"), "Running tests")
    }

    func testSwiftBuildIsBuilding() {
        XCTAssertEqual(AgentStepName.forShellCommand("swift build"), "Building")
    }

    func testPythonIsRunning() {
        XCTAssertEqual(AgentStepName.forShellCommand("python script.py"), "Running")
    }

    func testGitIsGit() {
        XCTAssertEqual(AgentStepName.forShellCommand("git status"), "Git")
    }

    func testCurlIsFetching() {
        XCTAssertEqual(AgentStepName.forShellCommand("curl https://example.com"), "Fetching")
    }

    func testMkdirIsManagingFiles() {
        XCTAssertEqual(AgentStepName.forShellCommand("mkdir foo"), "Managing files")
    }

    func testSkipsLeadingCdHop() {
        XCTAssertEqual(AgentStepName.forShellCommand("/bin/zsh -lc 'cd /repo && rg needle'"), "Searching")
    }

    func testStripsEnvAndPathPrefix() {
        XCTAssertEqual(AgentStepName.forShellCommand("FOO=bar /usr/bin/grep x"), "Searching")
    }

    func testUnknownCommandFallsBackToGeneric() {
        XCTAssertEqual(AgentStepName.forShellCommand("frobnicate --weird"), "Running a command")
    }

    func testEmptyCommandFallsBackToGeneric() {
        XCTAssertEqual(AgentStepName.forShellCommand(""), "Running a command")
    }

    // MARK: - Claude tool names (empty input — fallback behavior)

    func testClaudeBashIsGeneric() {
        XCTAssertEqual(AgentStepName.forClaudeTool("Bash", input: ClaudeToolInput()), "Running a command")
    }

    func testClaudeReadIsReading() {
        XCTAssertEqual(AgentStepName.forClaudeTool("Read", input: ClaudeToolInput()), "Reading")
    }

    func testClaudeEditIsEditing() {
        XCTAssertEqual(AgentStepName.forClaudeTool("Edit", input: ClaudeToolInput()), "Editing")
    }

    func testClaudeGrepIsSearching() {
        XCTAssertEqual(AgentStepName.forClaudeTool("Grep", input: ClaudeToolInput()), "Searching")
    }

    func testClaudeWebSearchIsSearchingWeb() {
        XCTAssertEqual(AgentStepName.forClaudeTool("WebSearch", input: ClaudeToolInput()), "Searching the web")
    }

    func testClaudeUnknownToolUsesAppOwnedFallback() {
        XCTAssertEqual(AgentStepName.forClaudeTool("SomethingCustom", input: ClaudeToolInput()), "Working")
    }

    // MARK: - Claude tool names (input-driven labels)

    func testClaudeBashUsesCommandCategoryNotModelDescription() {
        XCTAssertEqual(
            AgentStepName.forClaudeTool(
                "Bash",
                input: ClaudeToolInput(
                    description: "Ejecutando algo",
                    command: "python3 -m pytest"
                )
            ),
            "Running"
        )
    }

    func testClaudeBashWithoutDescriptionFallsBackToGeneric() {
        XCTAssertEqual(AgentStepName.forClaudeTool("Bash", input: ClaudeToolInput()), AgentStepName.genericShell)
    }

    func testClaudeReadShowsBasenameOnly() {
        XCTAssertEqual(
            AgentStepName.forClaudeTool("Read", input: ClaudeToolInput(filePath: "/private/tmp/demo/calculator.py")),
            "Reading calculator.py"
        )
    }

    func testClaudeEditAndWriteShowBasename() {
        XCTAssertEqual(
            AgentStepName.forClaudeTool("Edit", input: ClaudeToolInput(filePath: "/a/b/style.css")),
            "Editing style.css"
        )
        XCTAssertEqual(
            AgentStepName.forClaudeTool("Write", input: ClaudeToolInput(filePath: "/a/b/index.html")),
            "Editing index.html"
        )
    }

    func testClaudeGrepShowsClippedPattern() {
        XCTAssertEqual(
            AgentStepName.forClaudeTool("Grep", input: ClaudeToolInput(pattern: "subtract")),
            "Searching \"subtract\""
        )
    }

    func testClaudeTaskToolsLabelPlanning() {
        XCTAssertEqual(AgentStepName.forClaudeTool("TaskCreate", input: ClaudeToolInput()), "Planning")
        XCTAssertEqual(AgentStepName.forClaudeTool("TaskUpdate", input: ClaudeToolInput()), "Planning")
        XCTAssertEqual(AgentStepName.forClaudeTool("TodoWrite", input: ClaudeToolInput()), "Planning")
    }

    func testClaudeUnknownToolUsesFallbackNew() {
        XCTAssertEqual(AgentStepName.forClaudeTool("ToolSearch", input: ClaudeToolInput()), "Working")
    }
}
