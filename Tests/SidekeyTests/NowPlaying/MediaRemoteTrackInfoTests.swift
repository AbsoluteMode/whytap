import AppKit
import XCTest
@testable import Sidekey

/// Codable contract for `MediaRemoteTrackInfo` — the model decoded from one
/// line of the ungive `stream --no-diff --micros` output's `payload`
/// dictionary. Pins the field names + units against the real adapter so a
/// silent rename upstream (or a wrong key here) fails loudly.
///
/// A known 1×1 PNG is decoded from base64 to prove artwork bytes become an
/// `NSImage`. `isPlaying` is exercised as BOTH a JSON bool and a 0/1 int
/// (the adapter emits a bool; the int tolerance is defensive against the
/// MediaRemote substrate flipping representation, per spec).
final class MediaRemoteTrackInfoTests: XCTestCase {

    // 1×1 opaque red PNG.
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    private func decode(_ json: String) throws -> MediaRemoteTrackInfo {
        try JSONDecoder().decode(MediaRemoteTrackInfo.self, from: Data(json.utf8))
    }

    func test_decodesAllFields_boolIsPlaying_andArtwork() throws {
        let json = """
        {
          "title": "Karma Police",
          "artist": "Radiohead",
          "album": "OK Computer",
          "playing": true,
          "durationMicros": 261400000,
          "elapsedTimeMicros": 42000000,
          "timestampEpochMicros": 1700000000000000,
          "playbackRate": 1.0,
          "bundleIdentifier": "com.apple.Music",
          "processIdentifier": 4242,
          "artworkData": "\(Self.pngBase64)",
          "artworkMimeType": "image/png"
        }
        """
        let info = try decode(json)
        XCTAssertEqual(info.title, "Karma Police")
        XCTAssertEqual(info.artist, "Radiohead")
        XCTAssertEqual(info.album, "OK Computer")
        XCTAssertEqual(info.isPlaying, true)
        XCTAssertEqual(info.durationMicros ?? 0, 261_400_000, accuracy: 1)
        XCTAssertEqual(info.elapsedTimeMicros ?? 0, 42_000_000, accuracy: 1)
        XCTAssertEqual(info.timestampEpochMicros ?? 0, 1_700_000_000_000_000, accuracy: 1)
        XCTAssertEqual(info.playbackRate ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(info.bundleIdentifier, "com.apple.Music")
        XCTAssertNotNil(info.artwork, "base64 PNG must decode to an NSImage")
    }

    func test_tolerates_isPlaying_asInt() throws {
        let playing = try decode(#"{"title":"t","playing":1,"bundleIdentifier":"com.spotify.client"}"#)
        XCTAssertEqual(playing.isPlaying, true)

        let paused = try decode(#"{"title":"t","playing":0,"bundleIdentifier":"com.spotify.client"}"#)
        XCTAssertEqual(paused.isPlaying, false)
    }

    func test_missingArtwork_decodesWithNilImage() throws {
        let info = try decode("""
        {"title":"No Art","artist":"a","playing":false,"bundleIdentifier":"com.apple.Music"}
        """)
        XCTAssertNil(info.artwork)
        XCTAssertEqual(info.title, "No Art")
        XCTAssertEqual(info.isPlaying, false)
    }

    func test_missingIsPlaying_isNil() throws {
        // The adapter normally always sends "playing"; a payload without it
        // leaves `isPlaying` nil so the mapper can fall back to playbackRate.
        let info = try decode(#"{"title":"t","playbackRate":1.0,"bundleIdentifier":"com.apple.Music"}"#)
        XCTAssertNil(info.isPlaying)
        XCTAssertEqual(info.playbackRate ?? 0, 1.0, accuracy: 0.0001)
    }

    func test_currentElapsedSeconds_interpolatesWhilePlaying() throws {
        // elapsed at timestamp = 10s, playbackRate 1.0; "now" is 5s after the
        // timestamp → expect ~15s.
        let ts: Double = 1_700_000_000_000_000  // epoch micros
        let json = """
        {"title":"t","playing":true,"bundleIdentifier":"com.apple.Music",
         "elapsedTimeMicros":10000000,"timestampEpochMicros":\(Int64(ts)),"playbackRate":1.0}
        """
        let info = try decode(json)
        let now = Date(timeIntervalSince1970: ts / 1_000_000 + 5.0)
        XCTAssertEqual(info.currentElapsedSeconds(now: now), 15.0, accuracy: 0.01)
    }

    func test_currentElapsedSeconds_frozenWhilePaused() throws {
        let ts: Double = 1_700_000_000_000_000
        let json = """
        {"title":"t","playing":false,"bundleIdentifier":"com.apple.Music",
         "elapsedTimeMicros":10000000,"timestampEpochMicros":\(Int64(ts)),"playbackRate":0.0}
        """
        let info = try decode(json)
        let now = Date(timeIntervalSince1970: ts / 1_000_000 + 30.0)
        // Paused (rate 0): elapsed does not advance past the captured 10s.
        XCTAssertEqual(info.currentElapsedSeconds(now: now), 10.0, accuracy: 0.01)
    }
}
