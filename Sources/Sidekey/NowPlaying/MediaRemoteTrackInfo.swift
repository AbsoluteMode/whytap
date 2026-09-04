import AppKit
import Foundation

/// One now-playing item decoded from a single line of the MediaRemote
/// adapter's `stream --no-diff --micros` output (the `payload` dictionary;
/// the source unwraps the `{type,diff,payload}` envelope before decoding).
///
/// Field names + units are pinned to the upstream adapter
/// (`ungive/mediaremote-adapter` @ v0.7.6, run with `--micros`): time keys
/// are integer **microseconds** (`durationMicros`, `elapsedTimeMicros`,
/// `timestampEpochMicros`). `playing` is the play/pause bool; the decoder
/// also tolerates a 0/1 integer for it, defensively. `artworkData` is
/// base64 that is decoded to an `NSImage` during `init(from:)` so the rest
/// of the app never touches raw image bytes.
///
/// All numeric fields are optional because the adapter omits keys a player
/// does not report; the mapper fills sensible defaults.
struct MediaRemoteTrackInfo: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    /// `nil` when the adapter omitted "playing"; the mapper then falls back
    /// to `playbackRate > 0`.
    let isPlaying: Bool?
    let durationMicros: Double?
    let elapsedTimeMicros: Double?
    let timestampEpochMicros: Double?
    let playbackRate: Double?
    let bundleIdentifier: String?
    let processIdentifier: Int?
    /// Decoded artwork. `nil` when absent or the base64/bytes were not a
    /// valid image. Kept as a decoded `NSImage` (not raw bytes).
    let artwork: NSImage?

    private enum CodingKeys: String, CodingKey {
        case title
        case artist
        case album
        case playing
        case durationMicros
        case elapsedTimeMicros
        case timestampEpochMicros
        case playbackRate
        case bundleIdentifier
        case processIdentifier
        case artworkData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        isPlaying = try Self.decodeFlexibleBool(c, forKey: .playing)
        durationMicros = try c.decodeIfPresent(Double.self, forKey: .durationMicros)
        elapsedTimeMicros = try c.decodeIfPresent(Double.self, forKey: .elapsedTimeMicros)
        timestampEpochMicros = try c.decodeIfPresent(Double.self, forKey: .timestampEpochMicros)
        playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate)
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        processIdentifier = try c.decodeIfPresent(Int.self, forKey: .processIdentifier)

        if let base64 = try c.decodeIfPresent(String.self, forKey: .artworkData),
            let bytes = Data(base64Encoded: base64) {
            artwork = NSImage(data: bytes)
        } else {
            artwork = nil
        }
    }

    /// Memberwise init for the artwork-preservation path (which substitutes a
    /// previously-decoded `NSImage`) and for tests.
    init(
        title: String?,
        artist: String?,
        album: String?,
        isPlaying: Bool?,
        durationMicros: Double?,
        elapsedTimeMicros: Double?,
        timestampEpochMicros: Double?,
        playbackRate: Double?,
        bundleIdentifier: String?,
        processIdentifier: Int?,
        artwork: NSImage?
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.durationMicros = durationMicros
        self.elapsedTimeMicros = elapsedTimeMicros
        self.timestampEpochMicros = timestampEpochMicros
        self.playbackRate = playbackRate
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.artwork = artwork
    }

    /// Estimated current playback position in **seconds**, interpolating from
    /// the captured `elapsedTimeMicros` at `timestampEpochMicros` by the wall
    /// time elapsed since, scaled by `playbackRate`. When paused
    /// (`playbackRate == 0`) the position is frozen at the captured elapsed.
    /// Falls back to the raw captured elapsed when timestamp/rate are absent.
    func currentElapsedSeconds(now: Date = Date()) -> TimeInterval {
        let elapsedSeconds = (elapsedTimeMicros ?? 0) / 1_000_000
        guard let timestampMicros = timestampEpochMicros else {
            return max(0, elapsedSeconds)
        }
        let rate = playbackRate ?? (isPlaying == true ? 1.0 : 0.0)
        let timestampSeconds = timestampMicros / 1_000_000
        let delta = now.timeIntervalSince1970 - timestampSeconds
        // Only advance when actually progressing; negative rate or clock skew
        // must not run the position backwards.
        let advanced = elapsedSeconds + max(0, delta) * max(0, rate)
        return max(0, advanced)
    }

    /// Decode a JSON value that is a bool OR a 0/1 integer into a `Bool?`.
    private static func decodeFlexibleBool(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Bool? {
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) {
            return b
        }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) {
            return i != 0
        }
        return nil
    }
}
