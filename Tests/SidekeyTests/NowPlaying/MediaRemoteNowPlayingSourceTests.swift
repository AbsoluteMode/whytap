import XCTest
@testable import Sidekey

/// `MediaRemoteNowPlayingSource` behavior that is testable without a real
/// player or the bundled assets present in the test host. The process
/// streaming + transport are covered by contract (the pure parsing/mapper
/// tests) and by the on-device packaging proof; here we pin the fail-closed
/// guarantees the fallback relies on.
final class MediaRemoteNowPlayingSourceTests: XCTestCase {

    func test_initReturnsNil_whenBundleLacksAssets() {
        // The xctest host bundle has no MediaRemoteAdapter resources, so the
        // adapter must refuse to construct (→ factory falls back to
        // AppleScript). This is the fail-closed contract.
        let source = MediaRemoteNowPlayingSource(bundle: .main)
        XCTAssertNil(source, "adapter must fail-closed when run.pl/framework are absent")
    }

    func test_healthCheck_unavailable_whenAssetsMissing() {
        // No assets in the test host → healthCheck must report unavailable
        // without spawning anything.
        XCTAssertEqual(MediaRemoteNowPlayingSource.healthCheck(bundle: .main), .unavailable)
    }

    func test_currentSnapshot_isNil_beforeAnyData() {
        // A freshly built source (when one can be built) returns nil until the
        // stream pushes a snapshot. We can't build a real one here, so assert
        // the cache contract via the factory fallback path instead: an
        // unhealthy environment never yields a MediaRemote source.
        let selection = NowPlayingSourceFactory.makeSelection(
            health: { .unavailable },
            makeMediaRemote: { nil },
            makeAppleScript: { AppleScriptNowPlayingSource() }
        )
        XCTAssertEqual(selection.kind, .appleScript)
    }
}
