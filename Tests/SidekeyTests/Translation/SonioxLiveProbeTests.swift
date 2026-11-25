import Foundation
@testable import Sidekey
import XCTest

/// Live check of the Soniox Subtitles adapter against the real service.
/// Skipped unless `WHYTAP_SONIOX_LIVE_PCM` names a 24 kHz PCM16 mono file and
/// `SONIOX_API_KEY` is set (run it through Case, never with a key in a file).
/// It streams the file at real speed through `SonioxRealtimeTranslateAdapter`
/// and `SubtitleSpeechPairer`, and writes the events and pairs with their
/// arrival times to `WHYTAP_SONIOX_LIVE_OUT` (default: the temporary folder).
/// About $0.002 per minute of audio.
final class SonioxLiveProbeTests: XCTestCase {
    func testStreamsARecordingThroughSoniox() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WHYTAP_SONIOX_LIVE_PCM"], let key = environment["SONIOX_API_KEY"], !key.isEmpty else {
            throw XCTSkip("set WHYTAP_SONIOX_LIVE_PCM and SONIOX_API_KEY to run the live probe")
        }
        let pcm = try Data(contentsOf: URL(fileURLWithPath: path))
        let session = try await SonioxRealtimeTranslateAdapter(apiKey: key).open(source: "en", target: environment["WHYTAP_SONIOX_LIVE_TARGET"] ?? "ru")
        let started = Date()
        let reader = Task { () -> [[String: Any]] in
            var log: [[String: Any]] = []
            var pairer = SubtitleSpeechPairer()
            var pairs: [[String: Any]] = []
            for await event in session.events {
                let at = Int(Date().timeIntervalSince(started) * 1_000)
                switch event {
                case .source(let text, let elapsed):
                    pairer.addSource(text, elapsedMs: elapsed)
                    log.append(["at": at, "kind": "source", "text": text, "elapsed": elapsed ?? -1])
                case .translation(let text, let elapsed):
                    pairer.addTranslation(text, elapsedMs: elapsed, now: Date().timeIntervalSince(started))
                    log.append(["at": at, "kind": "translation", "text": text, "elapsed": elapsed ?? -1])
                case .closed:
                    log.append(["at": at, "kind": "closed"])
                case .failed(let failure):
                    log.append(["at": at, "kind": "failed", "failure": "\(failure)"])
                }
                for pair in pairer.take(now: Date().timeIntervalSince(started)) {
                    pairs.append(["at": at, "source": pair.source, "translation": pair.translation])
                }
            }
            for pair in pairer.take(now: Date().timeIntervalSince(started), force: true) {
                pairs.append(["at": Int(Date().timeIntervalSince(started) * 1_000), "source": pair.source,
                              "translation": pair.translation])
            }
            return log + [["kind": "pairs", "pairs": pairs]]
        }
        // 100 ms chunks at real speed, as the capture delivers them.
        let chunk = 4_800
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunk, pcm.count)
            await session.sendAudio(pcm.subdata(in: offset..<end))
            offset = end
            let due = started.addingTimeInterval(Double(offset) / 48_000)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1_000))) }
        }
        let endedAt = Int(Date().timeIntervalSince(started) * 1_000)
        await session.endInput()
        let log = await reader.value
        let output = URL(fileURLWithPath: environment["WHYTAP_SONIOX_LIVE_OUT"]
            ?? NSTemporaryDirectory() + "soniox-live-probe.json")
        let report: [String: Any] = ["audio_end_ms": endedAt, "accepted_seconds": session.acceptedAudioSeconds(), "events": log]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        XCTAssertEqual(log.dropLast().last?["kind"] as? String, "closed", "the session ends with finished")
        let pairs = (log.last?["pairs"] as? [[String: Any]]) ?? []
        XCTAssertFalse(pairs.isEmpty)
    }
}
