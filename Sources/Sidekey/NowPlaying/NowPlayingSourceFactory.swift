import Foundation

/// Picks the now-playing data source once per session: the prompt-free
/// MediaRemote adapter when its health check passes and its assets
/// constructed, otherwise the AppleScript source (unchanged, TCC-prompted at
/// runtime). The choice is **fixed for the session** — no per-poll switching.
///
/// The health closure and the two builders are injectable so the selection
/// logic is unit-tested without spawning perl or touching a real bundle.
enum NowPlayingSourceFactory {

    /// Which source kind was selected — surfaced so the Settings view can
    /// render the Automation row only when AppleScript is active.
    enum Kind: Equatable {
        case mediaRemote
        case appleScript
    }

    struct Selection {
        let source: NowPlayingSource
        let kind: Kind
    }

    /// Resolve and return the active source plus its kind.
    ///
    /// - Parameters:
    ///   - health: returns the adapter health; defaults to the real static
    ///     probe. Injected in tests.
    ///   - makeMediaRemote: builds the adapter source (fails to `nil` when
    ///     assets are missing). Injected in tests.
    ///   - makeAppleScript: builds the AppleScript fallback. Injected in tests.
    static func makeSelection(
        health: () -> MediaRemoteNowPlayingSource.Health = { MediaRemoteNowPlayingSource.healthCheck() },
        makeMediaRemote: () -> MediaRemoteNowPlayingSource? = { MediaRemoteNowPlayingSource() },
        makeAppleScript: () -> NowPlayingSource = { AppleScriptNowPlayingSource() }
    ) -> Selection {
        if health() == .ok, let adapter = makeMediaRemote() {
            adapter.start()
            return Selection(source: adapter, kind: .mediaRemote)
        }
        return Selection(source: makeAppleScript(), kind: .appleScript)
    }
}
