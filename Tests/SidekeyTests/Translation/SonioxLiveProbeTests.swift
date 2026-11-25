import Foundation
@testable import Sidekey
import XCTest

/// Live check of the Soniox Subtitles adapter against the real service.
/// Skipped unless `WHYTAP_SONIOX_LIVE_PCM` names a 24 kHz PCM16 mono file and
/// `SONIOX_API_KEY` is set (run it through Case, never with a key in a file).
/// It streams the file at real speed through `SonioxRealtimeTranslateAdapter`
/// and `SubtitleSpeechPairer`, polls what the overlay would show every
/// 250 ms (the model's flush timer) and at every event, and writes the
/// events, the screen timeline and the pairs with their times to
/// `WHYTAP_SONIOX_LIVE_OUT` (default: the temporary folder).
/// About $0.002 per minute of audio.
final class SonioxLiveProbeTests: XCTestCase {
    private actor Screen {
        let started = Date()
        var pairer = SubtitleSpeechPairer()
        var settledSource: [String] = []
        var settledTranslation: [String] = []
        var log: [[String: Any]] = []
        var timeline: [[String: Any]] = []
        var lastScreen = ("", "")

        init(streamingPreview: Bool) { pairer = SubtitleSpeechPairer(streamingPreview: streamingPreview) }

        var now: TimeInterval { Date().timeIntervalSince(started) }

        func record(_ event: SpeechTranslationEvent) {
            let at = Int(now * 1_000)
            switch event {
            case .source(let text, let elapsed):
                pairer.addSource(text, elapsedMs: elapsed)
                log.append(["at": at, "kind": "source", "text": text, "elapsed": elapsed ?? -1])
            case .translation(let text, let elapsed):
                pairer.addTranslation(text, elapsedMs: elapsed, now: now)
                log.append(["at": at, "kind": "translation", "text": text, "elapsed": elapsed ?? -1])
            case .sourcePreview(let text):
                pairer.setPreview(text)
                log.append(["at": at, "kind": "preview", "text": text])
            case .closed:
                log.append(["at": at, "kind": "closed"])
            case .failed(let failure):
                log.append(["at": at, "kind": "failed", "failure": "\(failure)"])
            }
            flush(force: false)
        }

        func flush(force: Bool) {
            for pair in pairer.take(now: now, force: force) {
                settledSource.append(pair.source)
                settledTranslation.append(pair.translation)
            }
            let row = pairer.showLive(now: now)
            let screen = ((settledSource + [row.source]).joined(separator: " "),
                          (settledTranslation + [row.translation]).joined(separator: " "))
            if screen != lastScreen {
                lastScreen = screen
                timeline.append(["at": Int(now * 1_000), "source": screen.0, "translation": screen.1])
            }
        }

        func report(audioEnd: Int, accepted: Double) -> [String: Any] {
            ["audio_end_ms": audioEnd, "accepted_seconds": accepted, "events": log, "screen": timeline,
             "pairs": zip(settledSource, settledTranslation).map { ["source": $0, "translation": $1] }]
        }
    }

    func testStreamsARecordingThroughSoniox() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WHYTAP_SONIOX_LIVE_PCM"], let key = environment["SONIOX_API_KEY"], !key.isEmpty else {
            throw XCTSkip("set WHYTAP_SONIOX_LIVE_PCM and SONIOX_API_KEY to run the live probe")
        }
        let pcm = try Data(contentsOf: URL(fileURLWithPath: path))
        let session = try await SonioxRealtimeTranslateAdapter(apiKey: key).open(source: "en", target: environment["WHYTAP_SONIOX_LIVE_TARGET"] ?? "ru")
        // As `LiveSubtitleModel`; WHYTAP_SONIOX_LIVE_FINAL_ONLY=1 replays the
        // final-only behavior of build 1761 for a before/after measurement.
        let screen = Screen(streamingPreview: environment["WHYTAP_SONIOX_LIVE_FINAL_ONLY"] == nil
            && session.streamsOriginalPreview)
        let reader = Task {
            for await event in session.events { await screen.record(event) }
            await screen.flush(force: true)
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await screen.flush(force: false)
            }
        }
        let started = await screen.started
        // 100 ms chunks at real speed, as the capture delivers them.
        let chunk = 4_800
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunk, pcm.count)
            await session.sendAudio(pcm.subdata(in: offset..<end))
            offset = end
            let wait = started.addingTimeInterval(Double(offset) / 48_000).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1_000))) }
        }
        let endedAt = Int(Date().timeIntervalSince(started) * 1_000)
        await session.endInput()
        await reader.value
        ticker.cancel()
        let report = await screen.report(audioEnd: endedAt, accepted: session.acceptedAudioSeconds())
        let output = URL(fileURLWithPath: environment["WHYTAP_SONIOX_LIVE_OUT"]
            ?? NSTemporaryDirectory() + "soniox-live-probe.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        let events = (report["events"] as? [[String: Any]]) ?? []
        XCTAssertEqual(events.last?["kind"] as? String, "closed", "the session ends with finished")
        XCTAssertFalse(((report["pairs"] as? [[String: String]]) ?? []).isEmpty)
    }
}
