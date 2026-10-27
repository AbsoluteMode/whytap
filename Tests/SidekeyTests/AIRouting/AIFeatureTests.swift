import XCTest
@testable import Sidekey

/// The feature registry and the account identity types behind API & Models.
/// Feature raw values and account storage IDs are persisted (route keys and
/// values in `AIRoutingStore`), so these tests pin the exact strings.
final class AIFeatureTests: XCTestCase {

    private let serverID = UUID(uuidString: "5B2F3C1E-9A4D-4E7B-8C21-0D6F7A8B9C10")!
    private let serverStorageID = "server:5b2f3c1e-9a4d-4e7b-8c21-0d6f7a8b9c10"

    // MARK: - Registry

    func test_features_follow_the_spec_table() {
        XCTAssertEqual(AIFeature.activeCases, [.dropFast, .dropSmart, .dropSmartCleanup, .meetings, .meetingNotes, .agent, .agentVoice, .meetingAssistant, .meetingAssistantAudio, .meetingAssistantDetector, .voiceSearch, .translation, .subtitlesAudio, .subtitlesTranslation])
        XCTAssertEqual(AIFeature.activeCases.map(\.title), ["Drop Fast", "Drop Smart", "Drop Smart cleanup", "Meetings", "Meeting notes", "Agent", "Agent voice", "Meeting Assistant", "Meeting Assistant audio", "Meeting Assistant detector", "Voice search", "Translation", "Subtitles audio", "Subtitles translation"])
        XCTAssertEqual(AIFeature.activeCases.map(\.mode.label), ["real-time", "real-time", "LLM", "recorded", "LLM", "LLM with tools", "real-time", "LLM with tools", "real-time", "Decision", "real-time", "LLM", "real-time", "LLM"])
        XCTAssertEqual(AIFeature.drop(.fast), .dropFast)
        XCTAssertEqual(AIFeature.drop(.smart), .dropSmart)
    }

    func test_feature_raw_values_are_the_persisted_route_keys() {
        XCTAssertEqual(
            AIFeature.allCases.map(\.rawValue),
            ["dropFast", "dropSmart", "dropSmartCleanup", "dropSmartDecision", "meetings", "meetingNotes", "agent", "agentVoice", "meetingAssistant", "meetingAssistantAudio", "meetingAssistantDetector", "voiceSearch", "translation", "subtitlesAudio", "subtitlesTranslation"]
        )
    }

    func test_provider_kinds_carry_their_ui_names() {
        XCTAssertEqual(AIProviderKind.allCases, [.soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic, .openAICompatible])
        XCTAssertEqual(
            AIProviderKind.allCases.map(\.displayName),
            ["Soniox", "Deepgram", "ElevenLabs", "OpenRouter", "OpenAI", "Anthropic", "OpenAI-compatible server"]
        )
    }

    // MARK: - Feature x provider table

    /// One row of the spec table: the features that share it and what each
    /// provider column holds (`nil` — the provider cannot serve the feature).
    private struct TableRow {
        let features: [AIFeature]
        let soniox, deepgram, elevenLabs, openRouter, anthropic, openAICompatible: ModelUse?

        func use(on kind: AIProviderKind) -> ModelUse? {
            switch kind {
            case .soniox: return soniox
            case .deepgram: return deepgram
            case .elevenLabs: return elevenLabs
            case .openRouter: return openRouter
            case .openAI: return openRouter
            case .anthropic: return anthropic
            case .openAICompatible: return openAICompatible
            }
        }
    }

    func test_model_use_matches_the_provider_table() {
        let rows = [
            TableRow(
                features: [.dropFast, .dropSmart, .agentVoice, .meetingAssistantAudio, .voiceSearch, .subtitlesAudio],
                soniox: .realtimeSTT, deepgram: .realtimeSTT, elevenLabs: .realtimeSTT,
                openRouter: nil, anthropic: nil, openAICompatible: .realtimeSTT
            ),
            TableRow(
                features: [.meetings],
                soniox: .asyncSTT, deepgram: .realtimeSTT, elevenLabs: .realtimeSTT,
                openRouter: nil, anthropic: nil, openAICompatible: .realtimeSTT
            ),
            TableRow(
                features: [.dropSmartCleanup, .meetingNotes, .translation, .subtitlesTranslation],
                soniox: nil, deepgram: nil, elevenLabs: nil,
                openRouter: .chat, anthropic: .chat, openAICompatible: .chat
            ),
            TableRow(
                features: [.agent, .meetingAssistant],
                soniox: nil, deepgram: nil, elevenLabs: nil,
                openRouter: .chatWithTools, anthropic: .chatWithTools, openAICompatible: nil
            ),
            TableRow(
                features: [.meetingAssistantDetector],
                soniox: nil, deepgram: nil, elevenLabs: nil,
                openRouter: .decision, anthropic: nil, openAICompatible: nil
            ),
        ]
        // Every feature sits in exactly one row, so the loop below visits all
        // 14 active features x 7 providers = 98 cells.
        XCTAssertEqual(
            rows.flatMap(\.features).map(\.rawValue).sorted(),
            AIFeature.activeCases.map(\.rawValue).sorted()
        )

        var visited = 0
        for row in rows {
            for feature in row.features {
                for kind in AIProviderKind.allCases {
                    XCTAssertEqual(
                        feature.modelUse(on: kind), row.use(on: kind),
                        "\(feature.rawValue) on \(kind.rawValue)"
                    )
                    visited += 1
                }
            }
        }
        XCTAssertEqual(visited, 98)
    }

