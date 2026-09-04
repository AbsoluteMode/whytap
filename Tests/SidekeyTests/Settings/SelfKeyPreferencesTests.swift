import XCTest
@testable import Sidekey

@MainActor
final class SelfKeyPreferencesTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "byok.test.\(UUID().uuidString)")!
        return d
    }

    func testDefaultsFollowHardwareAndSoniox() {
        // A fresh install runs on-device on Apple Silicon and on BYOK elsewhere.
        let appleSilicon = SelfKeyPreferences(defaults: makeDefaults(), isAppleSilicon: true)
        XCTAssertEqual(appleSilicon.transcriptionLevel, .local)
        XCTAssertEqual(appleSilicon.llmLevel, .local)

        let intel = SelfKeyPreferences(defaults: makeDefaults(), isAppleSilicon: false)
        XCTAssertEqual(intel.transcriptionLevel, .yourKey)
        XCTAssertEqual(intel.llmLevel, .yourKey)

        // BYOK default is soniox now (OpenAI dropped — its realtime doesn't stream).
        XCTAssertEqual(intel.selectedProvider, .soniox)
        XCTAssertNil(intel.selfHostedBaseURL)
        XCTAssertEqual(intel.selfHostedModel, "gpt-4o-transcribe")
        XCTAssertEqual(intel.openRouterModel, "openai/gpt-4o-mini")
        XCTAssertNil(intel.customLLMBaseURL)
        XCTAssertEqual(intel.customLLMModel, "local-model")
    }

    func testDefaultLevelHelpersFollowHardware() {
        XCTAssertEqual(TranscriptionIsolationLevel.defaultLevel(isAppleSilicon: true), .local)
        XCTAssertEqual(TranscriptionIsolationLevel.defaultLevel(isAppleSilicon: false), .yourKey)
        XCTAssertEqual(LLMIsolationLevel.defaultLevel(isAppleSilicon: true), .local)
        XCTAssertEqual(LLMIsolationLevel.defaultLevel(isAppleSilicon: false), .yourKey)
    }

    func testRetiredCloudLevelDecodesToHardwareDefault() {
        // Older installs persisted the cloud ("whytap") level. It is no longer
        // a case, so the stored string resolves to the hardware default instead
        // of failing to decode.
        let d = makeDefaults()
        d.set("whytap", forKey: "sidekey.models.transcriptionLevel")
        d.set("whytap", forKey: "sidekey.models.llmLevel")

        let appleSilicon = SelfKeyPreferences(defaults: d, isAppleSilicon: true)
        XCTAssertEqual(appleSilicon.transcriptionLevel, .local)
        XCTAssertEqual(appleSilicon.llmLevel, .local)

        let intel = SelfKeyPreferences(defaults: d, isAppleSilicon: false)
        XCTAssertEqual(intel.transcriptionLevel, .yourKey)
        XCTAssertEqual(intel.llmLevel, .yourKey)
    }

    func testLegacyOpenAISelectionMigratesToSoniox() {
        // OpenAI is no longer offered for BYOK; a legacy/stored OpenAI selection
        // resolves to soniox so it's gone from the UI AND the runtime path.
        let d = makeDefaults()
        let prefs = SelfKeyPreferences(defaults: d)
        prefs.selectedProvider = .openAI
        XCTAssertEqual(SelfKeyPreferences(defaults: d).selectedProvider, .soniox)
    }

    func testSelectableExcludesOpenAIButKeepsCaseForDecoding() {
        XCTAssertFalse(BYOKProvider.selectable.contains(.openAI))
        XCTAssertEqual(BYOKProvider.selectable, [.selfHosted, .deepgram, .soniox, .elevenLabs])
        // The case must remain so a legacy stored "openAI" value still decodes.
        XCTAssertTrue(BYOKProvider.allCases.contains(.openAI))
    }

    func testPersistsLevelProviderBaseURLModel() {
        let d = makeDefaults()
        let prefs = SelfKeyPreferences(defaults: d)
        prefs.transcriptionLevel = .yourKey
        prefs.selectedProvider = .selfHosted
        prefs.selfHostedBaseURL = "https://stt.example.com"
        prefs.selfHostedModel = "whisper-large-v3"

        let reloaded = SelfKeyPreferences(defaults: d)
        XCTAssertEqual(reloaded.transcriptionLevel, .yourKey)
        XCTAssertEqual(reloaded.selectedProvider, .selfHosted)
        XCTAssertEqual(reloaded.selfHostedBaseURL, "https://stt.example.com")
        XCTAssertEqual(reloaded.selfHostedModel, "whisper-large-v3")
    }

    func testAvailableTranscriptionModelsPerProvider() {
        XCTAssertEqual(BYOKProvider.openAI.availableTranscriptionModels, ["gpt-4o-transcribe", "gpt-4o-mini-transcribe"])
        XCTAssertEqual(BYOKProvider.deepgram.availableTranscriptionModels, ["nova-3"])
        XCTAssertEqual(BYOKProvider.soniox.availableTranscriptionModels, ["stt-rt-v5"])
        XCTAssertEqual(BYOKProvider.elevenLabs.availableTranscriptionModels, ["scribe_v2_realtime"])
        XCTAssertTrue(BYOKProvider.selfHosted.availableTranscriptionModels.isEmpty)  // free-text
    }

    func testTranscriptionModelDefaultsToProviderDefault() {
        let prefs = SelfKeyPreferences(defaults: makeDefaults())
        XCTAssertEqual(prefs.transcriptionModel(for: .openAI), "gpt-4o-transcribe")
        XCTAssertEqual(prefs.transcriptionModel(for: .deepgram), "nova-3")
        XCTAssertEqual(prefs.transcriptionModel(for: .soniox), "stt-rt-v5")
        XCTAssertEqual(prefs.transcriptionModel(for: .elevenLabs), "scribe_v2_realtime")
    }

    func testTranscriptionModelPersistsPerProvider() {
        let d = makeDefaults()
        let prefs = SelfKeyPreferences(defaults: d)
        prefs.setTranscriptionModel("gpt-4o-mini-transcribe", for: .openAI)
        let reloaded = SelfKeyPreferences(defaults: d)
        XCTAssertEqual(reloaded.transcriptionModel(for: .openAI), "gpt-4o-mini-transcribe")
        XCTAssertEqual(reloaded.transcriptionModel(for: .deepgram), "nova-3")  // untouched → default
        XCTAssertEqual(reloaded.transcriptionModel(for: .soniox), "stt-rt-v5")  // untouched → default
    }

    func testTranscriptionModelForSelfHostedMapsToSelfHostedModel() {
        let d = makeDefaults()
        let prefs = SelfKeyPreferences(defaults: d)
        prefs.setTranscriptionModel("whisper-large-v3", for: .selfHosted)
        XCTAssertEqual(prefs.selfHostedModel, "whisper-large-v3")
        XCTAssertEqual(prefs.transcriptionModel(for: .selfHosted), "whisper-large-v3")
    }

    func testOpenRouterModelEmptyInputFallsBackToExplicitModel() {
        let d = makeDefaults()
        let prefs = SelfKeyPreferences(defaults: d)
        prefs.openRouterModel = "   "

        XCTAssertEqual(SelfKeyPreferences(defaults: d).openRouterModel, "openai/gpt-4o-mini")
    }

    func testCustomLLMEndpointPersistsBaseURLAndModel() {
        let d = makeDefaults()
        let prefs = SelfKeyPreferences(defaults: d)
        prefs.customLLMBaseURL = " http://localhost:8000/v1 "
        prefs.customLLMModel = " llama/local "

        let reloaded = SelfKeyPreferences(defaults: d)
        XCTAssertEqual(reloaded.customLLMBaseURL, "http://localhost:8000/v1")
        XCTAssertEqual(reloaded.customLLMModel, "llama/local")
    }

    func testCustomLLMEmptyInputClearsBaseURLAndFallsBackToDefaultModel() {
        let d = makeDefaults()
        let prefs = SelfKeyPreferences(defaults: d)
        prefs.customLLMBaseURL = "http://localhost:8000/v1"
        prefs.customLLMModel = "llama/local"
        prefs.customLLMBaseURL = "   "
        prefs.customLLMModel = "   "

        let reloaded = SelfKeyPreferences(defaults: d)
        XCTAssertNil(reloaded.customLLMBaseURL)
        XCTAssertEqual(reloaded.customLLMModel, "local-model")
    }
}
