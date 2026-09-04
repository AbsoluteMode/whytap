import AppKit
import XCTest
@testable import Sidekey

/// Stage 1 tests for the **pure** NowPlaying mapping/selection layer —
/// the part that turns raw per-player AppleScript fields into a
/// normalized `NowPlayingSnapshot` and picks the active player. No
/// AppleScript runs here: the layer takes raw field structs as input so
/// unit tests can pin the unit normalization (Music seconds vs Spotify
/// milliseconds) and the active-player tie-break without a real player.
///
/// Pinned by the plan's Stage 1 validation gate:
/// - `test_appleMusicFields_mapToSnapshot_inSeconds`
/// - `test_spotifyFields_mapToSnapshot_msNormalizedToSeconds`
/// - `test_activePlayer_prefersPlaying_thenMostRecent`
/// - `test_pausedTrack_producesPausedSnapshot`
final class NowPlayingSourceTests: XCTestCase {

    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Per-app field → snapshot mapping

    func test_appleMusicFields_mapToSnapshot_inSeconds() {
        // Apple Music reports duration and position already in seconds.
        let fields = NowPlayingRawFields(
            app: .music,
            playerState: .playing,
            title: "Karma Police",
            artist: "Radiohead",
            album: "OK Computer",
            durationSeconds: 261.4,
            elapsedSeconds: 42.0,
            artwork: nil
        )

        let snapshot = NowPlayingMapper.snapshot(from: fields, capturedAt: capturedAt)

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.app, .music)
        XCTAssertEqual(snapshot?.title, "Karma Police")
        XCTAssertEqual(snapshot?.artist, "Radiohead")
        XCTAssertEqual(snapshot?.album, "OK Computer")
        XCTAssertEqual(snapshot?.duration ?? 0, 261.4, accuracy: 0.0001)
        XCTAssertEqual(snapshot?.elapsed ?? 0, 42.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot?.isPlaying, true)
        XCTAssertEqual(snapshot?.capturedAt, capturedAt)
    }

    func test_spotifyFields_mapToSnapshot_msNormalizedToSeconds() {
        // Spotify reports duration in MILLISECONDS — `normalizeDuration`
        // must divide by 1000; Music is already in seconds and passes
        // through unchanged. This pins the per-app divisor in the pure
        // layer with RAW inputs, so removing or inverting the divisor fails.
        XCTAssertEqual(
            NowPlayingMapper.normalizeDuration(215_000, for: .spotify),
            215.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NowPlayingMapper.normalizeDuration(261.4, for: .music),
            261.4,
            accuracy: 0.0001
        )
    }

    func test_pausedTrack_producesPausedSnapshot() {
        let fields = NowPlayingRawFields(
            app: .music,
            playerState: .paused,
            title: "Paranoid Android",
            artist: "Radiohead",
            album: "OK Computer",
            durationSeconds: 383.0,
            elapsedSeconds: 100.0,
            artwork: nil
        )

        let snapshot = NowPlayingMapper.snapshot(from: fields, capturedAt: capturedAt)

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.isPlaying, false)
        XCTAssertEqual(snapshot?.title, "Paranoid Android")
    }

    func test_stoppedOrEmptyFields_produceNoSnapshot() {
        // A stopped player, or one with no track name, is "no active
        // player" → nil snapshot (so the controller clears, debounced).
        let stopped = NowPlayingRawFields(
            app: .music,
            playerState: .stopped,
            title: "Whatever",
            artist: "x",
            album: "y",
            durationSeconds: 100,
            elapsedSeconds: 0,
            artwork: nil
        )
        XCTAssertNil(NowPlayingMapper.snapshot(from: stopped, capturedAt: capturedAt))

        let noTitle = NowPlayingRawFields(
            app: .spotify,
            playerState: .playing,
            title: "",
            artist: "x",
            album: "y",
            durationSeconds: 100,
            elapsedSeconds: 0,
            artwork: nil
        )
        XCTAssertNil(NowPlayingMapper.snapshot(from: noTitle, capturedAt: capturedAt))
    }

    // MARK: - Active-player selection

    func test_activePlayer_prefersPlaying_thenMostRecent() {
        let playingMusic = makeSnapshot(app: .music, isPlaying: true, capturedAt: capturedAt)
        let pausedSpotify = makeSnapshot(app: .spotify, isPlaying: false, capturedAt: capturedAt)

        // One playing, one paused → the playing one wins regardless of order.
        XCTAssertEqual(
            NowPlayingMapper.selectActive([pausedSpotify, playingMusic])?.app,
            .music
        )
        XCTAssertEqual(
            NowPlayingMapper.selectActive([playingMusic, pausedSpotify])?.app,
            .music
        )

        // Both playing → the most-recently-active (latest lastActiveAt) wins.
        let older = makeSnapshot(
            app: .music, isPlaying: true,
            capturedAt: capturedAt,
            lastActiveAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = makeSnapshot(
            app: .spotify, isPlaying: true,
            capturedAt: capturedAt,
            lastActiveAt: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertEqual(NowPlayingMapper.selectActive([older, newer])?.app, .spotify)
        XCTAssertEqual(NowPlayingMapper.selectActive([newer, older])?.app, .spotify)

        // Only paused tracks → return a paused snapshot (do not drop it).
        let pausedOnly = makeSnapshot(app: .spotify, isPlaying: false, capturedAt: capturedAt)
        XCTAssertEqual(NowPlayingMapper.selectActive([pausedOnly])?.app, .spotify)
        XCTAssertEqual(NowPlayingMapper.selectActive([pausedOnly])?.isPlaying, false)

        // Nothing at all → nil.
        XCTAssertNil(NowPlayingMapper.selectActive([]))
    }

    // MARK: - AppleScript execution timeout (Finding 2)

    func test_boundedExecution_returnsNil_whenScriptHangsPastDeadline() {
        // A wedged Apple Event must NOT block the script queue forever. With
        // a short deadline and an executor that blocks well past it, the
        // bounded runner must give up and report "no result" (nil) so the
        // controller's debounced-clear path kicks in and the next poll
        // retries. We assert it returns within a tight wall-clock bound — if
        // the timeout were missing, this would hang for the executor's full
        // 5 s and the wall-clock assertion would fail.
        let hangingExecutor: AppleScriptExecutor = { _ in
            Thread.sleep(forTimeInterval: 5.0)
            return AppleScriptOutput(stringValue: "too late", data: nil, failed: false)
        }
        let source = AppleScriptNowPlayingSource(
            workspace: .shared,
            executor: hangingExecutor,
            executionTimeout: 0.2
        )

        let start = Date()
        let result = source.runScriptForTesting("tell application \"Music\" to return 1")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "a script that overruns the deadline must yield nil")
        XCTAssertLessThan(
            elapsed, 2.0,
            "bounded execution must return near the deadline, not wait out the hang"
        )
    }

    func test_boundedExecution_returnsValue_whenScriptCompletesInTime() {
        // The happy path: an executor that returns promptly is passed
        // through unchanged (the timeout only fires on overrun).
        let fastExecutor: AppleScriptExecutor = { _ in
            AppleScriptOutput(stringValue: "playing", data: nil, failed: false)
        }
        let source = AppleScriptNowPlayingSource(
            workspace: .shared,
            executor: fastExecutor,
            executionTimeout: 2.0
        )

        XCTAssertEqual(
            source.runScriptForTesting("tell application \"Music\" to return 1"),
            "playing"
        )
    }

    // MARK: - Helpers

    private func makeSnapshot(
        app: NowPlayingApp,
        isPlaying: Bool,
        capturedAt: Date,
        lastActiveAt: Date? = nil
    ) -> NowPlayingCandidate {
        NowPlayingCandidate(
            snapshot: NowPlayingSnapshot(
                app: app,
                title: "t",
                artist: "a",
                album: "al",
                artwork: nil,
                elapsed: 1,
                duration: 10,
                isPlaying: isPlaying,
                capturedAt: capturedAt
            ),
            lastActiveAt: lastActiveAt
        )
    }
}
