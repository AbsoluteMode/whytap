import AppKit
import Foundation

/// Which media app a `NowPlayingSnapshot` came from. v1 supports only the
/// two AppleScript-scriptable players the spec scopes (Apple Music and
/// Spotify); MediaRemote / browser audio is explicitly out of scope.
enum NowPlayingApp: Equatable, Sendable {
    case music
    case spotify

    /// Bundle id used to check the app is already running before scripting
    /// it (scripting a non-running app via `tell application` would launch
    /// it — forbidden by the spec).
    var bundleIdentifier: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    /// The `tell application "<name>"` target for AppleScript.
    var scriptingName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        }
    }
}

/// Immutable snapshot of the current track in a media app, published on
/// `AppState.nowPlaying` and consumed by the Dynamic Island surfaces
/// (Stages 2–3). `artwork` is intentionally an `NSImage?` (already
/// decoded) so the UI never touches raw image bytes or URLs.
///
/// Value type, `let`-only: snapshots are replaced wholesale on each poll,
/// never mutated in place (repo immutability rule).
struct NowPlayingSnapshot: Equatable {
    let app: NowPlayingApp
    let title: String
    let artist: String
    let album: String
    let artwork: NSImage?
    /// Player position, in seconds, normalized across players.
    let elapsed: TimeInterval
    /// Track length, in seconds, normalized across players (Spotify
    /// reports milliseconds at the AppleScript layer; the source divides
    /// before constructing the snapshot).
    let duration: TimeInterval
    let isPlaying: Bool
    /// Wall-clock time this snapshot was captured. Lets the UI extrapolate
    /// elapsed between ~1 s polls without re-scripting.
    let capturedAt: Date

    /// Progress fraction in `0...1`, clamped, `0` when duration is unknown.
    /// The zero-arg form reports the position as of `capturedAt`; equivalent to
    /// `progressFraction(at: capturedAt)`. Kept for callers (and the Stage 1
    /// contract tests) that don't need real-time extrapolation.
    var progressFraction: Double {
        progressFraction(at: capturedAt)
    }

    /// Progress fraction in `0...1` extrapolated to `now`.
    ///
    /// The MediaRemote source publishes a snapshot only when the player emits an
    /// event (play / pause / track change); between events the cached snapshot is
    /// reused unchanged. So the bar must advance the captured `elapsed` by the
    /// wall-clock time since `capturedAt` while playing — otherwise it freezes
    /// until the next event and only "catches up" on a transport command (the
    /// observed "progress only fills on Pause" bug). Paused tracks stay frozen;
    /// clock skew (`now` < `capturedAt`) never runs the bar backwards; an unknown
    /// duration (radio / live) stays empty.
    // WHY: docs/decisions/2026-06-16-island-music-progress-and-gap.md
    func progressFraction(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        let advanced = elapsed + (isPlaying ? max(0, now.timeIntervalSince(capturedAt)) : 0)
        return min(1, max(0, advanced / duration))
    }

    /// Radio / live-stream: a live stream reports no finite duration
    /// (`durationMicros` absent or 0 → `duration` 0), so there is nothing to
    /// seek and skipping is meaningless. The wing hides the progress bar and
    /// the strip hides prev/next for such items.
    var isLive: Bool { duration <= 0 }

    /// Copy with a different `isPlaying`, leaving every other field intact.
    /// Used for the optimistic play/pause flip so the UI responds on click
    /// before the source confirms (immutable copy — never mutated in place).
    func withIsPlaying(_ isPlaying: Bool) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            app: app,
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            elapsed: elapsed,
            duration: duration,
            isPlaying: isPlaying,
            capturedAt: capturedAt
        )
    }

    static func == (lhs: NowPlayingSnapshot, rhs: NowPlayingSnapshot) -> Bool {
        // NSImage has no value equality; compare identity so two snapshots
        // built from the same decoded artwork compare equal, and a missing
        // vs present artwork is still distinguished.
        lhs.app == rhs.app
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.elapsed == rhs.elapsed
            && lhs.duration == rhs.duration
            && lhs.isPlaying == rhs.isPlaying
            && lhs.capturedAt == rhs.capturedAt
            && lhs.artwork === rhs.artwork
    }
}
