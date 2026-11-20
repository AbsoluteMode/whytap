import XCTest
@testable import Sidekey

final class ModelRegistryTests: XCTestCase {
    func test_registry_recommendations_match_the_spec() {
        let realtime: [AIFeature] = [.dropFast, .dropSmart, .agentVoice, .voiceSearch]
        for feature in realtime {
            XCTAssertEqual(ModelRegistry.recommended(for: feature, kind: .soniox), "stt-rt-v6", "\(feature)")
            XCTAssertEqual(ModelRegistry.recommended(for: feature, kind: .deepgram), "nova-3", "\(feature)")
            XCTAssertEqual(ModelRegistry.recommended(for: feature, kind: .elevenLabs), "scribe_v3_live", "\(feature)")
        }
        XCTAssertEqual(ModelRegistry.recommended(for: .meetings, kind: .soniox), "stt-async-v6")
        XCTAssertEqual(ModelRegistry.recommended(for: .meetings, kind: .deepgram), "nova-3")
        XCTAssertEqual(ModelRegistry.recommended(for: .meetings, kind: .elevenLabs), "scribe_v3_live")
        for feature: AIFeature in [.dropSmartCleanup, .meetingNotes] {
            XCTAssertEqual(ModelRegistry.recommended(for: feature, kind: .openRouter), "google/gemini-3.8-flash")
        }
        XCTAssertEqual(ModelRegistry.recommended(for: .agent, kind: .openRouter), "anthropic/claude-sonnet-5.5")
        for feature in AIFeature.allCases {
            XCTAssertNil(ModelRegistry.recommended(for: feature, kind: .openAICompatible), "\(feature)")
        }
    }

    func test_registry_models_and_verification() {
        XCTAssertTrue(ModelRegistry.isVerified("stt-rt-v6", kind: .soniox, use: .realtimeSTT))
        XCTAssertFalse(ModelRegistry.isVerified("stt-rt-v6", kind: .soniox, use: .asyncSTT))
        XCTAssertTrue(ModelRegistry.isVerified("stt-async-v6", kind: .soniox, use: .asyncSTT))
        XCTAssertTrue(ModelRegistry.isVerified("nova-3", kind: .deepgram, use: .realtimeSTT))
        XCTAssertTrue(ModelRegistry.isVerified("scribe_v3", kind: .elevenLabs, use: .asyncSTT))
        XCTAssertTrue(ModelRegistry.isVerified("scribe_v3_live", kind: .elevenLabs, use: .realtimeSTT))
        // Scribe v2 was replaced, not kept beside v3.
        XCTAssertFalse(ModelRegistry.isVerified("scribe_v2", kind: .elevenLabs, use: .asyncSTT))
        XCTAssertFalse(ModelRegistry.isVerified("scribe_v2_realtime", kind: .elevenLabs, use: .realtimeSTT))
        XCTAssertTrue(ModelRegistry.isVerified("anthropic/claude-sonnet-5.5", kind: .openRouter, use: .chatWithTools))
        XCTAssertFalse(ModelRegistry.isVerified("google/gemini-3.8-flash", kind: .openRouter, use: .chatWithTools))
        XCTAssertFalse(ModelRegistry.isVerified("nova-3", kind: .soniox, use: .realtimeSTT))
        XCTAssertEqual(ModelRegistry.models.filter(\.diarization).map(\.id), ["stt-async-v6"])
        XCTAssertEqual(ModelRegistry.adapterVersion(.soniox, .realtimeSTT), 1)
        XCTAssertEqual(ModelRegistry.meetingNotesMinContext, 64_000)
        XCTAssertEqual(ModelRegistry.agentMinContext, 64_000)
    }

    func test_flux_is_known_unsupported_for_deepgram_only() {
        XCTAssertEqual(
            ModelRegistry.knownUnsupportedReason("flux-general-en", kind: .deepgram, use: .realtimeSTT),
            "needs Deepgram's v2 streaming API")
        XCTAssertNil(ModelRegistry.knownUnsupportedReason("nova-3", kind: .deepgram, use: .realtimeSTT))
        XCTAssertNil(ModelRegistry.knownUnsupportedReason("flux-general-en", kind: .openAICompatible, use: .realtimeSTT))
    }
}
