import Foundation

/// Single source of truth for the Dynamic Island idle auto-hide timings.
///
/// v1 ships without a Settings toggle (see spec §6): the threshold is this
/// constant, and the feature is always on. The controller still reads the
/// timeout through an injectable closure defaulting to `idleTimeout`, so a
/// future `DisplayPreferences` toggle wires in without touching the engine.
enum IslandIdleConfig {
    /// How long the user must be idle — no hover, no hotkey, no recording, no
    /// pill on screen — before the compact pill collapses to the "bare notch".
    static let idleTimeout: TimeInterval = 20

    /// Padding around the compact pill's rect forming the mouse WAKE zone.
    /// The wake requires approaching the notch pill itself — never the whole
    /// (permanently agent-wide) window frame (founder feedback 2026-07-06).
    static let wakeZonePadding: CGFloat = 24

    /// Fade-out + collapse of the compact content when going idle. Slightly
    /// slower than the wake so the disappearance reads as "settling", not a
    /// snap. Only the SwiftUI content animates — the window never moves.
    static let sleepAnimationDuration: TimeInterval = 0.22

    /// Fade-in when any activity signal wakes the island. Faster than the sleep
    /// so the return feels instant/responsive to a hover or hotkey.
    static let wakeAnimationDuration: TimeInterval = 0.10
}
