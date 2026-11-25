import Foundation
@testable import Sidekey
import XCTest

/// A paid live check of OpenAI `gpt-realtime-translate`, off by default. It
/// takes a raw 48 kHz mono PCM16 file (the system mix's rate), sends it at
/// real speed in Core Audio's 512-frame callbacks through a capture path, and
/// writes every event with its arrival time as JSON lines (texts included:
/// the file is synthetic speech). Run through Case so the key never appears:
///   whytap case run --only OPENAI_API_KEY 'WHYTAP_TRANSLATE_PROBE_PCM=… \
///     WHYTAP_TRANSLATE_PROBE_OUT=… swift test --filter SpeechTranslationLiveProbeTests'
/// `WHYTAP_TRANSLATE_PROBE_PATH=old` sends what builds before 2026-11-23 sent
/// (16 kHz without a low-pass, upsampled per callback); the default is the
/// Subtitles capture now (low-pass, 24 kHz). `WHYTAP_TRANSLATE_PROBE_TRANSCRIPTION=0`
/// turns the original's transcript off. Comparing runs shows what each costs
/// the translation.
// WHY: .project-docs/decisions/2026-11-23-subtitle-realtime-audio.md
final class SpeechTranslationLiveProbeTests: XCTestCase {
    func testLiveTranslationProbe() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let pcmPath = environment["WHYTAP_TRANSLATE_PROBE_PCM"], let output = environment["WHYTAP_TRANSLATE_PROBE_OUT"],
              let key = environment["OPENAI_API_KEY"] ?? environment["WHYTAP_TRANSLATE_PROBE_KEY"] else {
            throw XCTSkip("Set WHYTAP_TRANSLATE_PROBE_PCM, WHYTAP_TRANSLATE_PROBE_OUT and a key for the paid live probe.")
        }
        let target = environment["WHYTAP_TRANSLATE_PROBE_TARGET"] ?? "ru"
        let oldPath = environment["WHYTAP_TRANSLATE_PROBE_PATH"] == "old"
        let transcribes = environment["WHYTAP_TRANSLATE_PROBE_TRANSCRIPTION"] != "0"
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
            var adapter = OpenAIRealtimeTranslateAdapter(apiKey: key)
            adapter.transcribesInput = transcribes
            session = try await adapter.open(target: target)
        } catch {
            log(["type": "open_failed", "error": String(describing: error)])
            return
        }
        log(["type": "opened", "path": oldPath ? "old" : "clean", "transcription": transcribes])
        let pcm = try Data(contentsOf: URL(fileURLWithPath: pcmPath))
        let collector = Task {
            for await event in session.events {
                switch event {
                case .source(let text, let elapsed): log(["type": "source", "text": text, "elapsed": elapsed ?? -1])
                case .translation(let text, let elapsed): log(["type": "translation", "text": text, "elapsed": elapsed ?? -1])
                case .sourcePreview, .translationPiece, .update: break
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
        let input: [Float] = (pcm + Data(count: 96_000 * 2)) // 2 s of trailing silence, like a video's pause
            .withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Float($0) / 32_768 }
        var filter = SystemAudioAntiAliasFilter(targetSampleRate: 24_000)
        var resampler = SystemAudioStreamingResampler(targetSampleRate: oldPath ? 16_000 : 24_000)
        func captured(_ callback: [Float]) -> Data {
            if oldPath {
                return OpenAIRealtimeSession.upsample16kTo24k(SubtitleSegmenter.pcm16(resampler.process(callback, sourceSampleRate: 48_000)))
            }
            return SubtitleSegmenter.pcm16(resampler.process(filter.process(callback, sourceSampleRate: 48_000), sourceSampleRate: 48_000))
        }
        let streamStart = ProcessInfo.processInfo.systemUptime
        log(["type": "audio_start"])
        var offset = 0
        var index = 0
        while offset < input.count {
            let due = streamStart + Double(index) * 0.1
            let wait = due - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1_000))) }
            let end = min(offset + 4_800, input.count) // 100 ms at 48 kHz, as callbacks of 512 frames
            var start = offset
            while start < end {
                let stop = min(start + 512, end)
                await session.sendAudio(captured(Array(input[start..<stop])))
                start = stop
            }
            sentLock.withLock { sentMs = end / 48 }
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
