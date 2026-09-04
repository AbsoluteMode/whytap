import AppKit
import XCTest
@testable import Sidekey

/// Pure mapping from a decoded `MediaRemoteTrackInfo` to a
/// `NowPlayingSnapshot`. No process, no I/O — data → data, so the bundle
/// filter, microsecond→second conversion, and the isPlaying-vs-rate
/// resolution are unit-pinned.
final class MediaRemoteSnapshotMapperTests: XCTestCase {

    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func info(
        title: String? = "Song",
        artist: String? = "Artist",
        album: String? = "Album",
        isPlaying: Bool? = true,
        durationMicros: Double? = 200_000_000,
        elapsedTimeMicros: Double? = 50_000_000,
        timestampEpochMicros: Double? = nil,
        playbackRate: Double? = 1.0,
        bundleIdentifier: String?,
        artwork: NSImage? = nil
    ) -> MediaRemoteTrackInfo {
        MediaRemoteTrackInfo(
            title: title, artist: artist, album: album, isPlaying: isPlaying,
            durationMicros: durationMicros, elapsedTimeMicros: elapsedTimeMicros,
            timestampEpochMicros: timestampEpochMicros, playbackRate: playbackRate,
            bundleIdentifier: bundleIdentifier, processIdentifier: 1, artwork: artwork
        )
    }

    func test_musicBundle_mapsToMusicApp() {
        let snap = MediaRemoteSnapshotMapper.snapshot(
            from: info(bundleIdentifier: "com.apple.Music"), capturedAt: capturedAt)
        XCTAssertEqual(snap?.app, .music)
    }

    func test_spotifyBundle_mapsToSpotifyApp() {
        let snap = MediaRemoteSnapshotMapper.snapshot(
            from: info(bundleIdentifier: "com.spotify.client"), capturedAt: capturedAt)
        XCTAssertEqual(snap?.app, .spotify)
    }

    func test_otherBundle_isFilteredOut() {
        XCTAssertNil(MediaRemoteSnapshotMapper.snapshot(
            from: info(bundleIdentifier: "com.apple.Safari"), capturedAt: capturedAt))
        XCTAssertNil(MediaRemoteSnapshotMapper.snapshot(
            from: info(bundleIdentifier: nil), capturedAt: capturedAt))
    }

    func test_microsConvertedToSeconds_noPerAppDivisor() {
        // Both Music and Spotify: durationMicros / 1e6, elapsed via the
        // interpolation (here timestamp absent → raw elapsed). No per-app
        // millisecond divisor (MediaRemote normalizes both to micros).
        let snap = MediaRemoteSnapshotMapper.snapshot(
            from: info(
                durationMicros: 215_000_000, elapsedTimeMicros: 42_000_000,
                timestampEpochMicros: nil, bundleIdentifier: "com.spotify.client"),
            capturedAt: capturedAt)
        XCTAssertEqual(snap?.duration ?? 0, 215.0, accuracy: 0.001)
        XCTAssertEqual(snap?.elapsed ?? 0, 42.0, accuracy: 0.001)
    }

    func test_isPlaying_fromExplicitBool() {
        let paused = MediaRemoteSnapshotMapper.snapshot(
            from: info(isPlaying: false, playbackRate: 1.0,
                       bundleIdentifier: "com.apple.Music"),
            capturedAt: capturedAt)
        // Explicit bool wins over rate.
        XCTAssertEqual(paused?.isPlaying, false)
    }

    func test_isPlaying_fallsBackToPlaybackRate_whenBoolMissing() {
        let playing = MediaRemoteSnapshotMapper.snapshot(
            from: info(isPlaying: nil, playbackRate: 1.0,
                       bundleIdentifier: "com.apple.Music"),
            capturedAt: capturedAt)
        XCTAssertEqual(playing?.isPlaying, true)

        let paused = MediaRemoteSnapshotMapper.snapshot(
            from: info(isPlaying: nil, playbackRate: 0.0,
                       bundleIdentifier: "com.apple.Music"),
            capturedAt: capturedAt)
        XCTAssertEqual(paused?.isPlaying, false)
    }

    func test_emptyTitle_producesNil() {
        XCTAssertNil(MediaRemoteSnapshotMapper.snapshot(
            from: info(title: "", bundleIdentifier: "com.apple.Music"),
            capturedAt: capturedAt))
        XCTAssertNil(MediaRemoteSnapshotMapper.snapshot(
            from: info(title: "   ", bundleIdentifier: "com.apple.Music"),
            capturedAt: capturedAt))
        XCTAssertNil(MediaRemoteSnapshotMapper.snapshot(
            from: info(title: nil, bundleIdentifier: "com.apple.Music"),
            capturedAt: capturedAt))
    }

    func test_nilArtistAlbum_becomeEmptyStrings() {
        let snap = MediaRemoteSnapshotMapper.snapshot(
            from: info(artist: nil, album: nil, bundleIdentifier: "com.apple.Music"),
            capturedAt: capturedAt)
        XCTAssertEqual(snap?.artist, "")
        XCTAssertEqual(snap?.album, "")
    }

    func test_playingInterpolation_usesTimestampAndRate() {
        // elapsed 10s at timestamp; capturedAt 5s later, rate 1.0 → ~15s.
        let ts = capturedAt.timeIntervalSince1970 - 5.0  // timestamp 5s before now
        let snap = MediaRemoteSnapshotMapper.snapshot(
            from: info(
                isPlaying: true, elapsedTimeMicros: 10_000_000,
                timestampEpochMicros: ts * 1_000_000, playbackRate: 1.0,
                bundleIdentifier: "com.apple.Music"),
            capturedAt: capturedAt)
        XCTAssertEqual(snap?.elapsed ?? 0, 15.0, accuracy: 0.05)
    }

    func test_pausedInterpolation_frozen() {
        let ts = capturedAt.timeIntervalSince1970 - 30.0
        let snap = MediaRemoteSnapshotMapper.snapshot(
            from: info(
                isPlaying: false, elapsedTimeMicros: 10_000_000,
                timestampEpochMicros: ts * 1_000_000, playbackRate: 0.0,
                bundleIdentifier: "com.apple.Music"),
            capturedAt: capturedAt)
        XCTAssertEqual(snap?.elapsed ?? 0, 10.0, accuracy: 0.05)
    }

    func test_artworkPassThrough() {
        let img = NSImage(size: NSSize(width: 2, height: 2))
        let snap = MediaRemoteSnapshotMapper.snapshot(
            from: info(bundleIdentifier: "com.apple.Music", artwork: img),
            capturedAt: capturedAt)
        XCTAssertTrue(snap?.artwork === img)
    }
}
