import Foundation
@testable import Sidekey
import XCTest

/// A paid live check of OpenAI `gpt-realtime-translate`, off by default. It
/// streams a raw 16 kHz PCM16 file at real speed and writes every event with
/// its arrival time as JSON lines (texts included: the file is synthetic
/// speech). Run through Case so the key never appears:
///   whytap case run --only OPENAI_API_KEY 'WHYTAP_TRANSLATE_PROBE_PCM=… \
///     WHYTAP_TRANSLATE_PROBE_OUT=… swift test --filter SpeechTranslationLiveProbeTests'
final class SpeechTranslationLiveProbeTests: XCTestCase {
    func testLiveTranslationProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let pcmPath = environment["WHYTAP_TRANSLATE_PROBE_PCM"], let output = environment["WHYTAP_TRANSLATE_PROBE_OUT"],
              let key = environment["OPENAI_API_KEY"] ?? environment["WHYTAP_TRANSLATE_PROBE_KEY"] else {
            throw XCTSkip("Set WHYTAP_TRANSLATE_PROBE_PCM, WHYTAP_TRANSLATE_PROBE_OUT and a key for the paid live probe.")
        }
        let target = environment["WHYTAP_TRANSLATE_PROBE_TARGET"] ?? "ru"
        var lines: [String] = []
        let begin = Date()
        func log(_ object: [String: Any]) {
            var object = object
            object["t"] = (Date().timeIntervalSince(begin) * 1000).rounded()
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                lines.append(String(decoding: data, as: UTF8.self))
            }
        }
        defer { try? lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8) }
        let session: SpeechTranslationSession
        do {
            session = try await OpenAIRealtimeTranslateAdapter(apiKey: key).open(target: target)
        } catch {
            log(["type": "open_failed", "error": String(describing: error)])
            return
        }
        log(["type": "opened"])
        let pcm = try Data(contentsOf: URL(fileURLWithPath: pcmPath))
        let collector = Task {
            for await event in session.events {
                switch event {
                case .source(let text, let elapsed): log(["type": "source", "text": text, "elapsed": elapsed ?? -1])
                case .translation(let text, let elapsed): log(["type": "translation", "text": text, "elapsed": elapsed ?? -1])
                case .closed: log(["type": "closed"])
                case .failed(let failure): log(["type": "failed", "error": String(describing: failure)])
                }
            }
        }
        let chunk = 3_200 // 100 ms at 16 kHz
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunk, pcm.count)
            await session.sendAudio(pcm.subdata(in: offset..<end))
            offset = end
            try await Task.sleep(for: .milliseconds(100))
        }
        // Trailing silence like a video's pause, then finish.
        for _ in 0..<20 {
            await session.sendAudio(Data(count: chunk))
            try await Task.sleep(for: .milliseconds(100))
        }
        log(["type": "end_input"])
        await session.endInput()
        let deadline = Task { try? await Task.sleep(for: .seconds(15)); await session.close() }
        await collector.value
        deadline.cancel()
        log(["type": "accepted_seconds", "value": session.acceptedAudioSeconds()])
        await session.close()
    }
}
