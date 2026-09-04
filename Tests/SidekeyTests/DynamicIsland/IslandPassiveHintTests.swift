import XCTest
@testable import Sidekey

final class IslandPassiveHintTests: XCTestCase {

    /// When a priority right-band state takes over (agent wing's "listening…",
    /// meeting slots, update pill), the passive hint must vanish IN THE SAME
    /// FRAME — `nil` animation. The agent recording face inserts with
    /// `.transition(.identity)` (instant), so an animated hint fade overlaps
    /// it: both components read as on-screen at once, and the fade advances on
    /// the main thread, which dictation start keeps busy — the half-faded hint
    /// can linger for hundreds of ms. The reveal back to hints stays animated.
    @MainActor
    func test_priorityStateHidesHintInstantlyButRevealsAnimated() {
        XCTAssertNil(IslandView.passiveHintGateAnimation(hasPriorityRightState: true))
        XCTAssertNotNil(IslandView.passiveHintGateAnimation(hasPriorityRightState: false))
    }

    /// Pins the full hint rotation: Agent Voice, Drop, Agent Text.
    func test_hintsMatchPassiveDynamicIslandSequence() {
        let hints = IslandPassiveHints.hints

        XCTAssertEqual(hints.count, 3)
        XCTAssertEqual(hints[0].title, "Agent Voice")
        XCTAssertEqual(hints[0].actionLabel, "hold")
        XCTAssertEqual(hints[0].shortcutStyle, .inlineText)

        XCTAssertEqual(hints[1].title, "Drop")
        XCTAssertEqual(hints[1].actionLabel, "hold")
        XCTAssertEqual(hints[1].shortcutStyle, .inlineText)
        XCTAssertEqual(hints[1].keyScale, 1.0)
        XCTAssertEqual(hints[1].keyContents, [.text("Space")])

        XCTAssertEqual(hints[2].title, "Agent Text")
        XCTAssertEqual(hints[2].actionLabel, "tap")
        XCTAssertEqual(hints[2].shortcutStyle, .inlineText)
    }

    func test_cycleIntervalIsFiveSecondsPerHint() {
        XCTAssertEqual(IslandPassiveHints.cycleIntervalSeconds, 5.0)
    }

    func test_titleFontIsTightEnoughForCompactIsland() {
        XCTAssertEqual(IslandPassiveHints.titleFontSize, 8.8)
        XCTAssertLessThan(IslandPassiveHints.titleFontSize, 9.5)
    }

    func test_inlineShortcutsMatchActionLabelTypography() {
        XCTAssertEqual(IslandPassiveHints.secondaryTextFontSize, 8.5, accuracy: 0.001)
        XCTAssertEqual(
            IslandPassiveHints.inlineShortcutFontSize,
            IslandPassiveHints.secondaryTextFontSize,
            accuracy: 0.001
        )
        XCTAssertEqual(
            IslandPassiveHints.inlineShortcutTextWeight,
            IslandPassiveHints.secondaryTextWeight
        )
        XCTAssertEqual(
            IslandPassiveHints.inlineShortcutTextOpacity,
            IslandPassiveHints.secondaryTextOpacity,
            accuracy: 0.001
        )
    }

    func test_dropHintUsesInlineShortcutInsteadOfKeycapBoxes() throws {
        let dropHint = try XCTUnwrap(
            IslandPassiveHints.hints.first { $0.title == "Drop" }
        )

        XCTAssertEqual(dropHint.shortcutStyle, .inlineText)

        for keyContent in dropHint.keyContents {
            let layoutWidth = dropHint.keycapLayoutWidth(
                for: keyContent,
                baseSize: KeycapView.compactSize
            )
            let layoutHeight = dropHint.keycapLayoutHeight(baseSize: KeycapView.compactSize)

            XCTAssertNil(layoutWidth)
            XCTAssertEqual(layoutHeight, 0, accuracy: 0.001)
            XCTAssertLessThan(layoutHeight, KeycapView.compactSize)
        }
    }

