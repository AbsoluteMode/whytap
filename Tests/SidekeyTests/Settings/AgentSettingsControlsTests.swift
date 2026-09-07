import XCTest
@testable import Sidekey

@MainActor
final class AgentSettingsControlsTests: XCTestCase {
    func testModelOptionsComeFromRegistryAndRetainUnavailableSelection() {
        let models = [CodexModelOption(model: "new-model", displayName: "New model")]
        let opts = AgentControlsCodex.modelOptions(catalog: models, selected: "saved-model")
        XCTAssertEqual(opts.map { $0.value }, ["saved-model", "new-model"])
        XCTAssertEqual(opts.last?.label, "New model")
    }

    func testEmptyCatalogDoesNotInventOldModels() {
        XCTAssertEqual(AgentControlsCodex.modelOptions(catalog: [], selected: nil).map { $0.value }, [""])
    }

    func testClaudeModelOptionsAreHardcodedToSonnet() {
        // Hardcoded single pinned model, independent of the scanned catalog.
        let opts = AgentControlsClaude.modelOptions(ClaudeModelCatalog())
        XCTAssertEqual(opts.map { $0.value }, ["sonnet"])
        XCTAssertEqual(opts.first?.label, "Sonnet")
    }

    // MARK: - Reasoning picker (no "—" inherit option, list starts at Low)

    func testClaudeEffortOptionsStartAtLowWithNoInheritDash() {
        let opts = AgentControlsClaude.effortOptions
        XCTAssertEqual(opts.map { $0.value }, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(opts.first?.label, "Low")
    }

    func testClaudeDisplayedEffortShowsStoredOrLow() {
        // No stored override -> the picker shows Low (what will actually be sent).
        XCTAssertEqual(AgentControlsClaude.displayedEffort(stored: nil), "low")
        // Explicit user override is shown as-is.
        XCTAssertEqual(AgentControlsClaude.displayedEffort(stored: "medium"), "medium")
        XCTAssertEqual(AgentControlsClaude.displayedEffort(stored: "max"), "max")
        // Case-insensitive stored value.
        XCTAssertEqual(AgentControlsClaude.displayedEffort(stored: "XHIGH"), "xhigh")
        // A stored value outside the option set falls back to Low.
        XCTAssertEqual(AgentControlsClaude.displayedEffort(stored: "turbo"), "low")
    }

    /// The "—" (inherit) entry is gone from the Reasoning pickers: the option
    /// tuple `("—", nil)` must not appear in the controls source.
    func testReasoningPickersHaveNoInheritDashOption() throws {
        let url = try projectRoot()
            .appendingPathComponent("Sources/Sidekey/Settings/AgentSettingsControls.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(s.contains(#"("—", nil)"#))
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "AgentSettingsControlsTests", code: 1)
    }
}
