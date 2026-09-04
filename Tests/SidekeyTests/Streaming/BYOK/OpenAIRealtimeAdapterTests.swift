import XCTest
@testable import Sidekey

@MainActor
final class OpenAIRealtimeAdapterTests: XCTestCase {
    func testOpenSendsTranscriptionConfigWithModelLanguagePrompt() async throws {
        let stub = StubWebSocketTransport()
        let adapter = OpenAIRealtimeAdapter(model: "gpt-4o-transcribe") { stub }
        _ = try await adapter.open(language: "ru", terms: ["Whytap"])
        // First frame is the session config (text/JSON).
        // StubWebSocketTransport stores sent frames in `stub.sent` as [Sent]
        // where Sent is .text(String) or .data(Data).
        guard case .text(let json)? = stub.sent.first else { return XCTFail("no config frame") }
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let session = obj["session"] as! [String: Any]
        let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
        let format = input["format"] as! [String: Any]
        let tx = input["transcription"] as! [String: Any]
        // OpenAI Realtime GA transcription shape.
        XCTAssertEqual(obj["type"] as? String, "session.update")
        XCTAssertEqual(session["type"] as? String, "transcription")
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        XCTAssertEqual(tx["model"] as? String, "gpt-4o-transcribe")
        XCTAssertEqual(tx["language"] as? String, "ru")
        XCTAssertEqual(tx["prompt"] as? String, "Whytap")
    }

    func testSendAudioAppendsBase64AndCommitOnEnd() async throws {
        let stub = StubWebSocketTransport()
        let adapter = OpenAIRealtimeAdapter(model: "m") { stub }
        let session = try await adapter.open(language: nil, terms: [])
        await session.sendAudio(Data([0x01, 0x02]))
        await session.endInput()
        // After config: append(base64) then commit.
        // StubWebSocketTransport.sent stores sent frames as [Sent].
        let texts = stub.sent.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
        XCTAssertTrue(texts.contains { $0.contains("input_audio_buffer.append") && $0.contains("\"audio\"") })
        XCTAssertTrue(texts.contains { $0.contains("input_audio_buffer.commit") })
        await session.close()
    }

    func testUpsample16kTo24kProduces3to2Ratio() {
        // 4 input samples (8 bytes) → 6 output samples (12 bytes) at 24/16 = 3/2.
        let input = Data([0, 0, 0x10, 0x27, 0, 0, 0xF0, 0xD8])
        XCTAssertEqual(OpenAIRealtimeSession.upsample16kTo24k(input).count, 12)
    }

    func testEventsNormalizedDeltaThenCompleted() async throws {
        let stub = StubWebSocketTransport()
        let adapter = OpenAIRealtimeAdapter(model: "m") { stub }
        let session = try await adapter.open(language: nil, terms: [])
        // StubWebSocketTransport delivers inbound frames via deliverText(_:).
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"he"}"#)
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"hello"}"#)
        var got: [BYOKStreamEvent] = []
        for await ev in session.events {
            got.append(ev)
            if case .done = ev { break }
        }
        XCTAssertTrue(got.contains(.partial("he")))
        XCTAssertEqual(got.last, .done("hello"))
        await session.close()
    }
}
