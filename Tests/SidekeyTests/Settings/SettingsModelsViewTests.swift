import XCTest
@testable import Sidekey

@MainActor
final class SettingsModelsViewTests: XCTestCase {
    func test_models_uses_mac_reskin_components() throws {
        let url = try projectRoot()
            .appendingPathComponent("Sources/Sidekey/Settings/SettingsModelsView.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(s.contains("MacSegmented"))
        XCTAssertTrue(s.contains("MacPopup"))
        XCTAssertTrue(s.contains("MacField"))
        XCTAssertTrue(s.contains("ProviderBrandIcon"))
        XCTAssertTrue(s.contains("byokProviderBrandIcon(provider)"))
        // whytapProviderBrandIcon was removed with the Whytap STT picker (#511):
        // the whytap level shows static text, no per-provider brand icon.
        XCTAssertFalse(s.contains("whytapProviderBrandIcon"))
        XCTAssertTrue(s.contains("Smart processing LLM"))
        XCTAssertTrue(s.contains("Drop cleanup + meeting notes"))
        XCTAssertTrue(s.contains("Route: OpenRouter direct"))
        XCTAssertTrue(s.contains("Route: Self-hosted"))
        XCTAssertTrue(s.contains("Self-hosted (OpenAI-compatible)"))
        XCTAssertFalse(s.contains("Custom endpoint"))
        XCTAssertTrue(s.contains("OpenRouter /chat/completions"))
        XCTAssertTrue(s.contains("OpenAI-compatible /chat/completions"))
        XCTAssertTrue(s.contains("http://localhost:8000/v1"))
        XCTAssertTrue(s.contains("ScrollView(.vertical)"))
        XCTAssertTrue(s.contains(".frame(maxHeight: Self.suggestionsMaxHeight)"))
        XCTAssertTrue(s.contains("Agent Mode still uses the provider selected on the Agent tab."))
        XCTAssertTrue(s.contains("Task { await viewModel.saveCurrentSelection() }"))
        XCTAssertTrue(s.contains("Task { await viewModel.downloadLocalModel() }"))
        XCTAssertTrue(s.contains("Task { await viewModel.deleteLocalModel() }"))
        XCTAssertTrue(s.contains(".task { await viewModel.watchLocalModelStatus() }"))
        XCTAssertTrue(s.contains("Parakeet TDT v3"))
        XCTAssertTrue(s.contains("LocalParakeetModelIcon"))
        XCTAssertTrue(s.contains("Multilingual Core ML ASR"))
        XCTAssertTrue(s.contains("LocalLLMQwenIcon()"))
        XCTAssertFalse(s.contains("ProviderBrandIcon(systemName: \"memorychip\")"))
        XCTAssertTrue(s.contains("Task { await viewModel.refreshCustomLLMModels() }"))
        XCTAssertTrue(s.contains("viewModel.selectLevel($0)"))
        XCTAssertFalse(s.contains("Local models are coming soon"))
        XCTAssertFalse(s.contains("comingSoon("))
        XCTAssertFalse(s.contains("ProviderBrandIcon(systemName: \"cpu\")"))
        XCTAssertFalse(s.contains("Approve change"))
        XCTAssertFalse(s.contains("Approve isolation change"))
        XCTAssertFalse(s.contains("levelApprovalControls"))
        XCTAssertFalse(s.contains("viewModel.save()"))
        XCTAssertFalse(s.contains("pickerStyle(.segmented)"))  // old segmented gone
        XCTAssertFalse(s.contains("SecureField("))             // wrapped by MacField now
        XCTAssertFalse(s.contains("viewModel.level = $0; viewModel.save()"))
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "SettingsModelsViewTests", code: 1)
    }
}