    func test_direct_llm_providers_are_available_for_all_text_modes_only() {
        for kind in [AIProviderKind.openAI, .anthropic] {
            for feature in AIFeature.activeCases {
                let expected: ModelUse? = feature.mode == .llm ? .chat
                    : (feature.mode == .llmWithTools ? .chatWithTools
                       : (kind == .openAI && feature.mode == .decision ? .decision : nil))
                XCTAssertEqual(feature.modelUse(on: kind), expected, feature.rawValue)
            }
        }
    }

    // MARK: - ProviderAccount

    func test_account_maps_to_its_provider_kind_and_storage_id() {
        let expected: [(account: ProviderAccount, kind: AIProviderKind, storageID: String)] = [
            (.soniox, .soniox, "soniox"),
            (.deepgram, .deepgram, "deepgram"),
            (.elevenLabs, .elevenLabs, "elevenLabs"),
            (.openRouter, .openRouter, "openRouter"),
            (.openAI, .openAI, "openAI"),
            (.anthropic, .anthropic, "anthropic"),
            (.server(serverID), .openAICompatible, serverStorageID),
        ]
        for entry in expected {
            XCTAssertEqual(entry.account.kind, entry.kind)
            XCTAssertEqual(entry.account.storageID, entry.storageID)
            XCTAssertEqual(ProviderAccount(storageID: entry.storageID), entry.account)
        }
    }

    func test_unknown_storage_ids_do_not_parse() {
        let unknown = [
            "", " ", "Soniox", "DEEPGRAM", "elevenlabs", "openrouter", "openAICompatible",
            "server", "server:", "servers:5b2f3c1e-9a4d-4e7b-8c21-0d6f7a8b9c10",
            "server:not-a-uuid", "server:5b2f3c1e9a4d4e7b8c210d6f7a8b9c10",
            " \(serverStorageID)", "\(serverStorageID) ",
            // One account, one spelling: the storage ID uses a lower-case UUID.
            "server:5B2F3C1E-9A4D-4E7B-8C21-0D6F7A8B9C10",
        ]
        for raw in unknown {
            XCTAssertNil(ProviderAccount(storageID: raw), "\"\(raw)\" must not parse")
        }
    }

    func test_account_encodes_as_one_storage_id_string() throws {
        let data = try JSONEncoder().encode([ProviderAccount.soniox, .openRouter, .server(serverID)])
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"["soniox","openRouter","\#(serverStorageID)"]"#
        )
    }

    func test_account_decodes_from_a_storage_id_string() throws {
        let json = #"["deepgram","\#(serverStorageID)"]"#
        let accounts = try JSONDecoder().decode([ProviderAccount].self, from: Data(json.utf8))
        XCTAssertEqual(accounts, [.deepgram, .server(serverID)])
    }

    func test_decoding_an_unknown_account_is_a_decoding_error() {
        for json in [#"["whisper"]"#, #"["server:not-a-uuid"]"#, #"[7]"#, #"[{"soniox":{}}]"#] {
            XCTAssertThrowsError(
                try JSONDecoder().decode([ProviderAccount].self, from: Data(json.utf8)), json
            ) { error in
                XCTAssertTrue(error is DecodingError, "\(json) threw \(error)")
            }
        }
    }

    // MARK: - ServerEndpoint

    func test_server_endpoint_round_trips_through_json() throws {
        let server = ServerEndpoint(
            id: serverID, name: "Home GPU", baseURL: "http://gpu.local:8000/v1",
            keyAccount: "byok.selfHosted.api_key"
        )
        let decoded = try JSONDecoder().decode(ServerEndpoint.self, from: JSONEncoder().encode(server))
        XCTAssertEqual(decoded, server)
        XCTAssertEqual(decoded.id, serverID)
    }
}
