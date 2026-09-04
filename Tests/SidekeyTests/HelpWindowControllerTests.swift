import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class HelpWindowControllerTests: XCTestCase {
    func testInstantiatesWithoutCrashing() {
        let controller = HelpWindowController()

        XCTAssertNotNil(controller.window)
    }

    func testLearningCenterPointsAtTheProjectReadme() {
        XCTAssertEqual(
            HelpWindowContent.learningCenterURL.absoluteString,
            BuildConfig.landingURL.appendingPathComponent("blob/main/README.md").absoluteString
        )
    }

    func testDisconnectedHelpRowsOmitAgentShortcuts() {
        let rows = HelpWindowContent.hotkeyRows(
            for: .defaults,
            includeAgent: false
        )

        XCTAssertFalse(rows.contains { $0.title.hasPrefix("Agent") })
        XCTAssertTrue(rows.contains { $0.title == "Drop — voice" })
    }

    func testHelpWindowDocumentsUnifiedHistoryHotkey() {
        // ROO-208: the three per-mode `⌥1` / `⌥2` / `⌥3` rows were
        // collapsed into a single "History" row for `⌥V`. The unified
        // strip exposes filter selection via an in-strip sidebar.
        let rows = HelpWindowContent.hotkeyRows

        XCTAssertTrue(rows.contains(HelpHotkeyRowSpec(
            title: "History",
            detail: "Open the bottom strip with clipboard, voice drops, and agent history.",
            iconName: "clock",
            prefix: nil,
            contents: [.text(HotkeyGlyph.option), .text("V")]
        )))

        // Old rows must NOT be present.
        XCTAssertFalse(
            rows.contains(where: { $0.title == "Agent history" }),
            "Agent history row removed by ROO-208"
        )
        XCTAssertFalse(
            rows.contains(where: { $0.title == "Drop history" }),
            "Drop history row removed by ROO-208"
        )
        XCTAssertFalse(
            rows.contains(where: { $0.title == "Clipboard history" }),
            "Clipboard history row removed by ROO-208"
        )
    }

    func testHelpWindowDocumentsEscapeCloseHotkey() {
        // Guaranteed-Esc close: the agent answer window registers a fixed
        // Carbon Escape hotkey while it is up, so Escape must be discoverable
        // as a canonical Help row alongside the ⌥Q close.
        let rows = HelpWindowContent.hotkeyRows

        XCTAssertTrue(rows.contains(HelpHotkeyRowSpec(
            title: "Close",
            detail: "Press Escape to close the Agent response window.",
            iconName: "escape",
            prefix: nil,
            contents: [.text("Esc")]
        )))
    }

    func testHelpWindowRowsReflectHotkeyConfiguration() {
        let rows = HelpWindowContent.hotkeyRows(for: HotkeyConfiguration(
            agentGestureKey: .rightOption,
            dropVoiceTapCombo: .optionPeriod,
            agentCloseCombo: .optionD,
            usefulLinksInsertCombo: .optionSpace,
            usefulLinksOpenCombo: .optionSlash,
            usefulLinksNextCombo: .optionSpace,
            usefulLinksPreviousCombo: .optionQ
        ))

        // dropVoiceGesture=.tap → normalizedDropGesture=.tap (not holdSpace) →
        // voiceTitle="Toggle" — the Help row detail reflects the gesture label.
        XCTAssertTrue(rows.contains(HelpHotkeyRowSpec(
            title: "Drop — voice",
            detail: "Toggle voice dictation. Transcript is pasted into the active app.",
            iconName: "mic",
            prefix: nil,
            contents: [.text(HotkeyGlyph.option), .text(".")]
        )))
        XCTAssertTrue(rows.contains(HelpHotkeyRowSpec(
            title: "Agent — text",
            detail: "Right Option — tap to open the input panel and type.",
            iconName: "sparkles",
            prefix: nil,
            contents: [.prefixedGlyph(prefix: "right", glyph: HotkeyGlyph.option, accessibilityLabel: "Right Option key")]
        )))
        XCTAssertTrue(rows.contains(HelpHotkeyRowSpec(
            title: "Agent — voice",
            detail: "Right Option — hold voice command.",
            iconName: "waveform",
            prefix: nil,
            contents: [.prefixedGlyph(prefix: "right", glyph: HotkeyGlyph.option, accessibilityLabel: "Right Option key")]
        )))
        XCTAssertTrue(rows.contains(HelpHotkeyRowSpec(
            title: "Agent close",
            detail: "Close the Agent response window.",
            iconName: "xmark.circle",
            prefix: nil,
            contents: [.text(HotkeyGlyph.option), .text("D")]
        )))
        // The bare-Escape close row is fixed (not derived from the
        // configuration) — it must appear regardless of the chosen combos.
        XCTAssertTrue(rows.contains(HelpHotkeyRowSpec(
            title: "Close",
            detail: "Press Escape to close the Agent response window.",
            iconName: "escape",
            prefix: nil,
            contents: [.text("Esc")]
        )))
        XCTAssertTrue(rows.contains(HelpHotkeyRowSpec(
            title: "Useful Links — insert",
            detail: "Paste the selected link's URL into the previously focused app.",
            iconName: "square.and.arrow.down.on.square",
            prefix: nil,
            contents: [.text(HotkeyGlyph.option), .text("Space")]
        )))
        XCTAssertTrue(rows.contains(HelpHotkeyRowSpec(
            title: "Useful Links — open",
            detail: "Open the selected link in the default browser.",
            iconName: "arrow.up.right.square",
            prefix: nil,
            contents: [.text(HotkeyGlyph.option), .text("/")]
        )))
        XCTAssertTrue(rows.contains(HelpHotkeyRowSpec(
            title: "Useful Links — down",
            detail: "Move the selection marker to the next link in the list.",
            iconName: "arrow.down",
            prefix: nil,
            contents: [.text(HotkeyGlyph.option), .text("Space")]
        )))
        XCTAssertTrue(rows.contains(HelpHotkeyRowSpec(
            title: "Useful Links — up",
            detail: "Move the selection marker to the previous link in the list.",
            iconName: "arrow.up",
            prefix: nil,
            contents: [.text(HotkeyGlyph.option), .text("Q")]
        )))
    }

    func testHelpWindowDocumentsGoogleRows() {
        // Google — text: R-Option tap opens the search field.
        // Google — voice: R-Option hold (default) speaks a search query.
        // Both rows must appear in the default configuration.
        let rows = HelpWindowContent.hotkeyRows

        XCTAssertTrue(rows.contains(HelpHotkeyRowSpec(
            title: "Google — text",
            detail: "Right Option — tap to open the search field and type.",
            iconName: "magnifyingglass",
            prefix: nil,
            contents: [.prefixedGlyph(prefix: "right", glyph: HotkeyGlyph.option, accessibilityLabel: "Right Option key")]
        )))
        XCTAssertTrue(rows.contains(HelpHotkeyRowSpec(
            title: "Google — voice",
            detail: "Right Option — hold voice search.",
            iconName: "magnifyingglass",
            prefix: nil,
            contents: [.prefixedGlyph(prefix: "right", glyph: HotkeyGlyph.option, accessibilityLabel: "Right Option key")]
        )))
    }
}
