import XCTest
@testable import Sidekey

final class IslandHoverPanelControlTests: XCTestCase {
    func test_notificationSlotIsTopAlignedWithIslandSurface() throws {
        let source = try Self.source(
            "Sources/Sidekey/DynamicIsland/IslandView.swift"
        )

        XCTAssertTrue(
            source.contains("HStack(alignment: .top, spacing: 0)"),
            "The notification slot must top-align with the island; default HStack center alignment drops the pill below the notch."
        )
    }

    func test_hoverPanelControlsUseOriginalButtonActionPath() throws {
        let source = try Self.source(
            "Sources/Sidekey/DynamicIsland/IslandView.swift"
        )
        let controlSource = try XCTUnwrap(
            Self.structBody(named: "IslandHoverPanelControl", in: source)
        )

        XCTAssertTrue(
            controlSource.contains("Button(action: action)"),
            "Hover panel controls should use the original SwiftUI Button path."
        )
        XCTAssertFalse(
            controlSource.contains(".onTapGesture { action() }"),
            "The tap-gesture experiment disabled hover button behavior on the real panel."
        )
    }

    func test_historyPanelModeGetsTallHoverBand() throws {
        // History renders ~267pt of content; the default hover band is 145pt.
        // The view must size the band per panel mode AND report the change to
        // the AppKit panel — otherwise the lower half of the History panel is
        // outside the window's hit-test band and ignores hover/clicks.
        let viewSource = try Self.source(
            "Sources/Sidekey/DynamicIsland/IslandView.swift"
        )
        XCTAssertTrue(viewSource.contains("var activeHoverPanelHeight"))
        // The island stack's reserved height is sized PER PANEL MODE: the
        // mode-dependent `activeHoverPanelHeight` feeds the stack frame, so the
        // History mode's tall band grows the hit region.
        XCTAssertTrue(viewSource.contains("+ activeHoverPanelHeight"))
        XCTAssertTrue(viewSource.contains("onHoverPanelBandHeightChange("))

        let panelSource = try Self.source(
            "Sources/Sidekey/DynamicIsland/IslandPanel.swift"
        )
        XCTAssertTrue(panelSource.contains("onHoverPanelBandHeightChange:"))
        XCTAssertTrue(panelSource.contains("func setHoverBandHeight"))
    }

    func test_historyEnterPasteReleasesKeyWindowBeforeCmdV() throws {
        // Same trap the bottom strip documents in `handleEnterPaste`: while
        // the island panel stays key, the synth Cmd+V lands in the panel
        // (system beep, no paste). Switching back to `.controls` rides the
        // existing `needsKeyboardFocus` channel → `resignKey` → AppKit hands
        // key back to the paste target before the pipeline posts Cmd+V.
        let source = try Self.source(
            "Sources/Sidekey/DynamicIsland/IslandView.swift"
        )
        XCTAssertTrue(source.contains("onPasteHistoryCard(card)"))
        XCTAssertTrue(source.contains("panelMode = .controls  // release key before synth Cmd+V"))
    }

    func test_historyHoverPreviewBubbleIsWiredOutsideTheClippedDrawer() throws {
        let source = try Self.source(
            "Sources/Sidekey/DynamicIsland/IslandView.swift"
        )
        XCTAssertTrue(source.contains("coordinateSpace(name: Self.hoverZoneSpace)"))
        XCTAssertTrue(source.contains("HistoryHoverPreviewBubble("))
        XCTAssertTrue(source.contains("historyPreviewAnchor"))
        XCTAssertTrue(
            source.contains(".allowsHitTesting(false)"),
            "The bubble is a purely visual layer — window mouse routing must stay untouched."
        )
    }

    func test_historyEntryCapturesPasteTargetViaPanelModeTransition() throws {
        // D1 + #313: the ⌥N Hover-slot hotkey for History opens the panel by
        // setting `hoverPanelMode = .history` programmatically (no tile-click
        // closure runs), so the paste-target capture MUST live on the
        // `panelMode` transition into `.history` — not only in the tile click —
        // otherwise the hotkey path opens History with `historyTargetAppName ==
        // nil` and Enter-to-paste silently no-ops while the click path works.
        let source = try Self.source(
            "Sources/Sidekey/DynamicIsland/IslandView.swift"
        )
        let panelSource = try XCTUnwrap(
            Self.structBody(named: "IslandDropModeHoverPanel", in: source)
        )

        // Capture runs from the panel-mode transition (shared by click + ⌥N),
        // not from the tile-click closure alone.
        XCTAssertTrue(
            panelSource.contains("if newMode == .history"),
            "History paste-target capture must hang off the panelMode -> .history transition so the ⌥N hotkey path captures it like a click does."
        )
        XCTAssertTrue(
            panelSource.contains("historyMode = onOpenHistory()"),
            "Entering History must capture the paste target + remembered mode via onOpenHistory()."
        )
        XCTAssertTrue(
            panelSource.contains("historyTargetAppName = historyPasteTargetName()"),
            "Entering History must record the validated paste-target app name for the Enter-to-paste affordance."
        )
    }

