import SwiftUI

/// Selection marker chip that sits to the left of the currently selected
/// useful_links row. Rolls between the available hotkey hints on a 3s
/// cycle so the user discovers all four bindings without crowding the
/// chip with a multi-line glyph cluster.
///
/// - `count == 1` — cycles between `[Insert ⌥ ‹]` and `[Open ⌥ ›]` only.
/// - `count >= 2` — cycles through `[Insert]` → `[Open]` → `[Down]` →
///   `[Up]` and loops.
///
/// The chip renders via the shared `HotkeyHintView` (chrome-less: no
/// outer capsule, just label + keycaps) so it stays in lockstep with the
/// Help window rows / response panel close row at the keycap level
/// (keycap chips, VoiceOver pronunciation).
///
/// **Fixed width.** Each hint label is a different length ("Insert" vs
/// "Up"), so a naive cycle would visibly resize the chip on every tick.
/// We claim the widest hint's intrinsic width up front via a hidden ZStack
/// of every hint laid out at full size — the visible hint then sits on
/// top centred inside that fixed envelope, so the chip width is constant
/// for the whole cycle.
struct UsefulLinksRollingHintView: View {
    /// Number of items in the currently visible block. Drives both the
    /// hint set and the cycle length.
    let itemCount: Int
    /// Whether the currently selected item supports `open`. `false` for a copy
    /// item — the rolling hint then drops the "Open" entry from the cycle.
    let openAvailable: Bool
    @ObservedObject private var hotkeys: HotkeyPreferences

    /// One full hint dwell. 3s reads as gentle and legible — slow enough
    /// that a glance lands on a stable label, fast enough that all four
    /// bindings cycle through inside a 12s exposure.
    static let cycleIntervalSeconds: Double = 3.0

    init(itemCount: Int, openAvailable: Bool = true, hotkeys: HotkeyPreferences? = nil) {
        self.itemCount = itemCount
        self.openAvailable = openAvailable
        _hotkeys = ObservedObject(wrappedValue: hotkeys ?? .shared)
    }

    var body: some View {
        let entries = Self.hints(
            forItemCount: itemCount,
            openAvailable: openAvailable,
            configuration: hotkeys.configuration
        )
        Group {
            if entries.isEmpty {
                // Defensive: parent view is gated on `selectedLink != nil`
                // but the empty case degenerates cleanly so a refactor of
                // the parent doesn't crash here.
                EmptyView()
            } else {
                ZStack {
                    // Width-claimer: every possible hint laid out at full
                    // size but rendered invisibly. The ZStack sizes to the
                    // widest child, which becomes the chip's fixed
                    // envelope regardless of which hint is currently
                    // active. `hidden()` keeps the layout pass but
                    // removes both rendering and accessibility — VoiceOver
                    // only sees the visible hint below.
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, hint in
                        // Subtask B: `size: .compact` so the rolling
                        // hint chip matches the helper "Help ⌥ H" under
                        // the orb (~21pt envelope) instead of the
                        // canonical ~30pt chip used by the Help window.
                        // `.keycaps` drops the outer capsule but keeps each
                        // glyph as its own mini chip (was `chrome: false`).
                        HotkeyHintView(
                            label: hint.label,
                            contents: hint.contents,
                            style: .keycaps,
                            size: .compact,
                            framedLabel: true
                        )
                        .hidden()
                    }
                    TimelineView(.periodic(from: .now, by: Self.cycleIntervalSeconds)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                        let index = Self.activeHintIndex(
                            at: phase,
                            count: entries.count,
                            interval: Self.cycleIntervalSeconds
                        )
                        HotkeyHintView(
                            label: entries[index].label,
                            contents: entries[index].contents,
                            style: .keycaps,
                            size: .compact,
                            framedLabel: true
                        )
                        // Smooth fade between hints. SwiftUI rebuilds the chip
                        // on each TimelineView tick — `.transition(.opacity)`
                        // here lets the new hint cross-fade in over the old
                        // instead of snapping.
                        .id(index)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: index)
                    }
                }
            }
        }
    }

    /// One entry in the cycling sequence. Plain struct so the unit tests
    /// can pin the order / contents without depending on the SwiftUI
    /// rendering path.
    struct Hint: Equatable {
        let label: String
        let contents: [KeycapContent]
    }

    /// Hint set for a given item count and the selected item's open-
    /// availability. Pure function — the test suite pins both the contents and
    /// the order. `openAvailable == false` (a copy item) drops the "Open"
    /// entry so the chip never advertises an action the hotkey controller
    /// hasn't registered. Production callers only need to read
    /// `hints(forItemCount:openAvailable:)`; `activeHintIndex(at:)` and
    /// `cycleIntervalSeconds` are exposed for tests that pin the phase math.
    static func hints(forItemCount count: Int, openAvailable: Bool = true) -> [Hint] {
        hints(forItemCount: count, openAvailable: openAvailable, configuration: .defaults)
    }

    static func hints(
        forItemCount count: Int,
        openAvailable: Bool = true,
        configuration: HotkeyConfiguration
    ) -> [Hint] {
        guard count > 0 else { return [] }
        var baseHints: [Hint] = [
            Hint(label: "Insert", contents: configuration.usefulLinksInsertShortcut.contents)
        ]
        // Open only cycles when the selected item supports it (link / path).
        if openAvailable {
            baseHints.append(
                Hint(label: "Open", contents: configuration.usefulLinksOpenShortcut.contents)
            )
        }
        guard count >= 2 else { return baseHints }
        return baseHints + [
            Hint(label: "Down", contents: configuration.usefulLinksNextShortcut.contents),
            Hint(label: "Up", contents: configuration.usefulLinksPreviousShortcut.contents)
        ]
    }

    /// Maps a wallclock timestamp into the active hint index for the
    /// current cycle. Floor-on-interval keeps each hint visible for
    /// exactly `interval` seconds without modulo flicker.
    /// Returns 0 when the hint list is empty so the caller can
    /// short-circuit before reading `hints[index]`.
    static func activeHintIndex(at time: Double, count: Int, interval: Double) -> Int {
        guard count > 0, interval > 0 else { return 0 }
        let totalCycle = interval * Double(count)
        let modulated = time.truncatingRemainder(dividingBy: totalCycle)
        let normalised = modulated < 0 ? modulated + totalCycle : modulated
        return min(count - 1, Int(floor(normalised / interval)))
    }
}
