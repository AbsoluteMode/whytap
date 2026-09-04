import AppKit
import Foundation

/// Buffers raw `Data` chunks from the adapter's stdout and yields complete
/// newline-terminated lines. A `readabilityHandler` delivers arbitrary
/// byte boundaries, so a JSON object can arrive split across two reads — the
/// framer holds the partial remainder until its terminating `\n` shows up.
///
/// Value type (a `struct` with mutating `feed`) so the owning source mutates
/// one instance under its serial queue; no shared global state.
struct LineFramer {
    private var buffer = Data()
    private static let newline = UInt8(ascii: "\n")

    /// Append a chunk and return every complete line it completes (without
    /// the trailing newline). Any trailing partial line is retained for the
    /// next `feed`.
    mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: Self.newline) {
            let lineData = buffer[buffer.startIndex..<nl]
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }
}

/// Unwraps one line of the adapter's `stream --no-diff` output. Each line is
/// either the `{"type":"data","diff":false,"payload":{…}}` envelope or a
/// bare `null` (the `get` shape, used by the health check). Returns the
/// decoded `MediaRemoteTrackInfo` from the payload, or `nil` for
/// `null`/blank/unparseable lines.
enum MediaRemoteStreamLine {

    private struct Envelope: Decodable {
        let type: String?
        let payload: MediaRemoteTrackInfo?
    }

    static func decode(_ line: String) -> MediaRemoteTrackInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else { return nil }

        let data = Data(trimmed.utf8)
        let decoder = JSONDecoder()

        // Stream form: a `{type,diff,payload}` envelope.
        if let envelope = try? decoder.decode(Envelope.self, from: data),
            envelope.type == "data" {
            return envelope.payload
        }
        // `get` form: a bare payload object (no envelope). Used by healthCheck.
        return try? decoder.decode(MediaRemoteTrackInfo.self, from: data)
    }
}

/// Same-track artwork anti-flicker. The MediaRemote substrate sometimes
/// briefly drops artwork (unloads then reloads it) while the track is
/// unchanged; without this, the strip would flash empty art for one poll.
/// When the incoming event is the **same track** (title + artist) as the
/// previous one but has lost its artwork, the previous decoded image is
/// carried over. A track change, or fresh incoming artwork, passes through.
enum MediaRemoteArtworkPreserver {

    static func merge(
        previous: MediaRemoteTrackInfo?,
        incoming: MediaRemoteTrackInfo
    ) -> MediaRemoteTrackInfo {
        guard
            let previous,
            incoming.artwork == nil,
            previous.artwork != nil,
            isSameTrack(previous, incoming)
        else {
            return incoming
        }
        return incoming.withArtwork(previous.artwork)
    }

    private static func isSameTrack(
        _ a: MediaRemoteTrackInfo, _ b: MediaRemoteTrackInfo
    ) -> Bool {
        (a.title ?? "") == (b.title ?? "") && (a.artist ?? "") == (b.artist ?? "")
    }
}

extension MediaRemoteTrackInfo {
    /// Copy with a substituted artwork image (used by the preserver).
    func withArtwork(_ image: NSImage?) -> MediaRemoteTrackInfo {
        MediaRemoteTrackInfo(
            title: title, artist: artist, album: album, isPlaying: isPlaying,
            durationMicros: durationMicros, elapsedTimeMicros: elapsedTimeMicros,
            timestampEpochMicros: timestampEpochMicros, playbackRate: playbackRate,
            bundleIdentifier: bundleIdentifier, processIdentifier: processIdentifier,
            artwork: image)
    }
}
