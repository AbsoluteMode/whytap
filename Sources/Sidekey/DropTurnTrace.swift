import Foundation

/// Ordered lifecycle checkpoints of a single Drop voice turn. The raw values
/// impose the ordering used by `DropTurnTrace.lastPhase` — the furthest point
/// a (possibly stuck) turn reached before it resolved or was killed by the
/// turn-watchdog. Localises where a hang happened:
///
///   - stuck at `.recording` (no `.firstToken`) → connected but nothing
///     transcribed (audio not flowing / provider silent);
///   - reached `.firstToken` but never `.stopRequested` → the user's release
///     was never delivered to `stop()` — the unbounded hang the post-stop
///     watchdog cannot catch (it only arms in `stop()`);
///   - `.stopRequested` but never `.done` → finalisation hung.
enum DropTurnPhase: Int, Comparable, CaseIterable {
    case started
    case recording
    case firstToken
    case stopRequested
    case resolving
    case done

    static func < (lhs: DropTurnPhase, rhs: DropTurnPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .started: return "started"
        case .recording: return "recording"
        case .firstToken: return "first_token"
        case .stopRequested: return "stop_requested"
        case .resolving: return "resolving"
        case .done: return "done"
        }
    }
}

/// Privacy-safe per-turn diagnostic accumulator for the Drop voice flow.
///
/// Stamps phase-crossing timestamps + an inbound-token count over the life of
/// one turn, then emits a flat telemetry payload (ms offsets, counts, enum
/// labels, ids, booleans) on the terminal event. It deliberately holds **no
/// transcript text** — only a token *count* — so it can ship permanently
/// without the dictation-leak that retired the temporary `drop_phase_debug`
/// diagnostic (#350; `String(describing: wing)` serialised the live transcript
/// — invariant #3).
///
/// `@MainActor` because every Drop call site (hotkey, session wiring,
/// stop/result handlers, turn-watchdog) already runs on the main actor.
///
// WHY: docs/decisions/2026-06-17-drop-turn-diagnostic-trace.md
@MainActor
final class DropTurnTrace {
    let turnId: String
    private let start: Date
    private var stamps: [DropTurnPhase: Date]
    private(set) var tokenCount: Int = 0

    init(turnId: String = UUID().uuidString, start: Date = Date()) {
        self.turnId = turnId
        self.start = start
        self.stamps = [.started: start]
    }

    /// Stamp the first time `phase` is reached. Later marks for the same phase
    /// are ignored (first wins) so a stamp reflects the earliest crossing.
    func mark(_ phase: DropTurnPhase, at: Date = Date()) {
        guard stamps[phase] == nil else { return }
        stamps[phase] = at
    }

    /// Count one inbound transcript token and stamp `.firstToken` on the first
    /// one. Counts only — never the token *text* (privacy / invariant #3).
    func recordToken(at: Date = Date()) {
        tokenCount += 1
        mark(.firstToken, at: at)
    }

    /// Furthest checkpoint reached, regardless of the order marks arrived in.
    var lastPhase: DropTurnPhase {
        stamps.keys.max() ?? .started
    }

    /// Privacy-safe telemetry payload: ids, enum labels, counts, ms offsets and
    /// booleans only. NEVER transcript text. A phase that was never reached has
    /// no `<phase>_ms` key, so absence is itself signal.
    func metadata(outcome: String, reason: String? = nil, at: Date = Date()) -> [String: Any] {
        var meta: [String: Any] = [
            "turn_id": turnId,
            "mode": "voice",
            "flow": "drop",
            "outcome": outcome,
            "last_phase": lastPhase.label,
            "token_count": tokenCount,
            "stop_requested": stamps[.stopRequested] != nil,
            "total_ms": elapsedMs(to: at)
        ]
        if let reason {
            meta["reason"] = reason
        }
        for phase in DropTurnPhase.allCases where phase != .started {
            if let stamp = stamps[phase] {
                meta["\(phase.label)_ms"] = elapsedMs(to: stamp)
            }
        }
        return meta
    }

    private func elapsedMs(to date: Date) -> Int {
        max(0, Int(date.timeIntervalSince(start) * 1000))
    }
}
