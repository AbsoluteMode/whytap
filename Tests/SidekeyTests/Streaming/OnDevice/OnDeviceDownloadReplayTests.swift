import XCTest
@testable import Sidekey

/// The owner's acceptance failure: the bar jumped from 4% to 97% and the card
/// said "99% of about 470 MB · About 1157 min left". These tests replay the
/// progress callbacks recorded from real downloads (`RecordedModelDownloads`)
/// through what the card shows, with the clock ticking between callbacks as
/// the controller's timer does.
// WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
final class OnDeviceDownloadReplayTests: XCTestCase {
    private struct Frame {
        let time: Double
        let fraction: Double
        let timeLeft: OnDeviceSpeechTimeLeft
    }

    /// Feeds `points` (seconds, fraction) and reads the time left at every
    /// callback and every half second between them.
    private func replay(_ points: [(Double, Double)], tickUntil end: Double? = nil) -> [Frame] {
        var rate = OnDeviceDownloadRateEstimator()
        var frames: [Frame] = []
        var shown = 0.0
        let last = end ?? (points.last?.0 ?? 0)
        var index = 0
        var clock = points.first?.0 ?? 0
        while clock <= last + 1e-9 {
            while index < points.count, points[index].0 <= clock + 1e-9 {
                rate.record(fraction: points[index].1, at: points[index].0)
                shown = max(shown, points[index].1)
                index += 1
            }
            frames.append(Frame(time: clock, fraction: shown, timeLeft: rate.timeLeft(at: clock)))
            clock += 0.5
        }
        return frames
    }

    private func fractions(_ rows: [(time: Double, bytes: Int64)]) -> [(Double, Double)] {
        rows.map { ($0.time, Double($0.bytes) / Double(RecordedModelDownloads.totalBytes)) }
    }

    private func percent(_ fraction: Double) -> Int { OnDeviceSpeechCard.Presentation.percent(fraction) }

    // MARK: - The defect, as recorded

    func test_fluidaudio_reports_only_whole_files_so_the_bar_jumps_from_4_to_97() {
        // Our mapping of FluidAudio's 0...0.5 download range.
        let shown = RecordedModelDownloads.fluidAudio.map { percent(min(1, $0.raw * 2)) }
        let steps = zip(shown, shown.dropFirst()).map { $1 - $0 }
        XCTAssertEqual(shown.firstIndex(of: 97).map { shown[$0 - 1] }, 4, "4% straight to 97%")
        XCTAssertGreaterThan(steps.max() ?? 0, 90)
        // 12.8 s of the 34 s download had no callback at all.
        let times = RecordedModelDownloads.fluidAudio.map(\.time)
        XCTAssertGreaterThan(zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0, 12)
    }

    func test_even_the_fluidaudio_sequence_never_produces_an_absurd_time() {
        let frames = replay(RecordedModelDownloads.fluidAudio.map { ($0.time, min(1, $0.raw * 2)) })
        for frame in frames {
            if case .seconds(let seconds) = frame.timeLeft {
                XCTAssertLessThan(seconds, 120, "at \(frame.time) s, \(percent(frame.fraction))%")
            }
            if frame.fraction >= 0.98 { XCTAssertEqual(frame.timeLeft, .almostDone) }
        }
    }

    // MARK: - Whytap's downloader, as recorded

    func test_our_downloader_moves_the_bar_with_the_bytes() {
        let rows = RecordedModelDownloads.clean
        XCTAssertEqual(rows.last?.bytes, RecordedModelDownloads.totalBytes)
        let shown = fractions(rows).map(\.1)
        XCTAssertEqual(shown, shown.sorted(), "never moves back")
        let steps = zip(shown, shown.dropFirst()).map { $1 - $0 }
        XCTAssertLessThan(steps.max() ?? 1, 0.02, "no step above 2% on a 35 MB/s connection")
        let times = rows.map(\.time).drop { $0 < 4 }
        XCTAssertLessThan(zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 99, 1.5,
                          "a callback at least every 1.5 s once bytes flow")
    }

