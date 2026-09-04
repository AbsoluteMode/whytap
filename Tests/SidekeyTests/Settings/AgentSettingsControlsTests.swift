import XCTest
@testable import Sidekey

@MainActor
final class AgentSettingsControlsTests: XCTestCase {
    func testModelOptionsIgnoreConfigAndOnlyExposeGPT55() {
        let opts = AgentControlsCodex.modelOptions(config: CodexConfigSnapshot(model: "gpt-5.2"))
        XCTAssertEqual(opts.map { $0.value }, ["gpt-5.5"])
    }

    func testQuickPicksPresentWithNilConfig() {
        let values = AgentControlsCodex.modelOptions(config: CodexConfigSnapshot()).map { $0.value }
        XCTAssertEqual(values, ["gpt-5.5"])
    }

    func testSparkConfigIsNotShownAsCurrentModel() {
        let values = AgentControlsCodex.modelOptions(
            config: CodexConfigSnapshot(model: "gpt-5.3-codex-spark")
        ).map { $0.value }
        XCTAssertEqual(values, ["gpt-5.5"])
    }

    func testSpeedMirrorsConfigTier() {
        // Both spellings of the fast lane -> the "priority" option.
        XCTAssertEqual(AgentControlsCodex.mirroredTier("priority"), "priority")
        XCTAssertEqual(AgentControlsCodex.mirroredTier("fast"), "priority")
        // Normal lane spellings -> the "default" option.
        XCTAssertEqual(AgentControlsCodex.mirroredTier("default"), "default")
        XCTAssertEqual(AgentControlsCodex.mirroredTier("normal"), "default")
        // Case-insensitive.
        XCTAssertEqual(AgentControlsCodex.mirroredTier("Priority"), "priority")
        // Absent / unknown -> nil (picker falls back to Normal).
        XCTAssertNil(AgentControlsCodex.mirroredTier(nil))
        XCTAssertNil(AgentControlsCodex.mirroredTier("turbo"))
    }

    func testSparkDoesNotSupportSpeedControl() {
        XCTAssertFalse(AgentControlsCodex.supportsSpeed(model: "gpt-5.3-codex-spark"))
        XCTAssertTrue(AgentControlsCodex.supportsSpeed(model: "gpt-5.4"))
        XCTAssertTrue(AgentControlsCodex.supportsSpeed(model: nil))
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

    func testCodexEffortOptionsStartAtLowWithNoInheritDash() {
        let opts = AgentControlsCodex.effortOptions
        XCTAssertEqual(opts.map { $0.value }, ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(opts.first?.label, "Low")
    }

    /// What the pickers offer and what `options(for:)` validates against must
    /// be the same sets, or the picker could show a level the run never sends.
    func testPickerOptionSetsMatchStoreEffortLevels() {
        XCTAssertEqual(Set(AgentControlsClaude.effortOptions.map { $0.value }),
                       AgentSettingsStore.claudeEffortLevels)
        XCTAssertEqual(Set(AgentControlsCodex.effortOptions.map { $0.value }),
                       AgentSettingsStore.codexEffortLevels)
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

    func testCodexDisplayedEffortShowsStoredOrLow() {
        // No stored override -> the picker shows Low (what will actually be sent).
        XCTAssertEqual(AgentControlsCodex.displayedEffort(stored: nil), "low")
        // Explicit user override is shown as-is.
        XCTAssertEqual(AgentControlsCodex.displayedEffort(stored: "high"), "high")
        // Case-insensitive stored value.
        XCTAssertEqual(AgentControlsCodex.displayedEffort(stored: "HIGH"), "high")
        // Values the picker cannot represent fall back to Low.
        XCTAssertEqual(AgentControlsCodex.displayedEffort(stored: "bogus"), "low")
        // Claude-only "max" is not a codex level -> Low.
        XCTAssertEqual(AgentControlsCodex.displayedEffort(stored: "max"), "low")
        XCTAssertEqual(AgentControlsCodex.displayedEffort(stored: "xhigh"), "xhigh")
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