    func test_hoverPanelHasCaseVaultModeAndTile() throws {
        let source = try Self.source(
            "Sources/Sidekey/DynamicIsland/IslandView.swift"
        )

        XCTAssertTrue(source.contains("case caseVault"))
        XCTAssertTrue(source.contains("IslandCaseVaultPanel("))
        XCTAssertTrue(source.contains("title: \"Case\""))
        XCTAssertTrue(source.contains("panelMode = .caseVault"))
    }

    func test_hideButtonGatesHoverWidgetsButKeepsCompactMusicWing() throws {
        let source = try Self.source(
            "Sources/Sidekey/DynamicIsland/IslandView.swift"
        )

        XCTAssertTrue(source.contains("IslandHideButton("))
        XCTAssertTrue(source.contains("eye.slash.fill"))
        XCTAssertTrue(source.contains("displayPreferences.hideIslandHoverWidgets"))
        XCTAssertTrue(
            source.contains("!displayPreferences.hideIslandHoverWidgets"),
            "Closed eye must prevent hover expansion."
        )
        // The compact right-band wing is eye-INDEPENDENT: closing the eye must
        // NOT remove it (only the hover player widget is hidden).
        XCTAssertTrue(
            source.contains("nowPlaying: compactNowPlaying"),
            "The compact music wing must read the eye-independent playback source."
        )
        XCTAssertTrue(
            source.contains("IslandMusicRouting.compactWingNowPlaying"),
            "Compact wing playback must route through the eye-independent helper."
        )
        // The hover player widget (the card between island and drawer) IS gated.
        XCTAssertTrue(
            source.contains("if let nowPlaying = hoverNowPlaying"),
            "The hover player widget must read through the eye-gated source."
        )
        XCTAssertTrue(
            source.contains("IslandMusicRouting.hoverWidgetNowPlaying"),
            "Hover widget playback must route through the eye-gated helper."
        )
    }

    func test_hideButtonReplacesOrbWithoutGlassChrome() throws {
        let source = try Self.source(
            "Sources/Sidekey/DynamicIsland/IslandView.swift"
        )
        let buttonSource = try XCTUnwrap(
            Self.structBody(named: "IslandHideButton", in: source)
        )

        XCTAssertTrue(buttonSource.contains("compactHeight"))
        XCTAssertTrue(buttonSource.contains("orbCanvas"))
        XCTAssertFalse(buttonSource.contains(".background"))
        XCTAssertFalse(buttonSource.contains(".overlay"))
        XCTAssertFalse(buttonSource.contains(".padding(2)"))
    }

    func test_controls_uses_hoverLayoutStore_slots() throws {
        let source = try Self.source("Sources/Sidekey/DynamicIsland/IslandView.swift")
        XCTAssertTrue(source.contains("HoverLayoutStore"),
                      "controls must read from HoverLayoutStore")
        XCTAssertTrue(source.contains("hoverStore.slots"),
                      "controls must iterate hoverStore.slots")
    }

    func test_controls_keep_slot_identity_stable_when_tool_changes() throws {
        let source = try Self.source("Sources/Sidekey/DynamicIsland/IslandView.swift")

        XCTAssertTrue(
            source.contains("ForEach(Array(hoverStore.slots.enumerated()), id: \\.offset)"),
            "Hover row identity must stay tied to the slot index so replacing Case with another tool updates in place instead of animating a removal/insertion."
        )
        XCTAssertFalse(
            source.contains("ForEach(hoverStore.slots, id: \\.self)"),
            "Tool identity makes SwiftUI tear down one tile and insert another on replacement, causing a visible tail at the end of the animation."
        )
    }

    func test_hoverDescriptionUsesSmartModeLanguageContext() throws {
        let source = try Self.source("Sources/Sidekey/DynamicIsland/IslandView.swift")

        XCTAssertTrue(source.contains("HoverToolRegistry.description("))
        XCTAssertTrue(source.contains("mode: mode"))
        XCTAssertTrue(source.contains("inputLanguage: selectedLanguage"))
        XCTAssertTrue(source.contains("outputLanguage: targetLanguage"))
    }

    @MainActor
    func testHoverExpansionAnimationIsNilForProgrammaticPath() {
        XCTAssertNil(IslandView.hoverExpansionAnimation(programmatic: true))
    }

    @MainActor
    func testHoverExpansionAnimationIsHoverMotionForMousePath() {
        XCTAssertNotNil(IslandView.hoverExpansionAnimation(programmatic: false))
    }

