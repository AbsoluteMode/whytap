import Carbon.HIToolbox
import XCTest
@testable import Sidekey

@MainActor
final class HotkeysSettingsViewTests: XCTestCase {
    func testHotkeyRecordingStaysActiveAfterSecondKeyUntilExplicitFinish() throws {
        let source = try hotkeysSettingsViewSource()

        XCTAssertFalse(source.contains("Press keys"))
        XCTAssertFalse(source.contains("recordingContents = combo.contents\n            stopRecording()"))
    }

    func testHotkeyRowsRenderGestureAsShortcutSlotInsteadOfTitleBadge() throws {
        let source = try hotkeysSettingsViewSource()

        XCTAssertTrue(source.contains("ShortcutGestureSlot"))
        XCTAssertTrue(source.contains("ShortcutKeySlot"))
        XCTAssertFalse(source.contains(".frame(width: 96)"))
    }

    func testUsefulLinksInsertAndOpenAreEditableRows() throws {
        let source = try hotkeysSettingsViewSource()

        XCTAssertTrue(source.contains("title: \"Links insert\""))
        XCTAssertTrue(source.contains("title: \"Links open\""))
        XCTAssertTrue(source.contains("case usefulLinksInsert"))
        XCTAssertTrue(source.contains("case usefulLinksOpen"))
    }

    func testDropRowIsRecordableWithoutHoldSpacePreset() throws {
        // B3: preset chip «Hold Space» removed. The recorder (bare Space →
        // `.holdSpace`, B1) is now the only path back to the default; the
        // row still wires the recorder and its gesture switch is live for
        // combos. `resetDropToHoldSpace()` is gone from the view source.
        let source = try hotkeysSettingsViewSource()

        XCTAssertTrue(source.contains("title: \"Drop voice\""))
        // Drop still starts the recorder.
        XCTAssertTrue(source.contains("onRecord: { startRecording(.dropVoice) }"))
        XCTAssertTrue(source.contains("isRecording: recordingTarget == .dropVoice"))
        // Preset chip and its fields are gone.
        XCTAssertFalse(source.contains("presetLabel: \"Hold Space\""))
        XCTAssertFalse(source.contains("presetLabel"))
        XCTAssertFalse(source.contains("ShortcutPresetSlot"))
        // resetDropToHoldSpace no longer called from the view (preset gone).
        XCTAssertFalse(source.contains("resetDropToHoldSpace()"))
        // The Drop row is no longer rendered as a display-only chip.
        XCTAssertFalse(source.contains("displayOnly: true"))
    }

    func testDropAssignmentUsesSetDropShortcut() throws {
        // B2/B3: the Settings view routes every Drop recorder result through
        // `setDropShortcut`. The gesture switch is now live for combos (B3).
        let source = try hotkeysSettingsViewSource()

        XCTAssertTrue(source.contains("draft.setDropShortcut(shortcut)"))
        XCTAssertFalse(source.contains("draft.setDropCombo"))
        // B3: gesture switch enabled — the onGestureChange closure is wired.
        XCTAssertTrue(source.contains("onGestureChange: { draft.dropVoiceGesture"))
    }

    // MARK: - B3 new tests

    func testDropGestureSwitchEnabledForComboLockedForHoldSpace() {
        XCTAssertTrue(HotkeysSettingsView.dropGestureSwitchEnabled(shortcut: .combo(.optionSlash)))
        XCTAssertFalse(HotkeysSettingsView.dropGestureSwitchEnabled(shortcut: .holdSpace))
    }

    func testVoiceGestureTitleUsesToggleForTap() {
        XCTAssertEqual(HotkeysSettingsView.voiceGestureTitle(for: .tap), "Toggle")
        XCTAssertEqual(HotkeysSettingsView.voiceGestureTitle(for: .hold), "Hold")
    }

    func testDropDetailWarnsForBareKeyToggle() {
        let bareTab = HotkeyShortcut.combo(HotkeyTapCombo(keyCode: UInt32(kVK_Tab), modifiers: 0, keyTitle: "Tab"))
        let detail = HotkeysSettingsView.dropDetail(for: .tap, shortcut: bareTab)
        XCTAssertTrue(detail.contains("stops typing"), "bare key + toggle must warn about global grab")

        let holdSpaceDetail = HotkeysSettingsView.dropDetail(for: .hold, shortcut: .holdSpace)
        XCTAssertTrue(holdSpaceDetail.contains("hold-only"), "Space row must explain why toggle is locked")

        let comboDetail = HotkeysSettingsView.dropDetail(for: .tap, shortcut: .combo(.optionSlash))
        XCTAssertFalse(comboDetail.contains("stops typing"), "modifier combo must not warn about global grab")
    }