    func test_clean_download_time_left_appears_and_stays_close_to_the_real_remaining_time() {
        let rows = fractions(RecordedModelDownloads.clean)
        let end = rows.last!.0
        let frames = replay(rows, tickUntil: end + 0.5)
        let firstNumber = frames.first { if case .seconds = $0.timeLeft { return true }; return false }
        XCTAssertNotNil(firstNumber)
        XCTAssertLessThan(firstNumber!.time, 10, "a number within a few seconds of the first bytes")
        for frame in frames {
            switch frame.timeLeft {
            case .seconds(let seconds):
                let actual = end - frame.time
                XCTAssertLessThan(seconds, max(15, actual * 3), "at \(frame.time) s")
            case .stalled:
                XCTFail("no stall in a flowing download at \(frame.time) s")
            default:
                break
            }
        }
        XCTAssertEqual(frames.last?.timeLeft, .almostDone)
        let text = OnDeviceSpeechCard.Presentation(.downloading(frames.last!.fraction), timeLeft: frames.last!.timeLeft)
        XCTAssertEqual(text.detail, "100% of about 470 MB · Almost done")
    }

    func test_cached_files_count_from_the_start_and_are_not_taken_as_speed() {
        let rows = fractions(RecordedModelDownloads.cached)
        XCTAssertGreaterThan(rows.first!.1, 0.07, "the files in place are counted at once")
        let end = rows.last!.0
        for frame in replay(rows) {
            if case .seconds(let seconds) = frame.timeLeft {
                XCTAssertLessThan(seconds, max(15, (end - frame.time) * 3), "at \(frame.time) s")
            }
        }
    }

    func test_a_stall_hides_the_number_and_it_returns_with_bytes() {
        // The clean download with 20 s without data in the middle.
        let rows = fractions(RecordedModelDownloads.clean)
        let cut = rows.firstIndex { $0.1 > 0.5 }!
        let stalled = rows[..<cut] + rows[cut...].map { ($0.0 + 20, $0.1) }
        let frames = replay(Array(stalled))
        let pause = rows[cut - 1].0
        XCTAssertTrue(frames.contains { $0.time > pause + 9 && $0.time < pause + 20 && $0.timeLeft == .stalled })
        XCTAssertTrue(frames.contains {
            if case .seconds = $0.timeLeft { return $0.time > pause + 22 }; return false
        }, "back to a number once bytes arrive")
        XCTAssertEqual(OnDeviceSpeechCard.Presentation(.downloading(0.5), timeLeft: .stalled).detail,
                       "50% of about 470 MB · Stalled. Check your connection.")
    }

    func test_a_slow_tail_never_grows_into_nonsense() {
        // The recorded download, with its last 10% a hundred times slower.
        let rows = fractions(RecordedModelDownloads.clean)
        let slowFrom = rows.firstIndex { $0.1 > 0.9 }!
        let start = rows[slowFrom].0
        let slow = rows[..<slowFrom] + rows[slowFrom...].map { (start + ($0.0 - start) * 100, $0.1) }
        let frames = replay(Array(slow))
        for frame in frames {
            if case .seconds(let seconds) = frame.timeLeft {
                XCTAssertLessThanOrEqual(seconds, 2 * 3600, "at \(frame.time) s")
            }
            if frame.fraction >= 0.98 { XCTAssertEqual(frame.timeLeft, .almostDone, "at \(frame.time) s") }
        }
    }

    func test_the_first_seconds_show_no_number() {
        let frames = replay(fractions(RecordedModelDownloads.clean))
        let start = frames.first!.time
        for frame in frames where frame.time < start + 4 {
            XCTAssertEqual(frame.timeLeft, .estimating, "at \(frame.time) s")
        }
        XCTAssertEqual(OnDeviceSpeechCard.Presentation(.downloading(0), timeLeft: .estimating).detail,
                       "Starting… about 470 MB. You can leave this tab.")
    }
}
