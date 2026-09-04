import XCTest
@testable import Sidekey

final class AgentUsefulLinksExtractorTests: XCTestCase {
    // MARK: useful.actions (primary contract)

    func testExtractsTrailingUsefulActionsJSONFence() throws {
        let text = """
        Here is what you can do.

        ```json
        {"kind":"useful.actions","schemaVersion":1,"items":[\
        {"type":"link","url":"https://brew.sh","description":"Homebrew","provider":"web"},\
        {"type":"path","path":"/Users/maxim/Downloads/Hammerspoon.app","description":"Hammerspoon"},\
        {"type":"copy","text":"/bin/bash -c install","description":"Install command"}]}
        ```
        """

        let extraction = try XCTUnwrap(AgentUsefulLinksExtractor.extract(from: text))

        XCTAssertEqual(extraction.answer, "Here is what you can do.")
        XCTAssertEqual(extraction.block.items.count, 3)
        XCTAssertEqual(
            extraction.block.items[0],
            .link(url: URL(string: "https://brew.sh")!, description: "Homebrew", provider: "web")
        )
        XCTAssertEqual(
            extraction.block.items[1],
            .path(path: "/Users/maxim/Downloads/Hammerspoon.app", description: "Hammerspoon")
        )
        XCTAssertEqual(
            extraction.block.items[2],
            .copy(text: "/bin/bash -c install", description: "Install command")
        )
    }

    /// Codex tags the fence with the block kind as the language hint
    /// (```useful.actions) instead of ```json. The extractor must treat any
    /// info string as an opaque language tag and still pull the JSON — a real
    /// Codex emission left the raw JSON sitting in the answer text before this
    /// was fixed (Claude's ```json worked, Codex's ```useful.actions did not).
    func testExtractsCodexUsefulActionsInfoStringFence() throws {
        let text = """
        Hammerspoon лежит здесь: `/Users/maxim/Downloads/Hammerspoon.app`.

        ```useful.actions
        {"kind":"useful.actions","schemaVersion":1,"items":[\
        {"type":"path","description":"Hammerspoon.app","path":"/Users/maxim/Downloads/Hammerspoon.app"}]}
        ```
        """

        let extraction = try XCTUnwrap(AgentUsefulLinksExtractor.extract(from: text))

        XCTAssertEqual(
            extraction.answer,
            "Hammerspoon лежит здесь: `/Users/maxim/Downloads/Hammerspoon.app`."
        )
        XCTAssertEqual(
            extraction.block.items,
            [.path(path: "/Users/maxim/Downloads/Hammerspoon.app", description: "Hammerspoon.app")]
        )
    }

    func testAcceptsCompactUsefulActionsObjectWithoutKind() throws {
        let text = """
        Useful context is here.

        ```json
        {"items":[{"type":"path","path":"/tmp/log.txt"}]}
        ```
        """

        let extraction = try XCTUnwrap(AgentUsefulLinksExtractor.extract(from: text))

        XCTAssertEqual(extraction.answer, "Useful context is here.")
        XCTAssertEqual(extraction.block.items, [.path(path: "/tmp/log.txt", description: nil)])
    }

    // MARK: useful.links (legacy backward compatibility)

    func testExtractsLegacyUsefulLinksJSONFenceAsLinkItems() throws {
        let text = """
        Useful context is here.

        ```json
        {"kind":"useful.links","schemaVersion":1,"links":[{"url":"https://example.com/spec","description":"Spec","provider":"notion"}]}
        ```
        """

        let extraction = try XCTUnwrap(AgentUsefulLinksExtractor.extract(from: text))

        XCTAssertEqual(extraction.answer, "Useful context is here.")
        XCTAssertEqual(extraction.block.items.count, 1)
        XCTAssertEqual(
            extraction.block.items[0],
            .link(url: URL(string: "https://example.com/spec")!, description: "Spec", provider: "notion")
        )
    }

    func testAcceptsCompactLegacyLinksObjectWithoutKind() throws {
        let text = """
        Useful context is here.

        ```json
        {"links":[{"url":"https://example.com/a","description":"A"}]}
        ```
        """

        let extraction = try XCTUnwrap(AgentUsefulLinksExtractor.extract(from: text))

        XCTAssertEqual(extraction.answer, "Useful context is here.")
        XCTAssertEqual(
            extraction.block.items.first,
            .link(url: URL(string: "https://example.com/a")!, description: "A", provider: nil)
        )
    }

    // MARK: passthrough

    func testReturnsNilWhenTrailingFenceIsNotActionableJSON() {
        let text = """
        Leave this alone.

        ```json
        {"hello":"world"}
        ```
        """

        XCTAssertNil(AgentUsefulLinksExtractor.extract(from: text))
    }
}