    func testHoldSpaceRejectedOnNonDropTargets() throws {
        // Review addition: `.holdSpace` is only valid for Drop. The source must
        // gate it — either via the allowsHoldSpace helper or an inline guard —
        // so non-Drop targets silently ignore it in assignShortcut.
        let source = try hotkeysSettingsViewSource()
        XCTAssertTrue(
            source.contains("allowsHoldSpace(target: target)") ||
            source.contains("guard shortcut != .holdSpace"),
            "non-Drop targets must reject .holdSpace in assignShortcut"
        )
    }

    func testBareKeyWarningAppearsOnAllRows() throws {
        // Review addition (functional): every non-Drop row assembles its detail
        // through `rowDetail(base:for:)`, which appends the shared
        // `bareKeyCaption` when the row's CURRENT binding is a bare printable
        // combo. Call sites: agent text, agent voice, google x2, meeting
        // record, links x4, agent close, and the hover-slot row builder (one
        // site serving five rows). Drop is deliberately excluded —
        // `dropDetail` owns its warning (bare+tap only; bare+hold rides the
        // swallow, typing kept).
        let source = try hotkeysSettingsViewSource()
        let rowDetailCallCount = source.components(separatedBy: "Self.rowDetail(").count - 1
        XCTAssertEqual(
            rowDetailCallCount, 11,
            "every non-Drop row must assemble detail via rowDetail (10 fixed rows + hover builder)"
        )
        // Single copy source: both assembly paths delegate to bareKeyCaption.
        XCTAssertTrue(source.contains("bareKeyCaption(for: shortcut)"),
                      "rowDetail and dropDetail must share the bareKeyCaption copy")
        // Drop keeps its own detail assembly — no double-warn through rowDetail.
        // (It reads the normalized display gesture; see
        // testDropRowDisplayNormalizesStaleHoldSpaceTap.)
        XCTAssertTrue(source.contains("detail: Self.dropDetail(for: displayedDropGesture"))
        // Literal ban: a future row added with a raw string detail would
        // silently skip the bare-key warning. (hoverSlotRow's base lives in a
        // separate `baseDetail` let, so this stays clean by construction.)
        XCTAssertFalse(source.contains("detail: \""),
                       "row details must flow through rowDetail/dropDetail, not string literals")
    }

    func testBareKeyCaptionBoundaries() {
        // Bare printable key (Tab) → warn.
        let bareTab = HotkeyShortcut.combo(HotkeyTapCombo(keyCode: UInt32(kVK_Tab), modifiers: 0, keyTitle: "Tab"))
        XCTAssertNotNil(HotkeysSettingsView.bareKeyCaption(for: bareTab),
                        "bare printable key must produce the caption")

        // Modifier combo → clean (Carbon grabs it, but it never typed anything bare).
        XCTAssertNil(HotkeysSettingsView.bareKeyCaption(for: .combo(.optionSlash)))
        // .holdSpace → clean here; its hold-only story lives in dropDetail.
        XCTAssertNil(HotkeysSettingsView.bareKeyCaption(for: .holdSpace))
        // Modifier-only binding (R-Cmd) → clean.
        XCTAssertNil(HotkeysSettingsView.bareKeyCaption(for: .modifier(.rightCommand)))
        // Bare arrows (the DEFAULT Links bindings) don't type characters —
        // the default config must not ship with four warnings out of the box.
        XCTAssertNil(HotkeysSettingsView.bareKeyCaption(for: .combo(.leftArrow)))
        // Bare F-keys don't type characters either.
        let bareF5 = HotkeyShortcut.combo(
            HotkeyTapCombo(keyCode: UInt32(kVK_F5), modifiers: 0, keyTitle: "F5")
        )
        XCTAssertNil(HotkeysSettingsView.bareKeyCaption(for: bareF5))
        // Nav keys (Home/End/PageUp/PageDown) type nothing — no warning.
        let bareHome = HotkeyShortcut.combo(
            HotkeyTapCombo(keyCode: UInt32(kVK_Home), modifiers: 0, keyTitle: "Home")
        )
        XCTAssertNil(HotkeysSettingsView.bareKeyCaption(for: bareHome),
                     "Home doesn't type a character — no warning")
        // Forward Delete erases text like Delete: a global grab breaks it,
        // so the warning stays PRESENT (copy oddity accepted by review).
        let bareForwardDelete = HotkeyShortcut.combo(
            HotkeyTapCombo(keyCode: UInt32(kVK_ForwardDelete), modifiers: 0, keyTitle: "Forward Delete")
        )
        XCTAssertNotNil(HotkeysSettingsView.bareKeyCaption(for: bareForwardDelete),
                        "Forward Delete is grabbed and stops deleting — warn")
    }

