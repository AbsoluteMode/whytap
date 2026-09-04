import XCTest
@testable import Sidekey

/// Source selection: adapter primary when healthy + constructable, else the
/// AppleScript fallback. Fixed per session. Health + builders are injected so
/// no perl/bundle is needed.
final class NowPlayingSourceFactoryTests: XCTestCase {

    private final class FakeSource: NowPlayingSource {
        func currentSnapshot() -> NowPlayingSnapshot? { nil }
        func previous() {}
        func playPause(isPlaying: Bool) {}
        func next() {}
    }

    func test_fallsBackToAppleScript_whenUnavailable() {
        var appleScriptBuilt = false
        let selection = NowPlayingSourceFactory.makeSelection(
            health: { .unavailable },
            makeMediaRemote: { XCTFail("must not build adapter when unhealthy"); return nil },
            makeAppleScript: { appleScriptBuilt = true; return FakeSource() }
        )
        XCTAssertEqual(selection.kind, .appleScript)
        XCTAssertTrue(appleScriptBuilt)
    }

    func test_fallsBackToAppleScript_whenAdapterAssetsMissing() {
        var appleScriptBuilt = false
        let selection = NowPlayingSourceFactory.makeSelection(
            health: { .ok },
            makeMediaRemote: { nil },  // assets missing → nil
            makeAppleScript: { appleScriptBuilt = true; return FakeSource() }
        )
        XCTAssertEqual(selection.kind, .appleScript)
        XCTAssertTrue(appleScriptBuilt)
    }
}
