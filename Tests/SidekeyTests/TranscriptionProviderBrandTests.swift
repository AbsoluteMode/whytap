import XCTest
@testable import Sidekey

final class TranscriptionProviderBrandTests: XCTestCase {
    // MARK: agent(_:)

    func testAgentCodexBrand() {
        let brand = TranscriptionProviderBrand.agent(.codex)
        XCTAssertEqual(brand.assetName, "codex")
        XCTAssertEqual(brand.label, "Codex")
        XCTAssertNil(brand.systemName)
    }

    func testAgentClaudeBrand() {
        let brand = TranscriptionProviderBrand.agent(.claude)
        XCTAssertEqual(brand.assetName, "claude-code")
        XCTAssertEqual(brand.label, "Claude Code")
        XCTAssertNil(brand.systemName)
    }

    func testAgentCoversEveryCLIProvider() {
        // Guard: every CLIProviderID maps to an asset-backed brand. If a new
        // case is added without a mapping the switch won't compile; this also
        // asserts no agent brand silently falls back to systemName.
        for provider in CLIProviderID.allCases {
            let brand = TranscriptionProviderBrand.agent(provider)
            XCTAssertNotNil(brand.assetName, "agent(\(provider)) has no assetName")
            XCTAssertFalse(brand.label.isEmpty, "agent(\(provider)) has empty label")
        }
    }

    // MARK: google

    func testGoogleBrand() {
        let brand = TranscriptionProviderBrand.google
        XCTAssertEqual(brand.assetName, "google")
        XCTAssertEqual(brand.label, "Google")
        XCTAssertNil(brand.systemName)
    }

    // MARK: OpenRouter

    func testOpenRouterBrand() {
        let brand = TranscriptionProviderBrand.openRouter
        XCTAssertEqual(brand.assetName, "openrouter")
        XCTAssertEqual(brand.label, "OpenRouter")
        XCTAssertNil(brand.systemName)
    }

    func testCustomLLMBrand() {
        let brand = TranscriptionProviderBrand.customLLM
        XCTAssertNil(brand.assetName)
        XCTAssertEqual(brand.label, "Custom LLM")
        XCTAssertEqual(brand.systemName, "server.rack")
    }

    func testLocalTranscriptionBrand() {
        // The on-device path surfaces the genuine Qwen mark in full color in the
        // Dynamic Island, not a generic CPU glyph.
        let brand = TranscriptionProviderBrand.localTranscription
        XCTAssertEqual(brand.assetName, "qwen")
        XCTAssertEqual(brand.label, "Qwen")
        XCTAssertNil(brand.systemName)
        XCTAssertTrue(brand.isFullColor)
    }

    func testProviderBrandsDefaultToMonochrome() {
        // Only the Qwen on-device mark opts into full color; every cloud provider
        // mark stays template/white in the island.
        XCTAssertFalse(TranscriptionProviderBrand.agent(.codex).isFullColor)
        XCTAssertFalse(TranscriptionProviderBrand.agent(.claude).isFullColor)
        XCTAssertFalse(TranscriptionProviderBrand.google.isFullColor)
        XCTAssertFalse(TranscriptionProviderBrand.openRouter.isFullColor)
        XCTAssertFalse(TranscriptionProviderBrand.customLLM.isFullColor)
        XCTAssertFalse(TranscriptionProviderBrand.byok(.soniox).isFullColor)
    }

    @MainActor
    func testCurrentDropBrandReturnsLocalForLocalTranscription() {
        let prefs = SelfKeyPreferences.shared
        let originalLevel = prefs.transcriptionLevel
        defer { prefs.transcriptionLevel = originalLevel }

        prefs.transcriptionLevel = .local

        XCTAssertEqual(TranscriptionProviderBrand.currentDrop(), .localTranscription)
    }

    @MainActor
    func testCurrentDropBrandReturnsSelectedProviderForYourKey() {
        let prefs = SelfKeyPreferences.shared
        let originalLevel = prefs.transcriptionLevel
        let originalProvider = prefs.selectedProvider
        defer {
            prefs.transcriptionLevel = originalLevel
            prefs.selectedProvider = originalProvider
        }

        prefs.transcriptionLevel = .yourKey
        prefs.selectedProvider = .deepgram

        XCTAssertEqual(TranscriptionProviderBrand.currentDrop(), .byok(.deepgram))
    }

    @MainActor
    func testCurrentDropCleanupBrandFollowsLLMRoute() {
        let prefs = SelfKeyPreferences.shared
        let originalLLMLevel = prefs.llmLevel
        defer { prefs.llmLevel = originalLLMLevel }

        prefs.llmLevel = .yourKey
        XCTAssertEqual(TranscriptionProviderBrand.currentDropCleanup(), .openRouter)

        prefs.llmLevel = .custom
        XCTAssertEqual(TranscriptionProviderBrand.currentDropCleanup(), .customLLM)

        // The on-device LLM has no cloud provider brand to surface.
        prefs.llmLevel = .local
        XCTAssertNil(TranscriptionProviderBrand.currentDropCleanup())
    }

    // MARK: assets resolve to bundled files

    func testRecordingSourceBrandAssetsAreBundled() throws {
        let iconDir = try projectRoot().appendingPathComponent("Resources/UsefulLinkIcons")
        let brands: [TranscriptionProviderBrand] = [
            .agent(.codex),
            .agent(.claude),
            .google,
            .openRouter,
            .localTranscription,
        ]
        for brand in brands {
            let assetName = try XCTUnwrap(brand.assetName, "brand \(brand.label) missing assetName")
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: iconDir.appendingPathComponent("\(assetName).pdf").path
                ),
                "Missing \(assetName).pdf for brand \(brand.label)"
            )
        }
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "TranscriptionProviderBrandTests", code: 1)
    }
}
