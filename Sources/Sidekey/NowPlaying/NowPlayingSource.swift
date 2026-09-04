import AppKit
import Foundation

/// Abstraction over "where the current track comes from". Production uses
/// `AppleScriptNowPlayingSource`; tests inject a fake so the controller's
/// polling/debounce/transport behaviour can be exercised without
/// AppleScript. Transport methods drive the active player.
///
/// `currentSnapshot()` is synchronous from the caller's view but the
/// concrete AppleScript implementation runs the actual scripting off the
/// main thread with a timeout (sync `NSAppleScript` can hang) — see
/// `AppleScriptNowPlayingSource`.
protocol NowPlayingSource: AnyObject {
    /// The active player's current track, or `nil` when nothing is active
    /// (stopped / no track / app not running / scripting failed).
    func currentSnapshot() -> NowPlayingSnapshot?

    func previous()
    /// Prefer a discrete play/pause over a blind `playpause` toggle:
    /// `isPlaying` is the player's last-known state so the source can pick
    /// `pause` (currently playing) or `play` (currently paused) and avoid
    /// toggle races.
    func playPause(isPlaying: Bool)
    func next()
}

// MARK: - Pure mapping layer (AppleScript-free, unit-testable)

/// Player transport state as reported by the scripting dictionary's
/// `player state`. Both Music and Spotify expose `playing` / `paused` /
/// `stopped`.
enum NowPlayingPlayerState: Equatable, Sendable {
    case playing
    case paused
    case stopped

    /// Parse the raw AppleScript `player state` string. Both apps return
    /// the constant's name as text via `executeAndReturnError().stringValue`.
    init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing": self = .playing
        case "paused": self = .paused
        default: self = .stopped
        }
    }
}

/// Fields read from one player, normalized to seconds. The AppleScript
/// layer reads the raw scripting-dictionary values and runs the per-app
/// unit conversion through `NowPlayingMapper.normalizeDuration` BEFORE
/// building this struct, so the snapshot mapper stays player-agnostic and
/// the divisor lives in one unit-tested place.
///
/// `durationSeconds` / `elapsedSeconds` are both in **seconds**.
struct NowPlayingRawFields: Equatable {
    let app: NowPlayingApp
    let playerState: NowPlayingPlayerState
    let title: String
    let artist: String
    let album: String
    let durationSeconds: TimeInterval
    let elapsedSeconds: TimeInterval
    let artwork: NSImage?

    static func == (lhs: NowPlayingRawFields, rhs: NowPlayingRawFields) -> Bool {
        lhs.app == rhs.app
            && lhs.playerState == rhs.playerState
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.durationSeconds == rhs.durationSeconds
            && lhs.elapsedSeconds == rhs.elapsedSeconds
            && lhs.artwork === rhs.artwork
    }
}

/// A per-app snapshot paired with the wall-clock time that app was last
/// seen active, used as the tie-break when more than one player reports
/// `playing` ("most-recently-active wins").
struct NowPlayingCandidate: Equatable {
    let snapshot: NowPlayingSnapshot
    let lastActiveAt: Date?
}

/// Pure conversion + selection logic. No AppleScript, no AppKit side
/// effects — just data → data, so the unit normalization and active-player
/// tie-break are fully unit-tested.
enum NowPlayingMapper {

    /// Normalize a raw `duration` value from a player's scripting dictionary
    /// into seconds. Spotify reports `duration` in **milliseconds**; Music
    /// reports it in **seconds**. This is the single source of truth for the
    /// per-app unit difference — the AppleScript layer passes the RAW value
    /// straight from the player and lets this pure function convert, so the
    /// divisor is unit-testable and cannot silently drift.
    static func normalizeDuration(_ raw: Double, for app: NowPlayingApp) -> TimeInterval {
        switch app {
        case .spotify: return raw / 1000.0
        case .music: return raw
        }
    }

    /// Build a snapshot from one player's raw fields, or `nil` when the
    /// player is not presenting a real track (stopped, or empty title).
    static func snapshot(
        from fields: NowPlayingRawFields,
        capturedAt: Date
    ) -> NowPlayingSnapshot? {
        guard fields.playerState != .stopped else { return nil }
        let title = fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        return NowPlayingSnapshot(
            app: fields.app,
            title: title,
            artist: fields.artist,
            album: fields.album,
            artwork: fields.artwork,
            elapsed: max(0, fields.elapsedSeconds),
            duration: max(0, fields.durationSeconds),
            isPlaying: fields.playerState == .playing,
            capturedAt: capturedAt
        )
    }

    /// Pick the active player among candidates:
    /// 1. Prefer a `playing` candidate.
    /// 2. Among playing candidates, the most-recently-active (latest
    ///    `lastActiveAt`) wins; missing timestamps sort oldest.
    /// 3. If none are playing, return a paused candidate (do not drop it —
    ///    the surfaces stay visible while paused).
    static func selectActive(_ candidates: [NowPlayingCandidate]) -> NowPlayingSnapshot? {
        guard !candidates.isEmpty else { return nil }

        let playing = candidates.filter { $0.snapshot.isPlaying }
        let pool = playing.isEmpty ? candidates : playing

        let chosen = pool.max { lhs, rhs in
            let l = lhs.lastActiveAt ?? .distantPast
            let r = rhs.lastActiveAt ?? .distantPast
            return l < r
        }
        return chosen?.snapshot
    }
}