    func testDropRowDisplayNormalizesStaleHoldSpaceTap() throws {
        // Stale persisted `.holdSpace`+`.tap` (written by builds predating the
        // hold-only normalization) must not render a locked switch labeled
        // "Toggle" next to hold-only detail. The display path normalizes via
        // `HotkeyConfiguration.normalizedDropGesture` (single source) first.
        let displayed = HotkeyConfiguration.normalizedDropGesture(shortcut: .holdSpace, gesture: .tap)
        XCTAssertEqual(HotkeysSettingsView.voiceGestureTitle(for: displayed), "Hold")
        // Wiring: the Drop row reads the normalized gesture, not raw draft state.
        let source = try hotkeysSettingsViewSource()
        XCTAssertTrue(source.contains("displayedDropGesture"),
                      "Drop row must render the normalized gesture under stale state")
        XCTAssertTrue(source.contains("normalizedDropGesture"),
                      "normalization must reuse HotkeyConfiguration.normalizedDropGesture")
    }

    func testRowDetailAppendsCaptionOnlyForBarePrintable() {
        let base = "Close the Agent response window."
        let bareTab = HotkeyShortcut.combo(HotkeyTapCombo(keyCode: UInt32(kVK_Tab), modifiers: 0, keyTitle: "Tab"))

        let warned = HotkeysSettingsView.rowDetail(base: base, for: bareTab)
        XCTAssertTrue(warned.hasPrefix(base), "caption is appended, base stays first")
        XCTAssertTrue(warned.contains("stops typing"),
                      "non-Drop bare binding must surface the caption regardless of gesture")

        XCTAssertEqual(HotkeysSettingsView.rowDetail(base: base, for: .combo(.optionQ)), base,
                       "modifier combo keeps the base detail untouched")
    }

    func testDropDetailDoesNotWarnForBareKeyHold() {
        // Bare+hold Drop rides the CGEventTap swallow — typing is preserved,
        // so no caption. On Drop the warning is tap-only.
        let bareTab = HotkeyShortcut.combo(HotkeyTapCombo(keyCode: UInt32(kVK_Tab), modifiers: 0, keyTitle: "Tab"))
        let detail = HotkeysSettingsView.dropDetail(for: .hold, shortcut: bareTab)
        XCTAssertFalse(detail.contains("stops typing"))
    }

    // Bare Delete recordability is pinned functionally in
    // `HotkeyRecorderBareKeyTests.testBareNavigationKeysRecordReadableTitles`
    // (kVK_Delete + DEL control char -> keyTitle "Delete").

    func testGestureSlotUsesCustomTitleNotGestureTitle() throws {
        // B3: ShortcutGestureSlot now takes a `title: String` (not `gesture:
        // HotkeyGesture`) so the display label is decoupled from the model value.
        let source = try hotkeysSettingsViewSource()
        XCTAssertTrue(source.contains("gestureTitle ?? gesture.title") || source.contains("title: gestureTitle"),
                      "HotkeySettingRow must forward gestureTitle into the gesture slot")
    }

    func testPerFieldConflictHighlightMatchesByConflictKey() throws {
        // Stage 1 review fix: per-row conflict highlight must compare on the
        // physical-key identity (`conflictKey`), not the full `HotkeyBinding`,
        // so both members of a combo tap/hold conflict are flagged.
        let source = try hotkeysSettingsViewSource()

        XCTAssertTrue(source.contains("$0.binding.conflictKey == conflictKey"))
        XCTAssertFalse(source.contains("$0.binding == binding"))
    }