    func test_dropHintReflectsConfiguredShortcut() throws {
        // The Drop hint is sourced from the live hotkey config, not a
        // hardcoded glyph: rebinding Drop to a real combo flows its keycaps
        // and gesture verb into the Dynamic Island. (Production Drop is fixed
        // to hold-Space, but the hint must track whatever config carries.)
        let rebound = HotkeyConfiguration(
            agentGestureKey: .rightCommand,
            dropVoiceTapCombo: .optionPeriod
        )

        let hints = IslandPassiveHints.hints(for: rebound)
        let dropHint = try XCTUnwrap(hints.first { $0.title == "Drop" })

        // dropVoiceGesture=.tap → normalizedDropGesture=.tap (combo, not holdSpace) →
        // voiceTitle="Toggle" → lowercased "toggle" displayed as the action label.
        XCTAssertEqual(dropHint.actionLabel, rebound.normalizedDropGesture.voiceTitle.lowercased())
        XCTAssertEqual(dropHint.keyContents, [.text(HotkeyGlyph.option), .text(".")])
    }

    func test_keycapLayoutWidthWidensMultiCharLabelInsteadOfClipping() throws {
        // Width-clipping fix: the `.keycaps` layout path pins single-glyph
        // text caps to the canonical square, but a multi-character label like
        // "Space" must NOT be pinned (it would clip). It returns `nil` so the
        // cap sizes itself horizontally; single-glyph caps stay square.
        let keycapHint = IslandPassiveHint(
            title: "Drop",
            actionLabel: "hold",
            keyContents: [.text("Space")],
            shortcutStyle: .keycaps
        )
        let base = KeycapView.compactSize
        let square = keycapHint.keycapLayoutSize(baseSize: base)

        XCTAssertNil(keycapHint.keycapLayoutWidth(for: .text("Space"), baseSize: base))

        let slashWidth = try XCTUnwrap(keycapHint.keycapLayoutWidth(for: .text("/"), baseSize: base))
        XCTAssertEqual(slashWidth, square, accuracy: 0.001)

        let symbolWidth = try XCTUnwrap(
            keycapHint.keycapLayoutWidth(for: .symbol("chevron.left", accessibilityLabel: nil), baseSize: base)
        )
        XCTAssertEqual(symbolWidth, square, accuracy: 0.001)
    }

    func test_passiveHintsLiftSlightlyInsideCompactIsland() {
        XCTAssertEqual(IslandPassiveHints.verticalOffset, -2, accuracy: 0.001)
    }

    func test_allPassiveHintsUseInlineShortcutsInsteadOfKeycapBoxes() {
        for hint in IslandPassiveHints.hints {
            XCTAssertEqual(hint.shortcutStyle, .inlineText)

            for keyContent in hint.keyContents {
                let layoutWidth = hint.keycapLayoutWidth(
                    for: keyContent,
                    baseSize: KeycapView.compactSize
                )
                let layoutHeight = hint.keycapLayoutHeight(baseSize: KeycapView.compactSize)

                XCTAssertNil(layoutWidth)
                XCTAssertEqual(layoutHeight, 0, accuracy: 0.001)
            }
        }
    }

    func test_activeHintIndexMapsTimestampToFiveSecondBuckets() {
        // Literal counts: the mapping is a pure function of (t, count,
        // interval) and must not silently retarget when the live hint
        // set changes size.
        let interval = IslandPassiveHints.cycleIntervalSeconds

        XCTAssertEqual(IslandPassiveHints.activeHintIndex(at: 0.0, count: 2, interval: interval), 0)
        XCTAssertEqual(IslandPassiveHints.activeHintIndex(at: 4.99, count: 2, interval: interval), 0)
        XCTAssertEqual(IslandPassiveHints.activeHintIndex(at: 5.0, count: 2, interval: interval), 1)
        XCTAssertEqual(IslandPassiveHints.activeHintIndex(at: 9.99, count: 2, interval: interval), 1)
        XCTAssertEqual(IslandPassiveHints.activeHintIndex(at: 10.0, count: 2, interval: interval), 0)
        XCTAssertEqual(IslandPassiveHints.activeHintIndex(at: 14.99, count: 2, interval: interval), 0)
        XCTAssertEqual(IslandPassiveHints.activeHintIndex(at: 15.0, count: 2, interval: interval), 1)

        XCTAssertEqual(IslandPassiveHints.activeHintIndex(at: 10.0, count: 3, interval: interval), 2)
        XCTAssertEqual(IslandPassiveHints.activeHintIndex(at: 15.0, count: 3, interval: interval), 0)
    }

    func test_activeHintIndexHandlesEmptyAndInvalidInterval() {
        XCTAssertEqual(IslandPassiveHints.activeHintIndex(at: 2.0, count: 0, interval: 5.0), 0)
        XCTAssertEqual(IslandPassiveHints.activeHintIndex(at: 2.0, count: 3, interval: 0), 0)
    }
}
