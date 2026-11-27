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

    func testClaudeModelOptionsComeFromClaudeCodeAndKeepASavedModel() {
        let catalog = [ClaudeModelOption(value: "default", displayName: "Default (recommended)"),
                       ClaudeModelOption(value: "fable", displayName: "Fable 5.2")]
        let opts = AgentControlsClaude.modelOptions(catalog: catalog, selected: "claude-old-1")
        XCTAssertEqual(opts.map(\.value), ["claude-old-1", "default", "fable"])
        XCTAssertEqual(opts.first?.label, "claude-old-1 (saved)")
        XCTAssertEqual(opts.last?.label, "Fable 5.2")
    }

    func testClaudeWithoutCatalogOffersOnlyItsOwnDefault() {
        XCTAssertEqual(AgentControlsClaude.modelOptions(catalog: [], selected: nil).map(\.value), ["default"])
    }

    func testClaudeEffortLabels() {
        XCTAssertEqual(AgentControlsClaude.effortLabel("low"), "Low")
        XCTAssertEqual(AgentControlsClaude.effortLabel("xhigh"), "Very high")
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
