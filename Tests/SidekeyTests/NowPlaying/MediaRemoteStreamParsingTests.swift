import AppKit
import XCTest
@testable import Sidekey

/// Pure helpers backing `MediaRemoteNowPlayingSource`'s stdout handling:
/// the newline line-framer (partial chunks, multi-line bursts) and the
/// envelope/payload unwrap, plus the same-track artwork-preservation
/// heuristic. Kept pure so the process plumbing stays untested-by-contract
/// while the parsing logic is pinned here.
final class MediaRemoteStreamParsingTests: XCTestCase {

    // MARK: - Line framing

    func test_framer_splitsCompleteLines_keepsRemainder() {
        var framer = LineFramer()
        let first = framer.feed(Data("aaa\nbbb\nccc".utf8))
        XCTAssertEqual(first, ["aaa", "bbb"])
        // "ccc" has no trailing newline yet → buffered, not emitted.
        let second = framer.feed(Data("ddd\n".utf8))
        XCTAssertEqual(second, ["cccddd"])
    }

    func test_framer_handlesMultipleLinesInOneChunk() {
        var framer = LineFramer()
        XCTAssertEqual(framer.feed(Data("1\n2\n3\n".utf8)), ["1", "2", "3"])
    }

    func test_framer_emptyLinesPreserved() {
        var framer = LineFramer()
        XCTAssertEqual(framer.feed(Data("\n\n".utf8)), ["", ""])
    }

    // MARK: - Envelope unwrap

    func test_unwrap_extractsPayloadFromDataEnvelope() throws {
        let line = #"{"type":"data","diff":false,"payload":{"title":"Hi","bundleIdentifier":"com.apple.Music","playing":true}}"#
        let info = MediaRemoteStreamLine.decode(line)
        XCTAssertEqual(info?.title, "Hi")
        XCTAssertEqual(info?.isPlaying, true)
    }

    func test_unwrap_emptyPayload_isNoTrack() {
        // Adapter emits an empty payload object when nothing is playing.
        let info = MediaRemoteStreamLine.decode(#"{"type":"data","diff":false,"payload":{}}"#)
        // Decodes, but has no usable identity (title nil) → the source/mapper
        // treats it as no track.
        XCTAssertNil(info?.title)
    }

    func test_unwrap_bareNull_isNil() {
        XCTAssertNil(MediaRemoteStreamLine.decode("null"))
    }

    func test_unwrap_blankLine_isNil() {
        XCTAssertNil(MediaRemoteStreamLine.decode("   "))
    }

    // MARK: - Artwork preservation

    private func info(title: String, artist: String, artwork: NSImage?) -> MediaRemoteTrackInfo {
        MediaRemoteTrackInfo(
            title: title, artist: artist, album: nil, isPlaying: true,
            durationMicros: nil, elapsedTimeMicros: nil, timestampEpochMicros: nil,
            playbackRate: 1.0, bundleIdentifier: "com.apple.Music",
            processIdentifier: 1, artwork: artwork)
    }

    func test_artwork_preservedOnSameTrackDowngrade() {
        let img = NSImage(size: NSSize(width: 4, height: 4))
        let prev = info(title: "T", artist: "A", artwork: img)
        let incoming = info(title: "T", artist: "A", artwork: nil)  // art vanished
        let merged = MediaRemoteArtworkPreserver.merge(previous: prev, incoming: incoming)
        XCTAssertTrue(merged.artwork === img, "same track losing art keeps the old image")
    }

    func test_artwork_notPreservedAcrossTrackChange() {
        let img = NSImage(size: NSSize(width: 4, height: 4))
        let prev = info(title: "Old", artist: "A", artwork: img)
        let incoming = info(title: "New", artist: "A", artwork: nil)
        let merged = MediaRemoteArtworkPreserver.merge(previous: prev, incoming: incoming)
        XCTAssertNil(merged.artwork, "a new track does not inherit the previous artwork")
    }

    func test_artwork_incomingArtworkWins() {
        let oldImg = NSImage(size: NSSize(width: 4, height: 4))
        let newImg = NSImage(size: NSSize(width: 8, height: 8))
        let prev = info(title: "T", artist: "A", artwork: oldImg)
        let incoming = info(title: "T", artist: "A", artwork: newImg)
        let merged = MediaRemoteArtworkPreserver.merge(previous: prev, incoming: incoming)
        XCTAssertTrue(merged.artwork === newImg, "fresh artwork on the same track is kept")
    }

    func test_artwork_noPreviousIsNoOp() {
        let incoming = info(title: "T", artist: "A", artwork: nil)
        let merged = MediaRemoteArtworkPreserver.merge(previous: nil, incoming: incoming)
        XCTAssertNil(merged.artwork)
    }
}
