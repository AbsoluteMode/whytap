import AppKit
import Combine
@testable import Sidekey
import XCTest

/// Opt-in measurement (WHYTAP_SUBTITLE_DISPLAY_PROBE=<seconds>): the recorded
/// session replayed back to back at real speed through the real overlay panel
/// (off screen), measuring how late the main thread runs and how long a
/// translation delta takes from arrival to the published caption.
@MainActor
final class SubtitleDisplayLagProbeTests: XCTestCase {
    func testDisplayLagOverALongSession() async throws {
        guard let value = ProcessInfo.processInfo.environment["WHYTAP_SUBTITLE_DISPLAY_PROBE"],
              let seconds = Double(value) else { throw XCTSkip("Set WHYTAP_SUBTITLE_DISPLAY_PROBE=<seconds>.") }
        let speech = FakeSpeechTranslation()
        let model = LiveSubtitleModel(makeAudio: { FixtureSubtitleAudio() }, openTranslator: { _, _ in speech })
        model.sourceCode = "en"; model.targetCode = "ru"
        let controller = TranslationWindowController(
            textModel: TextTranslationModel(makeService: { FixtureTranslator() }), subtitleModel: model,
            defaults: try XCTUnwrap(UserDefaults(suiteName: "display-lag-\(UUID())")),
            openSettings: { _ in }, activityChanged: { _ in })
        controller.presentation.mode = .subtitles
        controller.resize(for: .subtitles)
        controller.window.setFrame(NSRect(x: -20_000, y: -20_000, width: 760, height: 190), display: false)
        controller.window.orderFrontRegardless()
        model.start()
        for _ in 0..<200 where model.phase != .listening { try await Task.sleep(for: .milliseconds(5)) }

        // Translation characters yielded (with time) and shown (with time).
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var yielded: [(chars: Int, at: Double)] = []
        }
        let log = Log()
        let begin = ProcessInfo.processInfo.systemUptime
        var shown: [(chars: Int, at: Double)] = []
        func translatedChars() -> Int {
            model.lines.compactMap(\.translation).map(\.count).reduce(0, +) + model.liveTranslation.count
        }
        let sink = model.objectWillChange.sink { _ in
            DispatchQueue.main.async {
                shown.append((translatedChars(), ProcessInfo.processInfo.systemUptime - begin))
            }
        }
        defer { sink.cancel() }
        // Main-thread lateness: a 50 ms tick, how late it runs.
        var lateness: [(at: Double, late: Double)] = []
        var expected = ProcessInfo.processInfo.systemUptime + 0.05
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated { lateness.append((now - begin, max(0, now - expected))) }
            expected = now + 0.05
        }
        defer { ticker.invalidate() }

        let events = OpenAITranslateRecordedSession.events
        let loop = (events.last?.at ?? 45_000) + 1_000
        let loops = Int((seconds * 1_000 / Double(loop)).rounded(.up))
        let feeder = Task.detached {
            let start = ProcessInfo.processInfo.systemUptime
            var total = 0
            for round in 0..<loops {
                for event in events {
                    let due = Double(round * loop + event.at) / 1_000
                    let wait = due - (ProcessInfo.processInfo.systemUptime - start)
                    if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1_000))) }
                    let elapsed = round * 60_000 + event.elapsed
                    switch event.stream {
                    case .source: speech.pair.continuation.yield(.source(event.text, elapsedMs: elapsed))
                    case .translation:
                        total += event.text.count
                        speech.pair.continuation.yield(.translation(event.text, elapsedMs: elapsed))
                        log.lock.withLock { log.yielded.append((total, ProcessInfo.processInfo.systemUptime - begin)) }
                    }
                }
            }
        }
        await feeder.value
        try await Task.sleep(for: .seconds(2))
        model.cancel()
        controller.window.orderOut(nil)

        // Translation chars are cumulative only while no line was dropped;
        // report per 15 s bucket: main-thread lateness and arrival-to-shown.
        let yielded = log.lock.withLock { log.yielded }
        print("DISPLAY probe \(seconds) s, \(yielded.count) translation deltas, \(shown.count) publishes")
        var bucket = 0.0
        while bucket < seconds + 2 {
            let late = lateness.filter { $0.at >= bucket && $0.at < bucket + 15 }.map(\.late).sorted()
            let p50 = late.isEmpty ? 0 : late[late.count / 2]
            let p95 = late.isEmpty ? 0 : late[Int(Double(late.count) * 0.95)]
            // Arrival to the model's next published change (its queue on the
            // main actor plus pairing), for the deltas of this bucket.
            let waits = yielded.filter { $0.at >= bucket && $0.at < bucket + 15 }.compactMap { delta in
                shown.first { $0.at >= delta.at }.map { $0.at - delta.at }
            }.sorted()
            let w50 = waits.isEmpty ? 0 : waits[waits.count / 2]
            let w95 = waits.isEmpty ? 0 : waits[Int(Double(waits.count) * 0.95)]
            print(String(format: "DISPLAY %3.0f-%3.0f s: main late p50 %.0f ms p95 %.0f ms max %.0f ms; delta to publish p50 %.1f ms p95 %.1f ms max %.1f ms",
                         bucket, bucket + 15, p50 * 1_000, p95 * 1_000, (late.last ?? 0) * 1_000,
                         w50 * 1_000, w95 * 1_000, (waits.last ?? 0) * 1_000))
            bucket += 15
        }
        XCTAssertFalse(yielded.isEmpty)
    }
}