    func testAgentRowsUseSameShortcutRecorderAsOtherRows() throws {
        let source = try hotkeysSettingsViewSource()

        XCTAssertTrue(source.contains("fallback: draft.agentTextShortcut.contents"))
        XCTAssertTrue(source.contains("fallback: draft.agentVoiceShortcut.contents"))
        XCTAssertFalse(source.contains("assignAgentKey"))
        XCTAssertFalse(source.contains("case .agentText, .agentVoice:"))
    }

    func testHotkeysUseMacReskinChrome() throws {
        let source = try hotkeysSettingsViewSource()

        // Footer actions and surfaces moved to the macOS kit / theme tokens.
        XCTAssertTrue(source.contains("MacButton"))
        XCTAssertTrue(source.contains("MacSettingsTheme"))
    }

    func testSettingsExposesFiveEditableHoverRows() throws {
        // Stage 4 (ROO-210): each of the five positional Hover slots gets an
        // editable row. The `RecordingTarget` enum gains five cases (consumed by
        // the `assignShortcut` / `shortcut(for:)` / `binding(for:)` switches) and
        // the rows are driven positionally off `hoverSlotTargets`. (Behaviour of
        // each branch is verified on live objects in `HoverHintsTests`.)
        let source = try hotkeysSettingsViewSource()

        for slot in 1...5 {
            XCTAssertTrue(
                source.contains("case hoverSlot\(slot)"),
                "RecordingTarget missing hoverSlot\(slot)"
            )
        }
        // Positional rows: a slot-indexed section maps each position to its
        // `RecordingTarget` and starts the SAME recorder every other row uses.
        XCTAssertTrue(source.contains("hoverSlotSection"))
        XCTAssertTrue(source.contains("hoverSlotTargets"))
        XCTAssertTrue(source.contains("startRecording(target)"))
        // Rows read their title/icon from the LIVE layout store position, not a
        // hardcoded label (D1 positional).
        XCTAssertTrue(source.contains("hoverLayout.slots[offset]"))
        XCTAssertTrue(source.contains("HoverToolRegistry.info(for: tool)"))
    }

    func testSlotFiveHotkeyEditableButToolFixedToSettings() throws {
        // D2: the 5th hover row's KEY is editable like every other slot (it
        // flows through the shared `startRecording(target)` path and the
        // `.hoverSlot5` switch branch), but its tool is fixed to Settings
        // (`HoverLayoutStore.lockSlotIndex` = position 5). The row must NOT
        // offer a tool/action picker — only Toolbox reorders tools, and the
        // lock keeps slot 5 on `.settings` even there.
        let source = try hotkeysSettingsViewSource()

        // Key editable: slot 5 is a normal RecordingTarget branch.
        XCTAssertTrue(source.contains("case .hoverSlot5"))
        // The locked-slot fact is referenced so the row reflects the fixed tool
        // rather than pretending it is changeable.
        XCTAssertTrue(source.contains("HoverLayoutStore.lockSlotIndex"))
        XCTAssertTrue(source.contains("isLocked"))
    }

    func testHoverRowsHighlightConflictByConflictKey() throws {
        // Stage 1 conflict model carries over: a hover row's per-field
        // highlight matches on `conflictKey` (combo ignores gesture), so a ⌥N
        // collision flags both members. The hover rows reuse the same
        // `hasConflict(for:)` / `binding(for:)` helpers via their target.
        let source = try hotkeysSettingsViewSource()
        XCTAssertTrue(source.contains("hasConflict(for: target)"))
        XCTAssertTrue(source.contains("$0.binding.conflictKey == conflictKey"))
    }

    func testRecordingMonitorListensForKeyUp() throws {
        // Release-to-commit needs keyUp; the local monitor and the event guard
        // must both admit .keyUp or a bare key (no modifier release) never commits.
        let src = try hotkeysSettingsViewSource()
        XCTAssertTrue(
            src.contains("matching: [.keyDown, .keyUp, .flagsChanged]"),
            "startRecording must listen for keyUp (release-to-commit)."
        )
        XCTAssertTrue(
            src.contains("event.type == .keyUp"),
            "handleRecordingEvent must pass keyUp through to the recorder."
        )
    }

    private func hotkeysSettingsViewSource() throws -> String {
        let root = try projectRoot()
        let url = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Hotkeys")
            .appendingPathComponent("HotkeysSettingsView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "HotkeysSettingsViewTests", code: 1)
    }
}
