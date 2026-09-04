import Foundation

/// Pure conversion from a decoded `MediaRemoteTrackInfo` (one adapter line)
/// to a `NowPlayingSnapshot`. No process, no AppKit side effects — data →
/// data, fully unit-tested.
///
/// Responsibilities:
/// - Filter to the two supported players by bundle id (Music / Spotify);
///   anything else (browsers, other apps) maps to `nil`.
/// - Convert the adapter's microsecond time fields to seconds. There is **no
///   per-app divisor** here (unlike the AppleScript path's Spotify-ms quirk):
///   MediaRemote already normalizes both players to a common unit, so the
///   only conversion is micros → seconds.
/// - Resolve `isPlaying`: an explicit bool from the adapter wins; otherwise
///   fall back to `playbackRate > 0`.
/// - Interpolate the elapsed position via `currentElapsedSeconds(now:)` so a
///   playing track's progress advances between ~1 s polls.
enum MediaRemoteSnapshotMapper {

    /// Map one MediaRemote payload to a snapshot, or `nil` when it does not
    /// represent a real track in a supported player.
    static func snapshot(
        from info: MediaRemoteTrackInfo,
        capturedAt: Date
    ) -> NowPlayingSnapshot? {
        guard let app = app(for: info.bundleIdentifier) else { return nil }

        let title = (info.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let duration = max(0, (info.durationMicros ?? 0) / 1_000_000)
        let elapsed = max(0, info.currentElapsedSeconds(now: capturedAt))
        let isPlaying = info.isPlaying ?? ((info.playbackRate ?? 0) > 0)

        return NowPlayingSnapshot(
            app: app,
            title: title,
            artist: info.artist ?? "",
            album: info.album ?? "",
            artwork: info.artwork,
            elapsed: elapsed,
            duration: duration,
            isPlaying: isPlaying,
            capturedAt: capturedAt
        )
    }

    /// Map a bundle identifier to a supported `NowPlayingApp`, or `nil`.
    static func app(for bundleIdentifier: String?) -> NowPlayingApp? {
        switch bundleIdentifier {
        case NowPlayingApp.music.bundleIdentifier: return .music
        case NowPlayingApp.spotify.bundleIdentifier: return .spotify
        default: return nil
        }
    }
}
