import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class KeybindingsHintViewTests: XCTestCase {
    // MARK: - Hint set

    func testHintsCycleThroughHelpAgentDrop() {
        // The floating chip rolls through three hints so users discover
        // every system-wide binding without having to open the Help
        // window. Order is fixed: Help (how to learn more) → Agent (the
        // marquee feature) → Drop (the legacy voice path).
        let hints = KeybindingsHintView.hints

        XCTAssertEqual(hints.count, 3)
        XCTAssertEqual(hints[0].label, "Help")
        XCTAssertEqual(hints[0].contents, [.text(HotkeyGlyph.option), .text("H")])
        XCTAssertEqual(hints[1].label, "Agent")
        // Right Command is the Agent gesture — "right" lives INSIDE the
        // same keycap as the ⌘ glyph via `.prefixedGlyph`. The chip
        // reads as one cap "right ⌘", not as a separate `R` key or as
        // an inline label outside the cap.
        XCTAssertEqual(hints[1].contents, [
            .prefixedGlyph(prefix: "right", glyph: HotkeyGlyph.command, accessibilityLabel: "Right Command key")
        ])
        XCTAssertEqual(hints[2].label, "Drop")
        // Post-cutover the default Drop binding is the Space-hold gesture, so
        // the chip renders a single "Space" keycap (was ⌥ /).
        XCTAssertEqual(hints[2].contents, [.text("Space")])
    }

    func testHintsReflectChangedHotkeyConfiguration() {
        let hints = KeybindingsHintView.hints(for: HotkeyConfiguration(
            agentGestureKey: .rightOption,
            dropVoiceTapCombo: .optionPeriod
        ))

        XCTAssertEqual(hints[1].label, "Agent")
        XCTAssertEqual(hints[1].contents, [
            .prefixedGlyph(prefix: "right", glyph: HotkeyGlyph.option, accessibilityLabel: "Right Option key")
        ])
        XCTAssertEqual(hints[2].label, "Drop")
        XCTAssertEqual(hints[2].contents, [.text(HotkeyGlyph.option), .text(".")])
    }

    func testHintsOmitAgentWhenNoProviderIsConfigured() {
        let hints = KeybindingsHintView.hints(
            for: .defaults,
            agentConfigured: false
        )

        XCTAssertEqual(hints.map(\.label), ["Help", "Drop"])
    }

    // MARK: - Cycle interval

    func testCycleIntervalIsSixtySecondsPerHint() {
        // One minute per hint — slow enough that the chip reads as a
        // stable landmark, fast enough that the full three-hint loop
        // (3 min) completes inside an average Sidekey session.
        XCTAssertEqual(KeybindingsHintView.cycleIntervalSeconds, 60.0)
    }

    // MARK: - Cycle phase mapping

    func testCyclePhaseMapsTimestampToActiveHintIndex() {
        // Pure floor-on-interval math: t/interval rounded down, modulo
        // total cycle length. Drives which hint shows on a given frame.
        let count = 3
        let interval = KeybindingsHintView.cycleIntervalSeconds
        // t = 0 → first hint.
        XCTAssertEqual(
            KeybindingsHintView.activeHintIndex(at: 0.0, count: count, interval: interval),
            0
        )
        // t = 59.99s → still on the first hint (last sub-second of dwell).
        XCTAssertEqual(
            KeybindingsHintView.activeHintIndex(at: 59.99, count: count, interval: interval),
            0
        )
        // t = 60.0s → crosses into the second hint.
        XCTAssertEqual(
            KeybindingsHintView.activeHintIndex(at: 60.0, count: count, interval: interval),
            1
        )
        // t = 179.99s → still on the third hint (last sub-second before wrap).
        XCTAssertEqual(
            KeybindingsHintView.activeHintIndex(at: 179.99, count: count, interval: interval),
            2
        )
        // t = 180.0s → full 3-hint loop elapsed (60s × 3), wraps to 0.
        XCTAssertEqual(
            KeybindingsHintView.activeHintIndex(at: 180.0, count: count, interval: interval),
            0
        )
    }

    func testCyclePhaseDegeneratesGracefullyForZeroCount() {
        // Defensive: empty hint set returns 0 so a caller relying on
        // `hints[index]` short-circuits instead of crashing.
        XCTAssertEqual(
            KeybindingsHintView.activeHintIndex(at: 1.5, count: 0, interval: 60.0),
            0
        )
    }

    // MARK: - Panel envelope

    func testPanelWidthAccommodatesWidestHintEnvelope() {
        // The hidden ZStack inside the view auto-sizes to the widest
        // hint, but the outer `.frame(width:height:)` constrains. Width
        // stays at 144pt — vertical axis is sized to the compact-chip
        // intrinsic envelope (= `KeycapView.compactSize` + 2 ×
        // `HotkeyHintView.compactChipVerticalPadding`) so the helper
        // under the orb renders at the same chip size as the compact
        // chips inside the agent response panel.
        XCTAssertEqual(KeybindingsHintView.panelWidth, 144)
        XCTAssertEqual(KeybindingsHintView.panelHeight, KeybindingsHintView.compactChipIntrinsicHeight)
    }

    /// The helper chip under the orb must visually match the compact
    /// chips inside the agent response panel (Maxim: "Мы можем такой же
    /// хелпер сделать под орбом. Такой же хелпер по размеру, как и в
    /// агенте"). Both surfaces render through `HotkeyHintView` —
    /// `compact: true` is the lever that produces the same chip body.
    /// Panel envelope = chip body so there's no padding drift to mask.
    func testCompactChipIntrinsicHeightIsKeycapPlusCompactPadding() {
        // `compactChipIntrinsicHeight` is the single source of truth
        // for the helper-under-orb vertical envelope: keycap envelope
        // + the compact-mode vertical padding HotkeyHintView applies
        // around its HStack. Pinned here so a future change to either
        // constant trips visually before reaching production.
        let expected = KeycapView.compactSize
            + 2 * HotkeyHintView.compactChipVerticalPadding
        XCTAssertEqual(KeybindingsHintView.compactChipIntrinsicHeight, expected)
    }

    func testHelperUnderOrbUsesCompactChipMode() {
        // The hint view feeds `compact: true` to every inner
        // `HotkeyHintView` so the chip body matches the agent panel's
        // close-row chip exactly. The flag is a pinned constant so a
        // future regression flipping back to default chrome trips here
        // before the visual review.
        XCTAssertTrue(KeybindingsHintView.usesCompactChips)
    }

    // MARK: - Smoke render

    func testRendersInsideHostingControllerWithoutCrashing() {
        let view = KeybindingsHintView()
        let hosting = NSHostingController(rootView: view)

        XCTAssertNotNil(hosting.view)
    }
}
