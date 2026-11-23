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
        let sentLock = NSLock()
        nonisolated(unsafe) var sentMs = 0
        func log(_ object: [String: Any]) {
            var object = object
            object["t"] = (Date().timeIntervalSince(begin) * 1000).rounded()
            object["sent_ms"] = sentLock.withLock { sentMs }
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
        // Real speed on an absolute schedule: chunk n goes out at n x 100 ms
        // after the first, so send time never slows the audio down (the
        // 2026-11-21 recording slept 100 ms after each send and fell about 4 %
        // behind real time). Every event logs how much audio was sent by
        // then, so `sent_ms - elapsed` is how far the model trails its input.
        let chunk = 3_200 // 100 ms at 16 kHz
        let audio = pcm + Data(count: chunk * 20) // trailing silence like a video's pause
        let streamStart = ProcessInfo.processInfo.systemUptime
        log(["type": "audio_start"])
        var offset = 0
        var index = 0
        while offset < audio.count {
            let due = streamStart + Double(index) * 0.1
            let wait = due - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1_000))) }
            let end = min(offset + chunk, audio.count)
            await session.sendAudio(audio.subdata(in: offset..<end))
            sentLock.withLock { sentMs = end / 32 }
            offset = end
            index += 1
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
