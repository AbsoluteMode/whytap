import Foundation

/// Routes the Now Playing snapshot to each island music surface with respect to
/// the "Hide Hover and Music" eye (`DisplayPreferences.hideIslandHoverWidgets`).
///
/// There are two distinct music surfaces:
///   - the COMPACT right-band wing (`IslandMusicWingView`) — a lightweight,
///     always-on "a track is playing" indicator;
///   - the HOVER player WIDGET (`IslandMusicStripView`) — the card with
///     artwork + transport that sits in the gap between the compact island and
///     the hover drawer.
///
/// The eye hides only the hover widget; the compact wing stays put so the right
/// band does not change when the user hides the hover surfaces.
/// WHY: docs/decisions/2026-06-24-eye-keeps-compact-music-wing.md
enum IslandMusicRouting {
    /// Playback for the compact right-band wing — eye-independent: the wing
    /// reflects real playback regardless of the eye.
    static func compactWingNowPlaying<T>(_ playback: T?, hoverWidgetsHidden: Bool) -> T? {
        playback
    }

    /// Playback for the hover player widget — gated by the eye: hidden while the
    /// eye is on.
    static func hoverWidgetNowPlaying<T>(_ playback: T?, hoverWidgetsHidden: Bool) -> T? {
        hoverWidgetsHidden ? nil : playback
    }
}
