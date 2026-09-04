import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class HotkeyHintViewTests: XCTestCase {
    func testInitStoresLabelAndKeys() {
        let hint = HotkeyHintView(label: "Quit", keys: ["⌥", "Q"])

        XCTAssertEqual(hint.label, "Quit")
        XCTAssertEqual(hint.keys, ["⌥", "Q"])
    }

    func testInitWithoutLabel() {
        // Help window's HotkeyRow already carries the title in its
        // own column — the hotkey hint inside the row sits with no
        // label of its own. nil label = no label shown.
        let hint = HotkeyHintView(keys: ["⌥", "H"])

        XCTAssertNil(hint.label)
        XCTAssertEqual(hint.keys, ["⌥", "H"])
    }

    func testRendersInsideHostingControllerWithoutCrashing() {
        // Smoke — exercising body in an NSHostingController must
        // not throw or assert.
        let hosting = NSHostingController(
            rootView: HotkeyHintView(label: "Quit", keys: ["⌥", "Q"])
        )

        XCTAssertNotNil(hosting.view)
    }

    func testRendersWithoutLabelDoesNotCrash() {
        let hosting = NSHostingController(
            rootView: HotkeyHintView(keys: ["⌥", "H"])
        )

        XCTAssertNotNil(hosting.view)
    }

    func testOptionGlyphConstantIsKeyboardSymbol() {
        // The single source of truth for the Option modifier
        // glyph must be the Unicode keyboard symbol (U+2325),
        // not the word "Option". Consistent with the existing
        // ⌘ glyph for Command rows in the Help window.
        XCTAssertEqual(HotkeyGlyph.option, "\u{2325}")
        XCTAssertEqual(HotkeyGlyph.option, "⌥")
    }

    func testCommandGlyphConstantIsKeyboardSymbol() {
        // Command modifier — already used inline in HotkeyRow's
        // Agent rows. Surface it on the shared symbol enum so
        // future callers don't sprinkle ad-hoc string literals.
        XCTAssertEqual(HotkeyGlyph.command, "\u{2318}")
        XCTAssertEqual(HotkeyGlyph.command, "⌘")
    }

    func testGlyphSpokenNameTranslatesModifiersToReadableNames() {
        // Single-codepoint glyphs read as nothing useful to VoiceOver
        // ("U-plus-twenty-three-twenty-five"). The HotkeyHintView feeds
        // each keycap's accessibility label via `HotkeyGlyph.spokenName`
        // so screen reader users hear "Option key" / "Command key".
        XCTAssertEqual(HotkeyGlyph.spokenName(for: HotkeyGlyph.option), "Option key")
        XCTAssertEqual(HotkeyGlyph.spokenName(for: HotkeyGlyph.command), "Command key")
        XCTAssertEqual(HotkeyGlyph.spokenName(for: HotkeyGlyph.shift), "Shift key")
        XCTAssertEqual(HotkeyGlyph.spokenName(for: HotkeyGlyph.control), "Control key")
        XCTAssertEqual(HotkeyGlyph.spokenName(for: "/"), "Slash key")
        XCTAssertEqual(HotkeyGlyph.spokenName(for: "Q"), "Q key")
    }

    func testCombinedAccessibilityLabelComposesLabelAndSpokenKeyNames() {
        // VoiceOver users hear "<label>, <key1>, <key2>" in one swipe.
        let withLabel = HotkeyHintView(label: "Quit", keys: [HotkeyGlyph.option, "Q"])
        XCTAssertEqual(withLabel.combinedAccessibilityLabel, "Quit, Option key, Q key")

        let noLabel = HotkeyHintView(keys: [HotkeyGlyph.option, "H"])
        XCTAssertEqual(noLabel.combinedAccessibilityLabel, "Option key, H key")
    }

    func testCombinedAccessibilityLabelOmitsEmptyLabel() {
        // Defensive: empty-string label degenerates to "no label" so
        // the announcement doesn't start with a leading comma.
        let hint = HotkeyHintView(label: "", keys: [HotkeyGlyph.option, "H"])

        XCTAssertEqual(hint.combinedAccessibilityLabel, "Option key, H key")
    }

    // MARK: - Production callsite smokes
    //
    // Render the exact (label, keys) tuple that each UI surface uses
    // so a future tweak to one of those literals trips at least one
    // unit test. Layout / pixel-correctness is deferred to Maxim.

    func testResponsePanelCloseRowCallsiteRenders() {
        // AgentResponsePanel close row — "Quit ⌥ Q".
        let hint = HotkeyHintView(label: "Quit", keys: [HotkeyGlyph.option, "Q"])
        let hosting = NSHostingController(rootView: hint)

        XCTAssertNotNil(hosting.view)
        XCTAssertEqual(hint.combinedAccessibilityLabel, "Quit, Option key, Q key")
    }

    func testKeybindingsHintCallsiteRenders() {
        // KeybindingsHintView — "Help ⌥ H".
        let hint = HotkeyHintView(label: "Help", keys: [HotkeyGlyph.option, "H"])
        let hosting = NSHostingController(rootView: hint)

        XCTAssertNotNil(hosting.view)
        XCTAssertEqual(hint.combinedAccessibilityLabel, "Help, Option key, H key")
    }

    func testHelpWindowDropRowCallsiteRenders() {
        // HelpWindowController Drop row — "⌥ /" (no label inside the
        // hint; the row's title column already carries the name).
        let hint = HotkeyHintView(keys: [HotkeyGlyph.option, "/"])
        let hosting = NSHostingController(rootView: hint)

        XCTAssertNotNil(hosting.view)
        XCTAssertEqual(hint.combinedAccessibilityLabel, "Option key, Slash key")
    }

    func testHelpWindowAgentTapRowCallsiteRenders() {
        // HelpWindowController Agent tap row — "Tap ⌘".
        let hint = HotkeyHintView(label: "Tap", keys: [HotkeyGlyph.command])
        let hosting = NSHostingController(rootView: hint)

        XCTAssertNotNil(hosting.view)
        XCTAssertEqual(hint.combinedAccessibilityLabel, "Tap, Command key")
    }

    // MARK: - Chevron / SF Symbol caps (Useful Links nav)

    func testChevronGlyphsAreSFSymbolKeycapContent() {
        // HotkeyGlyph.chevronLeft/right/up/down expose the four cap
        // contents the Useful Links rolling hint uses. They MUST be
        // SF Symbol content (not Unicode arrow text) — the macOS-native
        // two-stroke "uголок" beats the Unicode triangle-tail glyph at
        // the 11pt cap size and reads as part of the same keycap family
        // as the modifier glyphs above.
        XCTAssertEqual(
            HotkeyGlyph.chevronLeft,
            .symbol(HotkeyGlyph.chevronLeftSymbol, accessibilityLabel: "Left arrow key")
        )
        XCTAssertEqual(
            HotkeyGlyph.chevronRight,
            .symbol(HotkeyGlyph.chevronRightSymbol, accessibilityLabel: "Right arrow key")
        )
        XCTAssertEqual(
            HotkeyGlyph.chevronUp,
            .symbol(HotkeyGlyph.chevronUpSymbol, accessibilityLabel: "Up arrow key")
        )
        XCTAssertEqual(
            HotkeyGlyph.chevronDown,
            .symbol(HotkeyGlyph.chevronDownSymbol, accessibilityLabel: "Down arrow key")
        )
    }

    func testKeycapContentTextSpokenNameFallsThroughToHotkeyGlyph() {
        // `.text` content reuses the existing `HotkeyGlyph.spokenName`
        // table so modifier glyphs ("⌥") read as "Option key", single
        // letters read as "X key".
        XCTAssertEqual(KeycapContent.text(HotkeyGlyph.option).spokenName, "Option key")
        XCTAssertEqual(KeycapContent.text("Q").spokenName, "Q key")
        XCTAssertEqual(KeycapContent.text("/").spokenName, "Slash key")
    }

    func testKeycapContentSymbolSpokenNameUsesExplicitAccessibilityLabel() {
        // SF Symbol caps carry their own VoiceOver label so screen
        // readers don't hear the raw symbol identifier (the "chevron.left"
        // string is meaningless out of context).
        XCTAssertEqual(
            KeycapContent.symbol("chevron.left", accessibilityLabel: "Left arrow key").spokenName,
            "Left arrow key"
        )
        // Defensive: when caller forgets the label the spoken form
        // falls back to "<name> key" rather than going silent.
        XCTAssertEqual(
            KeycapContent.symbol("chevron.right", accessibilityLabel: nil).spokenName,
            "chevron.right key"
        )
    }

    func testHotkeyHintViewAcceptsHeterogeneousContents() {
        // The Useful Links rolling hint mixes a text glyph ("⌥") with
        // an SF Symbol chevron in the same chip. Pin the API surface
        // so callers can supply `[KeycapContent]` directly.
        let hint = HotkeyHintView(
            label: "Open",
            contents: [.text(HotkeyGlyph.option), HotkeyGlyph.chevronRight]
        )

        XCTAssertEqual(hint.label, "Open")
        XCTAssertEqual(hint.contents.count, 2)
        XCTAssertEqual(hint.combinedAccessibilityLabel, "Open, Option key, Right arrow key")
    }

    func testHotkeyHintViewRendersHeterogeneousContentsWithoutCrashing() {
        // Smoke: the mixed-content path renders inside an NSHostingController
        // without throwing or asserting — anchors a regression where the
        // new SF Symbol branch in KeycapView fails to lay out.
        let hint = HotkeyHintView(
            label: "Insert",
            contents: [.text(HotkeyGlyph.option), HotkeyGlyph.chevronLeft]
        )
        let hosting = NSHostingController(rootView: hint)

        XCTAssertNotNil(hosting.view)
    }

    func testHotkeyHintViewBackCompatStringInitPreservesKeysProjection() {
        // Existing `init(label:, keys: [String])` callsites still
        // compile and roundtrip through the new `[KeycapContent]`
        // storage. The `keys` projection returns the original
        // String literals so callers can introspect the same data.
        let hint = HotkeyHintView(label: "Help", keys: [HotkeyGlyph.option, "H"])

        XCTAssertEqual(hint.keys, [HotkeyGlyph.option, "H"])
        XCTAssertEqual(hint.contents, [.text(HotkeyGlyph.option), .text("H")])
    }

    // MARK: - Compact variant (Subtask B)
    //
    // Subtask B: "хелперы сделать меньше что бы были такие же как под кольцом".
    // The helper chips inside the response panel (Quit ⌥ Q at the top,
    // UsefulLinksRollingHintView next to each link) must visually match
    // the helper "Help ⌥ H" that floats below the orb, which is
    // pinned to KeybindingsHintView.panelHeight = compactChipIntrinsicHeight
    // (= KeycapView.compactSize + 2 × compactChipVerticalPadding = 18pt).
    // The default chip is ~30pt tall (22pt cap + 8pt vertical padding) —
    // too big inside the response panel. The compact variant tightens
    // padding, shrinks the cap (via KeycapView's compact path), and
    // drops the label font 11pt → 10pt so the chip lands at the same
    // ~18pt envelope.

    func testHotkeyHintViewCompactInitPreservesContents() {
        // Compact flag must not change the data model — only visual chrome.
        let hint = HotkeyHintView(
            label: "Quit",
            keys: [HotkeyGlyph.option, "Q"],
            compact: true
        )
        XCTAssertEqual(hint.label, "Quit")
        XCTAssertEqual(hint.keys, [HotkeyGlyph.option, "Q"])
        XCTAssertTrue(hint.compact)
    }

    func testHotkeyHintViewDefaultIsNotCompact() {
        // Back-compat: existing callsites that don't pass `compact:` get
        // the standard chrome.
        let hint = HotkeyHintView(label: "Quit", keys: [HotkeyGlyph.option, "Q"])
        XCTAssertFalse(hint.compact)
    }

    func testCompactHotkeyHintRendersInsideHostingControllerWithoutCrashing() {
        // Smoke: compact-mode chip still lays out inside an NSHostingController.
        let hosting = NSHostingController(
            rootView: HotkeyHintView(
                label: "Quit",
                keys: [HotkeyGlyph.option, "Q"],
                compact: true
            )
        )
        XCTAssertNotNil(hosting.view)
    }

    func testCompactHotkeyHintWithHeterogeneousContentsRenders() {
        // Compact + mixed text/symbol caps (used by the Useful Links rolling
        // hint) still lays out.
        let hosting = NSHostingController(
            rootView: HotkeyHintView(
                label: "Open",
                contents: [.text(HotkeyGlyph.option), HotkeyGlyph.chevronRight],
                compact: true
            )
        )
        XCTAssertNotNil(hosting.view)
    }

    // MARK: - Container-less tiny variants (.bare API option + .keycaps hover shape)
    //
    // The five Hover-panel slot hints (⌥1..⌥5) sit ABOVE each tile, ~half the
    // compact size, with NO outer capsule/pill/material wrapper. They render
    // as `.keycaps` — each glyph in its own mini chip; `.bare` (loose glyphs,
    // no chips at all) remains an API option with no production callsites
    // today. Both stay inside the single `HotkeyHintView` entry point so
    // `docs/hotkey.md` ("UI представление через HotkeyHintView") holds.
    // Visual placement/legibility is deferred to the user handoff; these
    // tests pin the data + accessibility the container-less paths preserve.

    func testDefaultStyleIsContainer() {
        // Back-compat: existing callsites keep the capsule container.
        let hint = HotkeyHintView(label: "Quit", keys: [HotkeyGlyph.option, "Q"])
        XCTAssertEqual(hint.style, .container)
    }

    func testBareStyleInitStoresStyleAndSize() {
        // `.bare` + `.tiny` stores both knobs as given (the production
        // hover-slot hint itself uses `.keycaps` — see the smoke below).
        let hint = HotkeyHintView(
            contents: [.text(HotkeyGlyph.option), .text("1")],
            style: .bare,
            size: .tiny
        )
        XCTAssertEqual(hint.style, .bare)
        XCTAssertEqual(hint.size, .tiny)
        // Data model is untouched — bare/tiny is pure chrome.
        XCTAssertEqual(hint.contents, [.text(HotkeyGlyph.option), .text("1")])
    }

    func testBareStyleDoesNotShowContainer() {
        // The whole point of `.bare`: no surrounding capsule affordance.
        // Container visibility is derived from the style so a regression that
        // re-introduces the pill trips here.
        let bare = HotkeyHintView(
            contents: [.text(HotkeyGlyph.option), .text("1")],
            style: .bare,
            size: .tiny
        )
        XCTAssertFalse(bare.showsContainer)

        let standard = HotkeyHintView(label: "Quit", keys: [HotkeyGlyph.option, "Q"])
        XCTAssertTrue(standard.showsContainer)
    }

    func testBareTinyHintPreservesCombinedAccessibilityLabel() {
        // VoiceOver must still announce the shortcut in one swipe even with
        // the container stripped (extension of invariant #3 accessibility).
        let hint = HotkeyHintView(
            contents: [.text(HotkeyGlyph.option), .text("3")],
            style: .bare,
            size: .tiny
        )
        XCTAssertEqual(hint.combinedAccessibilityLabel, "Option key, 3 key")
    }

    func testBareTinyHintRendersInsideHostingControllerWithoutCrashing() {
        // Smoke: bare style + tiny size + positional ⌥N caps lay out without
        // throwing. (No longer the hover-slot hint's shape — that's `.keycaps`,
        // smoked right below.)
        for digit in ["1", "2", "3", "4", "5"] {
            let hosting = NSHostingController(
                rootView: HotkeyHintView(
                    contents: [.text(HotkeyGlyph.option), .text(digit)],
                    style: .bare,
                    size: .tiny
                )
            )
            XCTAssertNotNil(hosting.view)
        }
    }

    func testKeycapsTinyHintRendersInsideHostingControllerWithoutCrashing() {
        // Smoke: the exact shape the Dynamic Island hover-slot hint uses —
        // `.keycaps` style, tiny size, positional ⌥N caps. This is the first
        // production path where a `.tiny` cap actually draws its Material
        // chip, so pin that the hosting layout survives.
        for digit in ["1", "2", "3", "4", "5"] {
            let hosting = NSHostingController(
                rootView: HotkeyHintView(
                    contents: [.text(HotkeyGlyph.option), .text(digit)],
                    style: .keycaps,
                    size: .tiny
                )
            )
            XCTAssertNotNil(hosting.view)
        }
    }

    func testCompactBackCompatMapsToCompactSizeAndContainerStyle() {
        // The boolean `compact:` init is a shim: compact == compact-sized,
        // container-styled chip. Existing callsites get exactly that.
        let hint = HotkeyHintView(label: "Quit", keys: [HotkeyGlyph.option, "Q"], compact: true)
        XCTAssertEqual(hint.size, .compact)
        XCTAssertEqual(hint.style, .container)
    }

    // MARK: - .keycaps style (Hover-slot keycap-pair hints)

    func testKeycapsStyleStripsContainerButKeepsCapChips() {
        // `.keycaps` = no outer capsule (like `.bare`), but every cap draws its
        // own mini chip. The Hover-slot hints use this so [⌥][1] reads as two
        // tiny keys rather than loose glyphs.
        let hint = HotkeyHintView(
            contents: [.text("⌥"), .text("1")],
            style: .keycaps,
            size: .tiny
        )
        XCTAssertFalse(hint.showsContainer)
        XCTAssertEqual(hint.capChrome, .chip)
    }

    func testBareStyleKeepsAutomaticCapChrome() {
        // `.bare` must not change cap chrome — tiny caps stay bare glyphs, as
        // before. Only `.keycaps` forces the chip.
        let hint = HotkeyHintView(
            contents: [.text("⌥"), .text("1")],
            style: .bare,
            size: .tiny
        )
        XCTAssertEqual(hint.capChrome, .automatic)
    }
}
