import Foundation

/// Orthogonal visibility dimension for the Dynamic Island compact pill,
/// independent of the existing three (compact↔hover-expanded, agent-flow
/// growth, hover panel mode). Ships as exactly two states.
///
/// - `.active`: everything as today — orb strip, passive hints, right-band
///   pills; hover-expand and agent growth remain available.
/// - `.hiddenIdle`: the compact content fades out and collapses to the bare
///   notch (nothing visible under the cutout). The *window* is untouched
///   (never `orderOut`); only the SwiftUI content and the compact hit-rect
///   change. Any activity signal or blocker returns it to `.active`.
enum IdleVisibility: Equatable {
    case active
    case hiddenIdle

    /// Pure decision function — the heart of the idle engine (spec §2.4).
    /// No timers, no `AppState`, no UI: given the current time, the last
    /// activity moment, the threshold, whether a blocker is up, and whether
    /// the feature is enabled, decide the visibility.
    ///
    /// Priority (top wins):
    /// 1. `isEnabled == false` → `.active` (feature off; future toggle veto).
    /// 2. `isBusy == true`     → `.active` (any of the blockers holds it).
    /// 3. idle ≥ `timeout`     → `.hiddenIdle`.
    /// 4. otherwise            → `.active`.
    ///
    /// The timeout boundary is inclusive: idle for exactly `timeout` collapses.
    static func compute(
        now: Date,
        lastActivity: Date,
        timeout: TimeInterval,
        isBusy: Bool,
        isEnabled: Bool
    ) -> IdleVisibility {
        guard isEnabled else { return .active }
        guard !isBusy else { return .active }
        let idleFor = now.timeIntervalSince(lastActivity)
        return idleFor >= timeout ? .hiddenIdle : .active
    }
}

/// Snapshot of the AppState-sourced idle blockers (spec §3). While ANY is up,
/// the island is pinned `.active` and cannot collapse. B10 (mouse-over) is fed
/// separately through the panel's `setHovered`, so it is intentionally absent
/// here. Kept as an explicit named struct + pure `isBusy` so the disjunction is
/// unit-tested field-by-field — no blocker (notably B7 update pill, invariant
/// #5) can be silently dropped by a future edit.
struct IslandIdleBlockers: Equatable {
    /// B1 — Drop flow active (`AppState.phase != .idle`).
    var dropFlowActive: Bool
    /// B2 — Agent phase active (`AppState.agentPhase != .idle`).
    var agentPhaseActive: Bool
    /// B3 — Agent wing / answer panel visible (`agentFlow.isActive`).
    var agentPanelVisible: Bool
    /// B4 — "Take notes / Skip" nudge on screen (`meetingSuggestionActive`).
    var meetingSuggestionActive: Bool
    /// B5 — Meeting recording active or paused (`meetingRecordingActive`).
    var meetingRecordingActive: Bool
    /// B7 — Update pill visible (`updateAvailable != nil`, invariant #5).
    var updateAvailable: Bool
    /// B13 — Post-relaunch "Updated" indicator visible
    /// (`justUpdatedVersion != nil`, invariant #5). Its own ~5 s timer normally
    /// hides it well before the idle timeout, but holding `.active` while it is
    /// up guarantees idle-hide never races it away early.
    var justUpdatedVisible: Bool
    /// B9 — Now Playing strip active (`nowPlaying != nil`).
    var nowPlayingActive: Bool
    /// B11 — Right ⌘/⌥ held right now (`rightCommandHeld || rightOptionHeld`).
    var rightModifierHeld: Bool
    /// B12 — Programmatic hover expansion via ⌥N (`programmaticHoverExpansion`).
    var programmaticHoverExpansion: Bool

    /// The disjunction — `true` if any blocker is up.
    var isBusy: Bool {
        dropFlowActive
            || agentPhaseActive
            || agentPanelVisible
            || meetingSuggestionActive
            || meetingRecordingActive
            || updateAvailable
            || justUpdatedVisible
            || nowPlayingActive
            || rightModifierHeld
            || programmaticHoverExpansion
    }
}
