import AppKit
import SwiftUI

/// Floating keybindings hint that rolls between the three primary
/// system-wide hotkeys so users discover every binding without having
/// to open the Help window.
///
/// Cycle order: `Help ⌥ H` → `Agent ⌘` → `Drop Space` → loops. One full
/// dwell is 60s — slow enough that the chip stays stable for casual
/// glances, fast enough that a user keeping Sidekey open for a few
/// minutes naturally cycles through all three bindings. The Drop chip's
/// caps come from `dropVoiceShortcut.contents` (post-cutover: hold Space),
/// so a rebinding flows straight through without touching this view.
///
/// The chip renders inside a `HotkeyHintView`, which carries the
/// frosted capsule + keycap chips + VoiceOver pronunciation. A hidden
/// ZStack of every hint at full layout size claims the widest hint's
/// intrinsic width up front so the chip envelope stays constant when
/// the visible hint changes — same fixed-width pattern used by
/// `UsefulLinksRollingHintView`.
///
/// Visibility is controlled top-down by `AppDelegate` via the menu-bar
/// "Hide Helpers" toggle (`DisplayPreferences.hideHelpers`). The view
/// itself carries no local hide affordance — when the toggle flips on
/// the panel is closed, when it flips off the panel is reopened.
struct KeybindingsHintView: View {
    /// Shared `AppState` reference so the hint fades out when the
    /// cursor enters the orb area (`orbHovered == true`). The default
    /// resolves to the singleton; tests can inject a fresh instance.
    @ObservedObject private var state: AppState
    @ObservedObject private var hotkeys: HotkeyPreferences
    @ObservedObject private var agentProviders: AgentProviderStore

    /// Outer slot the floating `KeybindingsHintPanel` pins against.
    /// Width was bumped from 128 -> 144 to comfortably fit the widest
    /// cycled hint after the keycap squaring migration (a label-plus-cap
    /// like `Drop Space` is the widest post-cutover); width stays at 144pt
    /// (Maxim's 30% shrink directive is vertical-only).
    static let panelWidth: CGFloat = 144
    /// The helper-under-orb chip is the same `HotkeyHintView(compact:
    /// true)` chip used inside the agent response panel (Maxim: "такой
    /// же хелпер по размеру, как и в агенте"). The panel envelope is
    /// pinned to the chip's natural intrinsic height — keycap envelope
    /// (`KeycapView.compactSize`) plus the compact vertical padding
    /// `HotkeyHintView` applies around it — so the chip renders at its
    /// natural compact size with no SwiftUI frame compression. The
    /// previous 21pt envelope wrapped the default-mode chip; under
    /// compact mode the envelope drops to the smaller intrinsic height,
    /// keeping the helper visually identical to its agent-panel twin.
    static let compactChipIntrinsicHeight: CGFloat =
        KeycapView.compactSize + 2 * HotkeyHintView.compactChipVerticalPadding
    static let panelHeight: CGFloat = compactChipIntrinsicHeight

    /// `true` because every inner `HotkeyHintView` instance renders in
    /// compact chrome (see `body`). Pinned as a static so the unit
    /// suite can verify the contract without snapshotting the SwiftUI
    /// view tree.
    static let usesCompactChips: Bool = true

    /// One full hint dwell. 60s = one minute per hint, three hints
    /// per cycle = three minutes per full loop. Slow enough that the
    /// chip reads as a stable visual landmark; the user who keeps
    /// Sidekey running for a few minutes still sees every binding.
    static let cycleIntervalSeconds: Double = 60.0

    /// Singleton-resolving init — the only callable shape used in
    /// production. The state defaults are computed in the body to
    /// satisfy Swift 6 strict concurrency around MainActor singletons
    /// (same pattern as `DotView`).
    @MainActor
    init(
        state: AppState? = nil,
        hotkeys: HotkeyPreferences? = nil,
        agentProviders: AgentProviderStore? = nil
    ) {
        self.state = state ?? .shared
        self.hotkeys = hotkeys ?? .shared
        self.agentProviders = agentProviders ?? .shared
    }

    var body: some View {
        let entries = Self.hints(
            for: hotkeys.configuration,
            agentConfigured: agentProviders.activeProvider != nil
        )
        ZStack {
            // Width-claimer: every possible hint laid out at full size
            // but rendered invisibly. The ZStack sizes to the widest
            // child, which becomes the chip's fixed envelope regardless
            // of which hint is currently active. `hidden()` keeps the
            // layout pass but removes both rendering and accessibility
            // — VoiceOver only sees the visible hint below.
            //
            // `compact: true` matches the chip body to the agent
            // response panel's compact close-row chip — same keycap
            // size (16pt), padding (6/1), label font (10pt). Maxim:
            // "такой же хелпер по размеру, как и в агенте".
            ForEach(Array(entries.enumerated()), id: \.offset) { _, hint in
                HotkeyHintView(label: hint.label, contents: hint.contents, compact: true)
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
                    compact: true
                )
                .id(index)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: index)
            }
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        // Fade out when the cursor enters the orb area so the in-cluster
        // helper chips (`⌥ 1` / `⌥ 2` / `⌥ 3`) read cleanly without two
        // hint concepts overlapping. Stages with the orb cross-fade
        // inside `FloatingDotPanelRoot` (110ms half-fade): on entering
        // hover the chip fades out in the first half, on leaving hover
        // it waits the cluster's fade-out half-cycle before fading back
        // in. The TimelineView keeps ticking underneath (the chip's
        // cycle state is preserved) — only the opacity flips, so the
        // user lands on whatever hint was active before, no remount.
        .opacity(state.orbHovered ? 0 : 1)
        .animation(
            .easeInOut(duration: 0.11)
                .delay(state.orbHovered ? 0 : 0.11),
            value: state.orbHovered
        )
    }

    /// One entry in the cycling sequence. Plain struct so unit tests can
    /// pin the order / contents without depending on the SwiftUI
    /// rendering path.
    struct Hint: Equatable {
        let label: String
        let contents: [KeycapContent]
    }

    /// The three cycled hints. Order matches the user's natural learning
    /// progression: Help (how to learn the rest) → Agent (the marquee
    /// feature) → Drop (the voice dictation path). Pinned as a static
    /// constant so tests can sweep the contents.
    static var hints: [Hint] {
        hints(for: .defaults)
    }

    static func hints(
        for configuration: HotkeyConfiguration,
        agentConfigured: Bool = true
    ) -> [Hint] {
        var entries = [
            Hint(
                label: "Help",
                contents: [.text(HotkeyGlyph.option), .text("H")]
            )
        ]
        if agentConfigured {
            entries.append(Hint(
                label: "Agent",
                contents: configuration.agentTextShortcut.contents
            ))
        }
        entries.append(Hint(
                label: "Drop",
                contents: configuration.dropVoiceShortcut.contents
        ))
        return entries
    }

    /// Maps a wallclock timestamp into the active hint index for the
    /// current cycle. Same floor-on-interval math as
    /// `UsefulLinksRollingHintView.activeHintIndex` so a future
    /// extraction into a shared helper is mechanical.
    static func activeHintIndex(at time: Double, count: Int, interval: Double) -> Int {
        guard count > 0, interval > 0 else { return 0 }
        let totalCycle = interval * Double(count)
        let modulated = time.truncatingRemainder(dividingBy: totalCycle)
        let normalised = modulated < 0 ? modulated + totalCycle : modulated
        return min(count - 1, Int(floor(normalised / interval)))
    }
}