    func test_repeatHoverSlotHotkeyExtendsAutoCollapseWindow() throws {
        // A repeat ⌥N while the drawer is already open leaves
        // `programmaticHoverExpansion` at true (true -> true is not a change
        // event), so the expansion onChange never re-fires and the FIRST
        // press's collapse timer stays armed: ⌥3 pressed 3.5s after ⌥2 would
        // collapse the just-opened History 0.5s in. The panel request carries
        // a monotonic token, so ITS onChange fires on every press — that
        // handler must re-arm the deferred collapse via the shared helper.
        let source = try Self.source("Sources/Sidekey/DynamicIsland/IslandView.swift")

        XCTAssertTrue(
            source.contains("func armProgrammaticExpansionCollapse()"),
            "The auto-collapse timer body must live in one shared helper so both onChange paths arm the same window."
        )

        let requestHandler = try XCTUnwrap(
            Self.onChangeBody(observing: "appState.programmaticHoverPanelRequest", in: source),
            "IslandView must observe programmaticHoverPanelRequest."
        )
        XCTAssertTrue(
            requestHandler.contains("armProgrammaticExpansionCollapse()"),
            "Every ⌥N panel request must re-arm the auto-collapse window — a repeat press otherwise inherits the first press's nearly-expired timer."
        )
        XCTAssertTrue(
            requestHandler.contains("if appState.programmaticHoverExpansion {"),
            "Only a programmatic (⌥N) session runs the timer — a mouse-held drawer must not arm a deferred collapse."
        )
    }

    func test_hoverSlotHint_visibleOnlyForHoveredTile() throws {
        // A5: the ⌥N keycap hint shows only above the tile under the cursor.
        // Hidden via opacity — NOT removed from layout — so the layout slot
        // above every tile stays reserved and tiles don't jump when hover moves;
        // the fade rides the same `hoveredTool` value that animates the
        // description strip. A silent revert to always-visible hints keeps
        // every data-level test green, so pin the callsite gate itself.
        let source = try Self.source("Sources/Sidekey/DynamicIsland/IslandView.swift")
        let body = try XCTUnwrap(
            Self.varBody(named: "controls", in: source),
            "IslandView must keep the controls builder."
        )
        XCTAssertTrue(
            body.contains(".opacity(hoveredTool == tool ? 1 : 0)"),
            "Hover-slot hints must be visible only for the hovered tile, hidden via opacity so the layout slot stays reserved."
        )
        XCTAssertTrue(
            body.contains(".animation(.easeInOut(duration: 0.15), value: hoveredTool)"),
            "Hint fade must ride hoveredTool with the same 0.15s easeInOut as the description strip."
        )
    }

    func test_hoverSlotHint_rendersKeycapsPairAtTinySize() throws {
        // A3 (вариант 3): the ⌥N hint above each Hover tile is a pair of mini
        // keycaps `[⌥][N]` — `.keycaps` style (per-cap chips, no outer capsule)
        // at the `.tiny` tier. A silent revert to `.bare` (loose glyphs) keeps
        // every data-level test green, so pin the callsite itself.
        let source = try Self.source("Sources/Sidekey/DynamicIsland/IslandView.swift")
        let hintBody = try XCTUnwrap(
            Self.funcBody(named: "hoverSlotHint", in: source),
            "IslandView must keep the hoverSlotHint(for:) builder."
        )
        XCTAssertTrue(
            hintBody.contains("style: .keycaps"),
            "Hover-slot hints must render each glyph in its own mini keycap (style: .keycaps)."
        )
        XCTAssertTrue(
            hintBody.contains("size: .tiny"),
            "Hover-slot hints stay at the .tiny cap tier."
        )
    }

    private static func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func structBody(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "struct \(name): View") else {
            return nil
        }
        return Self.braceMatchedBlock(from: start.lowerBound, in: source)
    }

    /// Body of the named function — same brace-matching extraction as
    /// `structBody`, anchored on the `func <name>` declaration.
    private static func funcBody(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "func \(name)") else {
            return nil
        }
        return Self.braceMatchedBlock(from: start.lowerBound, in: source)
    }

    /// Body of the named computed var — same brace-matching extraction as
    /// `structBody`, anchored on `var <name>` (matches `private var controls`).
    private static func varBody(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "var \(name)") else {
            return nil
        }
        return Self.braceMatchedBlock(from: start.lowerBound, in: source)
    }

    /// Closure body of the `.onChange(of: <keyPath>)` modifier — same
    /// brace-matching extraction as `structBody`, anchored on the observed
    /// key path instead of a type name.
    private static func onChangeBody(observing keyPath: String, in source: String) -> String? {
        guard let start = source.range(of: ".onChange(of: \(keyPath))") else {
            return nil
        }
        return Self.braceMatchedBlock(from: start.upperBound, in: source)
    }

    private static func braceMatchedBlock(
        from anchor: String.Index,
        in source: String
    ) -> String? {
        let tail = source[anchor...]
        guard let bodyStart = tail.firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var index = bodyStart
        while index < source.endIndex {
            if source[index] == "{" {
                depth += 1
            } else if source[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[bodyStart...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
