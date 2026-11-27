import XCTest
@testable import Sidekey

final class AgentModelBrandTests: XCTestCase {
    func testHarnessMarksAreBundled() {
        XCTAssertEqual(TranscriptionProviderBrand.agent(.claude).assetName, "claude-code")
        XCTAssertEqual(TranscriptionProviderBrand.agent(.codex).assetName, "codex")
    }

    func testOpenRouterModelLosesOnlyALeadingHostPrefix() {
        XCTAssertEqual(AgentModelBrand.normalizedOpenRouterModel(" openrouter/google/gemini-3.8-flash "), "google/gemini-3.8-flash")
        XCTAssertEqual(AgentModelBrand.normalizedOpenRouterModel("openrouter/auto"), "openrouter/auto")
        XCTAssertEqual(AgentModelBrand.normalizedOpenRouterModel("anthropic/claude-sonnet-5.5"), "anthropic/claude-sonnet-5.5")
    }

    func testEveryAuthorMarkIsBundled() {
        for brand in AgentModelBrand.allCases {
            XCTAssertEqual(brand.assetName, "model-\(brand.rawValue)")
        }
    }
}
