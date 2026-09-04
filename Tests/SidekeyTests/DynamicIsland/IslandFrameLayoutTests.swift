import AppKit
import XCTest
@testable import Sidekey

/// Pure-function tests for `IslandFrameLayout`. We avoid constructing a
/// real `NSScreen` (which is non-trivial — `NSScreen` has no public
/// initializer) by passing raw `CGRect` / `NSEdgeInsets` values to the
/// helper. The live `IslandPanel` call site is responsible for reading
/// those values off `NSScreen.main`.
///
/// **Geometry baseline (notched 14"/16" MBP):**
/// - `frame = {0, 0, 1512, 982}` (M1 14" Retina, points)
/// - `visibleFrame = {0, 76, 1512, 868}` (76pt Dock at bottom, 38pt menu bar at top)
/// - `safeAreaInsets.top = 38` (= notch / menu-bar height on macOS Tahoe)
/// - `auxLeft = {0, 944, 670, 38}` — top-left strip ending at notch.minX
/// - `auxRight = {842, 944, 670, 38}` — top-right strip starting at notch.maxX
/// - Notch range: `[670, 842]` (width 172, height 38, y origin 944)
final class IslandFrameLayoutTests: XCTestCase {

    // MARK: - Sizing constants

    func test_leftSideWidth_isTunablePositiveConstant() {
        // Side-panel widths are the primary visual knobs Maxim should
        // tune by hand. These broad assertions catch broken values; the
        // current visual pass has its exact baseline below.
        XCTAssertGreaterThan(IslandFrameLayout.leftSideWidth, 40)
        XCTAssertLessThan(IslandFrameLayout.leftSideWidth, 160)
    }

    func test_rightSideWidth_isTunablePositiveConstant() {
        XCTAssertGreaterThan(IslandFrameLayout.rightSideWidth, 40)
        XCTAssertLessThan(IslandFrameLayout.rightSideWidth, 240)
    }

    func test_sideBandsAddFivePointsOnEachSideOfWindow() {
        XCTAssertEqual(IslandFrameLayout.leftSideWidth, 70, accuracy: 0.001)
        XCTAssertEqual(IslandFrameLayout.rightSideWidth, 70, accuracy: 0.001)
    }

    func test_rightTriggerOrbGroupMovesSevenPointsRightFromSafeBaseline() {
        XCTAssertEqual(IslandFrameLayout.rightTriggerOrbGroupOffsetX, -3, accuracy: 0.001)
    }

    func test_hostPanelFrameExtendsBelowCompactIslandForHoverControls() {
        let compactFrame = IslandFrameLayout.islandFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )
        let hostFrame = IslandFrameLayout.hostPanelFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )

        XCTAssertEqual(hostFrame.width, compactFrame.width, accuracy: 0.001)
        XCTAssertEqual(hostFrame.maxY, compactFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(
            hostFrame.height,
            compactFrame.height + IslandDropModeControl.hoverPanelHeight,
            accuracy: 0.001
        )
        XCTAssertLessThan(hostFrame.minY, compactFrame.minY)
    }

    func test_collapsedHostPanelFrameMatchesCompactIslandForLayoutHelper() {
        let compactFrame = IslandFrameLayout.islandFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )
        let collapsedFrame = IslandFrameLayout.hostPanelFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight,
            expanded: false
        )

        XCTAssertEqual(collapsedFrame, compactFrame)
    }

    // MARK: - Agent surfaces (wing right + answer zone below)

    func test_agentWingWidths_areTunablePositiveConstants() {
        XCTAssertEqual(IslandFrameLayout.agentWingGap, 8)
        XCTAssertGreaterThan(IslandFrameLayout.agentWingRecordingWidth, 200)
        XCTAssertGreaterThan(
            IslandFrameLayout.agentWingComposingWidth,
            IslandFrameLayout.agentWingRecordingWidth
        )
        XCTAssertLessThan(
            IslandFrameLayout.agentWingActingWidth,
            IslandFrameLayout.agentWingRecordingWidth
        )
        // The failure notice carries full-sentence messages, so it is wider
        // than the collapsed "thinking…" acting slot.
        XCTAssertGreaterThan(
            IslandFrameLayout.agentWingFailedWidth,
            IslandFrameLayout.agentWingActingWidth
        )
        // The wing is flush against the capsule (no horizontal seam), so the
        // rightward window zone is exactly the widest wing face.
        XCTAssertEqual(
            IslandFrameLayout.rightAgentZoneWidth,
            IslandFrameLayout.agentWingComposingWidth
        )
        XCTAssertEqual(IslandFrameLayout.agentAnswerPanelWidth, 336)
        XCTAssertGreaterThan(IslandFrameLayout.agentAnswerZoneHeight, 400)
    }

    func test_agentWingInCapsuleWidth_isRightBandWidth() {
        // The agent phase content begins in the right band (after the notch
        // gap), so exactly `rightSideWidth` of every face is hosted INSIDE
        // the compact capsule; only the remainder grows the island form.
        XCTAssertEqual(
            IslandFrameLayout.agentWingInCapsuleWidth,
            IslandFrameLayout.rightSideWidth,
            accuracy: 0.001
        )
    }

    func test_agentWingExtension_isFaceWidthMinusInCapsulePart_clampedAtZero() {
        // Faces that fit inside the band add no extension.
        XCTAssertEqual(IslandFrameLayout.agentWingExtension(faceWidth: 0), 0, accuracy: 0.001)
        XCTAssertEqual(
            IslandFrameLayout.agentWingExtension(
                faceWidth: IslandFrameLayout.agentWingInCapsuleWidth
            ),
            0,
            accuracy: 0.001
        )
        // A face narrower than the band still clamps to 0 (never negative).
        XCTAssertEqual(
            IslandFrameLayout.agentWingExtension(
                faceWidth: IslandFrameLayout.agentWingInCapsuleWidth - 10
            ),
            0,
            accuracy: 0.001
        )

        // The live faces grow the form only by their MISSING width
        // (faceWidth - 70): recording 260 -> 190, composing 300 -> 230,
        // acting 120 -> 50, failed 220 -> 150.
        XCTAssertEqual(
            IslandFrameLayout.agentWingExtension(faceWidth: 260),
            190,
            accuracy: 0.001
        )
        XCTAssertEqual(
            IslandFrameLayout.agentWingExtension(faceWidth: 300),
            230,
            accuracy: 0.001
        )
        XCTAssertEqual(
            IslandFrameLayout.agentWingExtension(
                faceWidth: IslandFrameLayout.agentWingActingWidth
            ),
            50,
            accuracy: 0.001
        )
        XCTAssertEqual(
            IslandFrameLayout.agentWingExtension(
                faceWidth: IslandFrameLayout.agentWingFailedWidth
            ),
            150,
            accuracy: 0.001
        )
    }

    func test_agentWingRecordingExtension_matchesHelperOnRecordingWidth() {
        // The answer panel's right edge and its hit zone both key off the
        // recording-form extension; the constant must equal the general
        // helper applied to the recording face so the formula lives once.
        XCTAssertEqual(
            IslandFrameLayout.agentWingRecordingExtension,
            IslandFrameLayout.agentWingExtension(
                faceWidth: IslandFrameLayout.agentWingRecordingWidth
            ),
            accuracy: 0.001
        )
        XCTAssertEqual(IslandFrameLayout.agentWingRecordingExtension, 190, accuracy: 0.001)
    }

    func test_mergedCapsuleWidth_isCompactPlusExtension_anchoredInBand() {
        let compactWidth: CGFloat = 244

        // No extension: the merged surface is exactly the compact capsule —
        // a single black shape at the unchanged compact width, so the
        // no-agent island renders bit-for-bit as before.
        XCTAssertEqual(
            IslandFrameLayout.mergedCapsuleWidth(compactWidth: compactWidth, extension: 0),
            compactWidth,
            accuracy: 0.001
        )

        // Active face: the island form grows rightward only by the face's
        // EXTENSION (the part that doesn't fit in the right band). The first
        // `agentWingInCapsuleWidth` of the face sits inside the capsule.
        XCTAssertEqual(
            IslandFrameLayout.mergedCapsuleWidth(
                compactWidth: compactWidth,
                extension: IslandFrameLayout.agentWingExtension(
                    faceWidth: IslandFrameLayout.agentWingRecordingWidth
                )
            ),
            compactWidth + 190,
            accuracy: 0.001
        )
        // The widest face (composing) extension cannot exceed the reserved
        // right zone, so the stretched surface never overshoots the window.
        XCTAssertLessThanOrEqual(
            IslandFrameLayout.mergedCapsuleWidth(
                compactWidth: compactWidth,
                extension: IslandFrameLayout.agentWingExtension(
                    faceWidth: IslandFrameLayout.agentWingComposingWidth
                )
            ),
            compactWidth + IslandFrameLayout.rightAgentZoneWidth
        )
    }

    func test_hostPanelFrame_agentActive_extendsRightAndDown() {
        let base = IslandFrameLayout.hostPanelFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight,
            expanded: false
        )
        let agent = IslandFrameLayout.hostPanelFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight,
            expanded: false,
            agentActive: true
        )

        XCTAssertEqual(
            agent.maxX,
            base.maxX + IslandFrameLayout.rightAgentZoneWidth,
            accuracy: 0.5
        )
        XCTAssertEqual(agent.minX, base.minX, accuracy: 0.5)   // island does not slide off the notch
        XCTAssertEqual(agent.maxY, base.maxY, accuracy: 0.5)   // top stays pinned to the menu bar
        XCTAssertEqual(
            agent.height,
            base.height + IslandFrameLayout.agentWingGap + IslandFrameLayout.agentAnswerZoneHeight,
            accuracy: 0.5
        )
    }

    // MARK: - Left notification frame (morphs island leftward)

    func test_leftNotificationFrameExpandsLeftFromCompact() {
        let compact = IslandFrameLayout.islandFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )
        let expanded = IslandFrameLayout.leftNotificationFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight,
            expanded: true
        )

        XCTAssertEqual(expanded.maxX, compact.maxX, accuracy: 0.5)        // right edge stays (joined to island)
        XCTAssertEqual(expanded.maxY, compact.maxY, accuracy: 0.5)        // top-flush, same top edge
        XCTAssertLessThan(expanded.minX, compact.minX)                    // extends left
        XCTAssertEqual(
            expanded.minX,
            compact.minX - IslandFrameLayout.leftNotificationWidth,
            accuracy: 0.5
        )
        XCTAssertEqual(expanded.height, compact.height, accuracy: 0.5)    // same height as the island
    }

    func test_collapsedLeftNotificationFrameMatchesCompact() {
        let compact = IslandFrameLayout.islandFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )
        let collapsed = IslandFrameLayout.leftNotificationFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight,
            expanded: false
        )

        XCTAssertEqual(collapsed, compact)
    }

    func test_panelWindowFrameStaysExpandedAcrossHoverStateChanges() {
        let compactFrame = IslandFrameLayout.islandFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )
        let expandedFrame = IslandFrameLayout.hostPanelFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )

        XCTAssertEqual(
            IslandPanelFramePolicy.windowFrame(
                compactFrame: compactFrame,
                expandedFrame: expandedFrame,
                acceptsExpandedHitTesting: false
            ),
            expandedFrame
        )
        XCTAssertEqual(
            IslandPanelFramePolicy.windowFrame(
                compactFrame: compactFrame,
                expandedFrame: expandedFrame,
                acceptsExpandedHitTesting: true
            ),
            expandedFrame
        )
    }

    func test_panelMouseEventsIgnoreHiddenHoverAreaWhileCollapsed() {
        let compactFrame = NSRect(x: 100, y: 300, width: 312, height: 38)
        let expandedFrame = NSRect(x: 100, y: 146, width: 312, height: 192)
        // Collapsed: only the compact pill is rendered, so only it is active.
        let activeFrames = [compactFrame]

        XCTAssertFalse(
            IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                cursor: NSPoint(x: compactFrame.midX, y: compactFrame.midY),
                activeFrames: activeFrames
            ),
            "Closed island must still receive hover/clicks on the visible compact camera."
        )
        XCTAssertTrue(
            IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                cursor: NSPoint(x: expandedFrame.midX, y: expandedFrame.minY + 20),
                activeFrames: activeFrames
            ),
            "Hidden hover-panel area must be click-through while the island is collapsed."
        )
    }

    func test_panelMouseEventsAcceptExpandedHoverAreaWhileOpen() {
        let expandedFrame = NSRect(x: 100, y: 146, width: 312, height: 192)
        // Open: the expanded hover panel is rendered, so it is the active rect.
        let activeFrames = [expandedFrame]

        XCTAssertFalse(
            IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                cursor: NSPoint(x: expandedFrame.midX, y: expandedFrame.minY + 20),
                activeFrames: activeFrames
            ),
            "Open hover controls must accept clicks across the rendered expanded panel."
        )
        XCTAssertTrue(
            IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                cursor: NSPoint(x: expandedFrame.maxX + 1, y: expandedFrame.midY),
                activeFrames: activeFrames
            )
        )
    }

    func test_mouseRoutingClaimsOnlyRenderedSurfaces_notTheBoundingGap() {
        // Regression: the island is a transparent, permanently agent-sized
        // window. It must stop ignoring the mouse ONLY over actually-rendered
        // surfaces (pill, wing, answer card) — never over the empty gap between
        // them. Collapsing those rects into one bounding union turned the gap
        // into a dead zone: `ignoresMouseEvents == false` there but `hitTest`
        // returns nil, so AppKit ATE the click/scroll/selection instead of
        // passing it to the app below — for the whole drop/agent cycle.
        let island = NSRect(x: 100, y: 300, width: 312, height: 38)
        let wing = NSRect(x: 412, y: 300, width: 40, height: 38)
        let answer = NSRect(x: 100, y: 100, width: 312, height: 180)
        let active = [island, wing, answer]

        // Inside the bounding box of island ∪ wing ∪ answer, but outside each.
        let gap = NSPoint(x: 430, y: 150)
        XCTAssertTrue(
            IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(cursor: gap, activeFrames: active),
            "Empty gap between island surfaces must stay click-through (the window keeps ignoring the mouse there)."
        )

        for surface in [island, wing, answer] {
            XCTAssertFalse(
                IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                    cursor: NSPoint(x: surface.midX, y: surface.midY),
                    activeFrames: active
                ),
                "Cursor over a rendered surface (\(surface)) must claim mouse events."
            )
        }

        // Nothing rendered (idle) → the window ignores the mouse everywhere.
        XCTAssertTrue(
            IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                cursor: NSPoint(x: island.midX, y: island.midY),
                activeFrames: []
            ),
            "With no active surfaces the window must be fully click-through."
        )
    }

    func test_agentAnswerHitSize_tracksRenderedCardHeight_notFixedReservation() {
        // The answer hit-zone must match the ACTUAL rendered card height, not a
        // fixed reservation. An over-tall zone below a short answer ate clicks
        // meant for windows under the screenSaver-level island — e.g. a system
        // "OK" dialog the agent triggered sat in the empty band below the card.
        let width = IslandFrameLayout.agentAnswerPanelWidth

        XCTAssertEqual(
            IslandPanelMouseEventPolicy.agentAnswerHitSize(visible: true, contentHeight: 96, width: width),
            CGSize(width: width, height: 96),
            "Hit-zone height must equal the measured card height, not a fixed constant."
        )
        XCTAssertEqual(
            IslandPanelMouseEventPolicy.agentAnswerHitSize(visible: false, contentHeight: 96, width: width),
            .zero,
            "No answer panel → no hit-zone."
        )
        XCTAssertEqual(
            IslandPanelMouseEventPolicy.agentAnswerHitSize(visible: true, contentHeight: 0, width: width),
            .zero,
            "Before the card is measured the zone stays empty (no premature dead zone)."
        )
    }

    func test_reservedZonesClaimedOnlyWhenRendered_agentNotificationMusic() {
        // Routing lists only RENDERED surfaces. A point in the reserved agent
        // region, the notification band, or the hover-gated music strip is
        // claimed ONLY while that surface is actually present — never via a
        // coarse bounding union of the whole reserved window.
        let compactFrame = NSRect(x: 100, y: 300, width: 312, height: 38)
        let wing = NSRect(x: 412, y: 300, width: 40, height: 38)
        let answer = NSRect(x: 100, y: 100, width: 312, height: 180)
        let leftNotificationFrame = NSRect(x: -200, y: 300, width: 300, height: 38)
        let musicStripFrame = NSRect(x: 100, y: 60, width: 312, height: 42)

        // Active agent: only rendered surfaces listed. The far corner of the
        // reserved region (over no content) must stay click-through.
        let reservedCorner = NSPoint(x: 451, y: 101)
        XCTAssertTrue(
            IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                cursor: reservedCorner,
                activeFrames: [compactFrame, wing, answer]
            ),
            "Reserved agent zone with no rendered content must be click-through."
        )

        // Notification pill zone: claimed only while listed.
        let pillPoint = NSPoint(x: leftNotificationFrame.midX, y: leftNotificationFrame.midY)
        XCTAssertTrue(
            IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(cursor: pillPoint, activeFrames: [compactFrame]),
            "Empty notification zone is click-through when no pill is present."
        )
        XCTAssertFalse(
            IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                cursor: pillPoint,
                activeFrames: [compactFrame, leftNotificationFrame]
            ),
            "Notification pill zone must be mouse-active while a pill is present."
        )

        // Hover-gated music strip band: claimed only while a track is active.
        let stripPoint = NSPoint(x: musicStripFrame.midX, y: musicStripFrame.midY)
        XCTAssertTrue(
            IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(cursor: stripPoint, activeFrames: [compactFrame]),
            "Idle (no track) strip band must be click-through."
        )
        XCTAssertFalse(
            IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                cursor: stripPoint,
                activeFrames: [compactFrame, musicStripFrame]
            ),
            "Active track must make the strip band mouse-active."
        )
    }

    func test_musicStripBand_claimedOnlyWhileHoverExpanded() {
        // The strip renders ONLY while hover-expanded (`IslandMusicStripHitZone.
        // isActive` gates `hitTest` and the `sendEvent` transport dispatch on
        // `musicStripActive && acceptsExpandedHitTesting`). Mouse-routing must
        // use the SAME predicate: with a track playing and the island COMPACT,
        // the invisible strip band (full pill width, `musicStripTopGap` to
        // `musicStripTopGap + musicStripHeight` below the pill) claimed events
        // while `hitTest` returned nil there — AppKit ate the click instead of
        // passing it to the window below, so window controls sitting right
        // under the island stopped responding whenever music was playing.
        let compactFrame = NSRect(x: 100, y: 300, width: 312, height: 38)
        let expandedFrame = NSRect(x: 100, y: 100, width: 312, height: 238)
        let musicStripFrame = NSRect(
            x: 100,
            y: 300 - IslandDropModeControl.musicStripTopGap - IslandDropModeControl.musicStripHeight,
            width: 312,
            height: IslandDropModeControl.musicStripHeight
        )
        let stripPoint = NSPoint(x: musicStripFrame.midX, y: musicStripFrame.midY)

        func frames(
            expanded: Bool,
            musicStripActive: Bool = true,
            idleHidden: Bool = false
        ) -> [NSRect] {
            IslandPanelMouseEventPolicy.activeFrames(
                compactFrame: compactFrame,
                expandedFrame: expandedFrame,
                leftNotificationFrame: .zero,
                musicStripFrame: musicStripFrame,
                agentSurfaceFrames: [],
                idleHidden: idleHidden,
                expanded: expanded,
                notificationActive: false,
                musicStripActive: musicStripActive
            )
        }

        // The dedicated strip frame is listed for EXACTLY the states in which
        // the strip is rendered (track active AND hover-expanded). Asserted on
        // the frame list itself: a cursor-membership check alone can false-pass
        // when the probe point also falls inside the expanded content frame.
        XCTAssertFalse(
            frames(expanded: false).contains(musicStripFrame),
            "Compact island must not claim the (unrendered) strip band while a track plays."
        )
        XCTAssertTrue(
            frames(expanded: true).contains(musicStripFrame),
            "Hover-expanded island must claim the rendered strip band."
        )
        XCTAssertFalse(
            frames(expanded: true, musicStripActive: false).contains(musicStripFrame),
            "No track → no strip claim, hover-expanded or not."
        )

        // Compact island + playing track: the strip band must stay
        // click-through for the app below (window controls right under the
        // island). This is the reported-bug scenario.
        XCTAssertTrue(
            IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                cursor: stripPoint,
                activeFrames: frames(expanded: false)
            ),
            "Clicks in the strip band must pass through while the island is compact."
        )

        // The compact pill itself stays claimed while a track plays.
        let pillPoint = NSPoint(x: compactFrame.midX, y: compactFrame.midY)
        XCTAssertFalse(
            IslandPanelMouseEventPolicy.shouldIgnoreMouseEvents(
                cursor: pillPoint,
                activeFrames: frames(expanded: false)
            ),
            "Compact pill stays mouse-active while a track plays."
        )

        // Idle-hidden (pill faded to the bare notch): nothing is rendered, so
        // nothing is claimed — even with a stale track flag the invisible pill
        // and strip must both be click-through.
        XCTAssertTrue(
            frames(expanded: false, idleHidden: true).isEmpty,
            "Idle-hidden island claims no frames at all."
        )
    }

    func test_hoverGatedMusicStrip_growsHoverBandByStripHeightPlusGap() {
        // The player strip is hover-gated: it lives at the top of the hover
        // drawer (between the island and the hover panel). The band must grow by
        // the strip height PLUS the bottom gap that separates the player from the
        // controls panel below — so the panel keeps its full height and the two
        // read as separate floating cards, not one fused frame. (The strip's
        // transport buttons stay hit-testable through the grown expanded rect.)
        let stripDelta = IslandDropModeControl.musicStripHeight
            + IslandDropModeControl.musicStripBottomGap

        let controlsNoMusic = IslandView.hoverPanelHeight(for: .controls, musicActive: false)
        let controlsWithMusic = IslandView.hoverPanelHeight(for: .controls, musicActive: true)
        XCTAssertEqual(
            controlsWithMusic - controlsNoMusic,
            stripDelta,
            "An active track must grow the hover band by the strip height + bottom gap."
        )

        // The growth is additive on top of the per-mode base, so History's
        // tall band still grows by the same strip delta.
        let historyNoMusic = IslandView.hoverPanelHeight(for: .history, musicActive: false)
        let historyWithMusic = IslandView.hoverPanelHeight(for: .history, musicActive: true)
        XCTAssertEqual(
            historyWithMusic - historyNoMusic,
            stripDelta,
            "The strip delta is additive over every panel mode's base band."
        )
        XCTAssertGreaterThan(
            historyNoMusic, controlsNoMusic,
            "History's base band stays taller than the controls band."
        )
    }

    func test_expandedHitRect_coversStripBand_whileTrackActive() {
        // The hover-gated strip sits at the TOP of the drawer, just below the
        // compact pill: its screen band spans
        //   [compactHeight + musicStripTopGap, compactHeight + musicStripTopGap + musicStripHeight]
        // measured DOWN from the window top. The AppKit hit rect
        // (`ClickThroughHostingView.acceptsEvent`, expanded case) is anchored at
        // the window top and is `compactHeight + activeHoverPanelHeight` tall,
        // where the active band already grew by `musicStripHeight`
        // (`hoverPanelHeight(for:musicActive:)`). This test pins the invariant
        // that the strip's transport-button row falls INSIDE that rect — i.e.
        // the band growth actually reaches the strip, not just the panel below.
        //
        // NOTE: geometry is necessary but proved NOT sufficient on-device — the
        // generic expanded rect failed to route clicks to the strip's
        // `Button`s in this non-key panel. The reliable fix is the explicit
        // `IslandMusicStripHitZone` union (see the tests above); this test
        // retains the geometric sanity check that the strip band is, at least,
        // within the expanded region.
        let compactHeight: CGFloat = 38
        let bandWithMusic = IslandView.hoverPanelHeight(for: .controls, musicActive: true)
        let hitRectHeight = compactHeight + bandWithMusic

        // Strip band, measured down from the window top.
        let stripTopFromTop = compactHeight + IslandDropModeControl.musicStripTopGap
        let stripBottomFromTop = stripTopFromTop + IslandDropModeControl.musicStripHeight

        // Model the expanded hit rect in a tall window the way `acceptsEvent`
        // builds it: anchored flush to the window top, growing downward.
        let windowHeight: CGFloat = 600   // permanently agent-sized; ample
        let hitRect = NSRect(
            x: 0,
            y: windowHeight - hitRectHeight,
            width: 312,
            height: hitRectHeight
        )

        // The strip's transport-button mid-row (in window coordinates, y up).
        let stripMidY = windowHeight - (stripTopFromTop + stripBottomFromTop) / 2
        XCTAssertTrue(
            hitRect.contains(NSPoint(x: hitRect.midX, y: stripMidY)),
            "Expanded hit rect must cover the strip's transport-button band while a track is active."
        )
        // And the whole strip band's bottom edge stays inside the rect.
        XCTAssertGreaterThanOrEqual(
            stripBottomFromTop, 0
        )
        XCTAssertLessThanOrEqual(
            stripBottomFromTop, hitRectHeight,
            "The full strip band must fall within the expanded hit rect height."
        )
    }

    // MARK: - Dedicated music-strip hit zone (hover-gated)

    func test_musicStripHitZone_coversRenderedStripBand_inBoundsSpace() {
        // The dedicated strip hit zone must match the strip's RENDERED region:
        // directly below the compact pill, offset DOWN by `musicStripTopGap`,
        // full `compactWidth`, height `musicStripHeight`. Modeled on the proven
        // always-on `agentActive` / `notificationActive` explicit zones — the
        // generic expanded rect demonstrably fails to route clicks to the strip
        // on-device, so this rect is unioned into `acceptsEvent` / `hitTest` and
        // the mouse-active frames while hover-expanded + a track is active.
        //
        // Bounds space: AppKit y-up, origin bottom-left, `bounds.height` = the
        // permanently agent-sized window height. The strip sits just under the
        // compact pill's bottom edge.
        let boundsSize = CGSize(width: 700, height: 671)
        let compactSize = CGSize(width: 312, height: 38)
        let zone = IslandMusicStripHitZone(
            boundsSize: boundsSize,
            compactSize: compactSize,
            rightAgentZoneWidth: IslandFrameLayout.rightAgentZoneWidth,
            topGap: IslandDropModeControl.musicStripTopGap,
            stripHeight: IslandDropModeControl.musicStripHeight
        )
        let rect = zone.stripRect

        // Width is the full compact pill width; height is the strip height.
        XCTAssertEqual(rect.width, compactSize.width, accuracy: 0.001)
        XCTAssertEqual(rect.height, IslandDropModeControl.musicStripHeight, accuracy: 0.001)

        // Trailing-anchored: the strip's right edge sits at the compact island's
        // right edge (`bounds.width - rightAgentZoneWidth`), exactly where
        // `acceptsEvent` pins the expanded island rect.
        XCTAssertEqual(
            rect.maxX,
            boundsSize.width - IslandFrameLayout.rightAgentZoneWidth,
            accuracy: 0.001
        )

        // Vertical span: top edge is `compactHeight + topGap` below the window
        // top; the rect is `stripHeight` tall (y-up: lower origin, grow up to
        // that top edge).
        let stripTopFromTop = compactSize.height + IslandDropModeControl.musicStripTopGap
        XCTAssertEqual(
            rect.maxY,
            boundsSize.height - stripTopFromTop,
            accuracy: 0.001
        )
        XCTAssertEqual(
            rect.minY,
            boundsSize.height - stripTopFromTop - IslandDropModeControl.musicStripHeight,
            accuracy: 0.001
        )

        // The strip's transport-button mid-row falls strictly inside the rect.
        let stripMidYFromTop = stripTopFromTop + IslandDropModeControl.musicStripHeight / 2
        let stripMidY = boundsSize.height - stripMidYFromTop
        XCTAssertTrue(rect.contains(NSPoint(x: rect.midX, y: stripMidY)))
    }

    func test_transportButtonRects_layoutMatchesRenderedHStack() {
        // The transport buttons sit at the strip's TRAILING end, inset by
        // `horizontalPadding` from the strip's right edge, each
        // `transportButtonSize` wide, `transportSpacing` apart, vertically
        // centered. Right-to-left the rendered order is next (rightmost),
        // playPause, previous. `IslandPanel.sendEvent` routes transport clicks
        // against these rects (the strip's SwiftUI `Button`s never receive the
        // click in the non-key panel), so the math must mirror the render
        // exactly or the click lands on the wrong (or no) button.
        let strip = CGRect(x: 100, y: 200, width: 312, height: 42)
        let rects = IslandMusicStripHitZone.transportButtonRects(stripRect: strip, isLive: false)

        let size = IslandMusicStrip.transportButtonSize
        let spacing = IslandMusicStrip.transportSpacing
        let inset = IslandMusicStrip.horizontalPadding

        // All three are square, the button size, and vertically centered.
        for button in [rects.previous, rects.playPause, rects.next] {
            XCTAssertEqual(button.width, size, accuracy: 0.001)
            XCTAssertEqual(button.height, size, accuracy: 0.001)
            XCTAssertEqual(button.midY, strip.midY, accuracy: 0.001,
                           "Transport buttons are vertically centered in the strip.")
        }

        // `next` is rightmost: its right edge is one inset inside the strip's
        // right edge.
        XCTAssertEqual(rects.next.maxX, strip.maxX - inset, accuracy: 0.001)
        // `playPause` sits one button + one spacing to the LEFT of `next`.
        XCTAssertEqual(rects.playPause.maxX, rects.next.minX - spacing, accuracy: 0.001)
        // `previous` sits one button + one spacing to the LEFT of `playPause`.
        XCTAssertEqual(rects.previous.maxX, rects.playPause.minX - spacing, accuracy: 0.001)
        // Strictly left-to-right ordering: previous, playPause, next.
        XCTAssertLessThan(rects.previous.maxX, rects.playPause.minX)
        XCTAssertLessThan(rects.playPause.maxX, rects.next.minX)
    }

    func test_transportButtonRects_pointInEachMapsToCorrectButton() {
        // A click at each button's center must fall inside that button's rect
        // and NOT inside the others — so the `sendEvent` dispatch routes the
        // click to the matching action (⏮ previous / ▶ playPause / ⏭ next).
        let strip = CGRect(x: 0, y: 0, width: 312, height: 42)
        let rects = IslandMusicStripHitZone.transportButtonRects(stripRect: strip, isLive: false)

        let centers: [(name: String, point: CGPoint, own: CGRect, others: [CGRect])] = [
            ("previous", CGPoint(x: rects.previous.midX, y: rects.previous.midY),
             rects.previous, [rects.playPause, rects.next]),
            ("playPause", CGPoint(x: rects.playPause.midX, y: rects.playPause.midY),
             rects.playPause, [rects.previous, rects.next]),
            ("next", CGPoint(x: rects.next.midX, y: rects.next.midY),
             rects.next, [rects.previous, rects.playPause]),
        ]
        for c in centers {
            XCTAssertTrue(c.own.contains(c.point),
                          "\(c.name) center must fall in its own hotspot.")
            for other in c.others {
                XCTAssertFalse(other.contains(c.point),
                               "\(c.name) center must NOT fall in another button's hotspot.")
            }
        }

        // All three hotspots stay within the strip rect (no overflow past the
        // trailing inset or above/below the strip).
        for button in [rects.previous, rects.playPause, rects.next] {
            XCTAssertTrue(strip.contains(button),
                          "Each transport hotspot must lie within the strip rect.")
        }
    }

    func test_transportButton_atEachCenterMapsToThatButton() {
        // The hover hit-test must resolve each button's center to that button —
        // the geometric twin of the click dispatch, so the hover highlight lands
        // on the control under the cursor.
        let strip = CGRect(x: 0, y: 0, width: 312, height: 42)
        let rects = IslandMusicStripHitZone.transportButtonRects(stripRect: strip, isLive: false)
        XCTAssertEqual(
            IslandMusicStripHitZone.transportButton(
                at: CGPoint(x: rects.previous.midX, y: rects.previous.midY),
                stripRect: strip, isLive: false),
            .previous
        )
        XCTAssertEqual(
            IslandMusicStripHitZone.transportButton(
                at: CGPoint(x: rects.playPause.midX, y: rects.playPause.midY),
                stripRect: strip, isLive: false),
            .playPause
        )
        XCTAssertEqual(
            IslandMusicStripHitZone.transportButton(
                at: CGPoint(x: rects.next.midX, y: rects.next.midY),
                stripRect: strip, isLive: false),
            .next
        )
    }

    func test_transportButton_offButtonsIsNil() {
        // Over the artwork/title area (left of the transport cluster) and fully
        // outside the strip there is no button — hover highlight must clear.
        let strip = CGRect(x: 0, y: 0, width: 312, height: 42)
        XCTAssertNil(IslandMusicStripHitZone.transportButton(
            at: CGPoint(x: strip.minX + 5, y: strip.midY),
            stripRect: strip, isLive: false))
        XCTAssertNil(IslandMusicStripHitZone.transportButton(
            at: CGPoint(x: strip.maxX + 50, y: strip.midY),
            stripRect: strip, isLive: false))
    }

    func test_transportButton_liveModeOnlyPlayPause() {
        // Radio / live: only play/pause exists, in the rightmost slot. The slots
        // prev/playPause normally occupy must resolve to nil.
        let strip = CGRect(x: 0, y: 0, width: 312, height: 42)
        let normal = IslandMusicStripHitZone.transportButtonRects(stripRect: strip, isLive: false)
        XCTAssertEqual(
            IslandMusicStripHitZone.transportButton(
                at: CGPoint(x: normal.next.midX, y: normal.next.midY),
                stripRect: strip, isLive: true),
            .playPause
        )
        XCTAssertNil(IslandMusicStripHitZone.transportButton(
            at: CGPoint(x: normal.previous.midX, y: normal.previous.midY),
            stripRect: strip, isLive: true))
    }

    func test_transportButtonRects_liveMode_onlyPlayPauseAtRightmostSlot() {
        // Radio / live stream: prev + next are meaningless (nothing to seek or
        // skip), so the strip renders ONLY play/pause and it must occupy the
        // SAME rightmost slot `next` normally holds — keeping it aligned with
        // the geometric hit dispatch in `sendEvent`. Prev/next rects are
        // `.null` (`.null.contains(_:)` is always false, so they can never
        // fire).
        let strip = CGRect(x: 100, y: 200, width: 312, height: 42)
        let live = IslandMusicStripHitZone.transportButtonRects(stripRect: strip, isLive: true)
        let normal = IslandMusicStripHitZone.transportButtonRects(stripRect: strip, isLive: false)

        XCTAssertEqual(live.previous, .null, "Live mode: previous must be a null (never-hit) rect.")
        XCTAssertEqual(live.next, .null, "Live mode: next must be a null (never-hit) rect.")
        // playPause sits where `next` (rightmost) normally is.
        XCTAssertEqual(live.playPause, normal.next,
                       "Live play/pause must occupy the rightmost (next) slot.")

        // A click at the rightmost slot center hits play/pause and nothing else.
        let rightmostCenter = CGPoint(x: normal.next.midX, y: normal.next.midY)
        XCTAssertTrue(live.playPause.contains(rightmostCenter))
        XCTAssertFalse(live.previous.contains(rightmostCenter))
        XCTAssertFalse(live.next.contains(rightmostCenter))

        // The slots `previous` / `playPause` normally occupy can never fire in
        // live mode (null prev/next, and play/pause moved to the rightmost).
        let normalPlayCenter = CGPoint(x: normal.playPause.midX, y: normal.playPause.midY)
        XCTAssertFalse(live.previous.contains(normalPlayCenter))
        XCTAssertFalse(live.next.contains(normalPlayCenter))
        XCTAssertFalse(live.playPause.contains(normalPlayCenter))
    }

    func test_musicStripHitZone_active_onlyWhenTrackActiveAndExpanded() {
        // The dedicated zone is gated on BOTH a track being active AND the
        // island being hover-expanded — exactly the state in which the strip is
        // rendered. (`musicStripActive` mirrors `AppState.nowPlaying != nil`;
        // `acceptsExpandedHitTesting` is the panel's live hover flag.)
        for musicActive in [false, true] {
            for expanded in [false, true] {
                let shouldBeActive = musicActive && expanded
                XCTAssertEqual(
                    IslandMusicStripHitZone.isActive(
                        musicStripActive: musicActive,
                        acceptsExpandedHitTesting: expanded
                    ),
                    shouldBeActive,
                    "Strip zone active iff a track is active AND hover-expanded (music=\(musicActive), expanded=\(expanded))."
                )
            }
        }
    }

    func test_musicStripHitZone_matchesExpandedHostFrameInScreenSpace() {
        // Cross-check the bounds-space rect against the SCREEN-space expanded
        // host frame: when projected onto the real notched-MBP layout, the
        // strip band's screen Y must sit just below the compact pill (between
        // the pill's bottom edge and the hover panel below it), and inside the
        // expanded host frame the panel routes hover/clicks over.
        let compact = IslandFrameLayout.islandFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )
        let expandedHost = IslandFrameLayout.hostPanelFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )

        // Strip screen band, measured DOWN from the screen top (= pill top).
        let screenTop = compact.maxY
        let stripScreenTopY = screenTop - (compact.height + IslandDropModeControl.musicStripTopGap)
        let stripScreenBottomY = stripScreenTopY - IslandDropModeControl.musicStripHeight

        // Below the compact pill's bottom edge…
        XCTAssertLessThanOrEqual(stripScreenTopY, compact.minY + 0.001)
        // …and entirely within the expanded host frame the panel hit-tests.
        XCTAssertGreaterThanOrEqual(stripScreenBottomY, expandedHost.minY - 0.001)
        XCTAssertLessThanOrEqual(stripScreenTopY, expandedHost.maxY + 0.001)
    }

    func test_panelHitTestSizeFollowsHoverState() {
        let compactSize = CGSize(width: 312, height: 38)
        let expandedSize = CGSize(width: 312, height: 192)

        XCTAssertEqual(
            IslandPanelFramePolicy.hitTestSize(
                compactSize: compactSize,
                expandedSize: expandedSize,
                acceptsExpandedHitTesting: false
            ),
            compactSize
        )
        XCTAssertEqual(
            IslandPanelFramePolicy.hitTestSize(
                compactSize: compactSize,
                expandedSize: expandedSize,
                acceptsExpandedHitTesting: true
            ),
            expandedSize
        )
    }

    func test_syntheticNotchWidth_isTunablePositiveConstant() {
        // Used on non-notched screens as a visual placeholder in the
        // middle of the pill — keeps the orb-left / trigger-right design
        // language consistent on external monitors.
        XCTAssertGreaterThan(IslandFrameLayout.syntheticNotchWidth, 80)
        XCTAssertLessThan(IslandFrameLayout.syntheticNotchWidth, 280)
    }

    func test_cameraShapeKeepsSquareTopAndSubtleBottomCorners() {
        XCTAssertEqual(IslandFrameLayout.cameraTopCornerRadius, 0)
        XCTAssertEqual(
            IslandFrameLayout.cameraCornerRenderer,
            .systemContinuousUnevenRectangle
        )

        let bottomRadius = IslandFrameLayout.cameraBottomCornerRadius(compactHeight: 38)

        XCTAssertEqual(bottomRadius, 10, accuracy: 0.001)
        XCTAssertLessThan(bottomRadius, 38 / 2)
    }

    func test_cameraShapeSquaresBottomCornersWhileMeetingSuggestionIsAttached() {
        XCTAssertEqual(
            IslandFrameLayout.cameraBottomCornerRadius(
                compactHeight: 38,
                meetingSuggestionActive: true
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            IslandFrameLayout.cameraBottomCornerRadius(
                compactHeight: 38,
                meetingSuggestionActive: false
            ),
            IslandFrameLayout.cameraBottomCornerRadius(compactHeight: 38),
            accuracy: 0.001
        )
    }

    // MARK: - menuBarHeight helper

    func test_menuBarHeight_isDifferenceBetweenFrameAndVisibleFrame() {
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 76, width: 1512, height: 868)
        XCTAssertEqual(
            IslandFrameLayout.menuBarHeight(frame: frame, visibleFrame: visible),
            38,
            accuracy: 0.001
        )
    }

    func test_menuBarHeight_externalMonitor_is24() {
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1224)
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1200)
        XCTAssertEqual(
            IslandFrameLayout.menuBarHeight(frame: frame, visibleFrame: visible),
            24,
            accuracy: 0.001
        )
    }

    // MARK: - compactHeight clamping

    func test_compactHeight_notchedMBP_38ptMenuBar_returns38() {
        XCTAssertEqual(
            IslandFrameLayout.compactHeight(menuBarHeight: 38),
            38,
            accuracy: 0.001
        )
    }

    func test_compactHeight_externalMonitor_24ptMenuBar_returns24() {
        XCTAssertEqual(
            IslandFrameLayout.compactHeight(menuBarHeight: 24),
            24,
            accuracy: 0.001
        )
    }

    func test_compactHeight_clampsLowerBoundTo24() {
        XCTAssertEqual(
            IslandFrameLayout.compactHeight(menuBarHeight: 20),
            24,
            accuracy: 0.001
        )
    }

    func test_compactHeight_clampsUpperBoundTo44() {
        XCTAssertEqual(
            IslandFrameLayout.compactHeight(menuBarHeight: 60),
            44,
            accuracy: 0.001
        )
    }

    func test_compactHeight_unknownMenuBar_returns32Default() {
        XCTAssertEqual(
            IslandFrameLayout.compactHeight(menuBarHeight: 0),
            32,
            accuracy: 0.001
        )
    }

    // MARK: - hasNotch helper

    func test_hasNotch_zeroSafeAreaIsFalse() {
        XCTAssertFalse(IslandFrameLayout.hasNotch(safeAreaTopInset: 0))
    }

    func test_hasNotch_positiveSafeAreaIsTrue() {
        XCTAssertTrue(IslandFrameLayout.hasNotch(safeAreaTopInset: 38))
    }

    // MARK: - Test fixtures: notched MBP geometry

    /// Notched M1 14" MBP layout used across pill-frame tests. Notch
    /// cutout is from x=670 to x=842 (width 172, height 38).
    private static let notchedFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private static let notchedVisible = NSRect(x: 0, y: 76, width: 1512, height: 868)
    private static let notchedAuxLeft = NSRect(x: 0, y: 944, width: 670, height: 38)
    private static let notchedAuxRight = NSRect(x: 842, y: 944, width: 670, height: 38)
    private static let notchedSafeAreaTop: CGFloat = 38

    /// Non-notched external monitor (no aux areas, no safe-area inset).
    private static let externalFrame = NSRect(x: 0, y: 0, width: 1920, height: 1200)
    private static let externalVisible = NSRect(x: 0, y: 0, width: 1920, height: 1176)
    // menuBarHeight = 24 on external monitor

    // MARK: - Compact frame placement on a notched screen

    func test_compactFrame_notchedScreen_pillWrapsTheNotch() {
        // Pill must straddle the notch: left panel sits at
        // auxLeft.maxX - leftSideWidth, right panel ends at
        // auxRight.minX + rightSideWidth. Notch is in the middle.
        let pill = IslandFrameLayout.islandFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )

        let leftWidth = IslandFrameLayout.leftSideWidth
        let rightWidth = IslandFrameLayout.rightSideWidth
        let notchMinX = Self.notchedAuxLeft.maxX  // 670
        let notchMaxX = Self.notchedAuxRight.minX // 842

        XCTAssertEqual(pill.minX, notchMinX - leftWidth, accuracy: 0.5,
                       "pill.minX must equal notch.minX - leftSideWidth")
        XCTAssertEqual(pill.maxX, notchMaxX + rightWidth, accuracy: 0.5,
                       "pill.maxX must equal notch.maxX + rightSideWidth")
    }

    func test_compactFrame_notchedScreen_topEdgeFlushWithScreenTop() {
        let pill = IslandFrameLayout.islandFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )
        // Top edge of pill flush with top of screen (= top of notch).
        XCTAssertEqual(pill.maxY, Self.notchedFrame.maxY, accuracy: 0.5)
    }

    func test_compactFrame_notchedScreen_heightEqualsNotchHeight() {
        // Compact pill height = menu-bar / notch height (clamped to
        // [24, 44]). 38pt menu bar is within range, so pill height = 38.
        let pill = IslandFrameLayout.islandFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )
        XCTAssertEqual(pill.height, 38, accuracy: 0.5)
        // Bottom edge of compact pill = top of visibleFrame (below notch line).
        XCTAssertEqual(pill.minY, Self.notchedVisible.maxY, accuracy: 0.5)
    }

    func test_compactFrame_realNotchUsesSafeAreaHeightWhenMenuBarHeightDiffers() {
        let frame = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let visible = NSRect(x: 0, y: 94, width: 1728, height: 990)
        let safeAreaTop: CGFloat = 32
        let auxLeft = NSRect(x: 0, y: 1085, width: 771, height: 32)
        let auxRight = NSRect(x: 956, y: 1085, width: 772, height: 32)

        let pill = IslandFrameLayout.islandFrame(
            frame: frame,
            visibleFrame: visible,
            safeAreaTopInset: safeAreaTop,
            auxiliaryTopLeftArea: auxLeft,
            auxiliaryTopRightArea: auxRight
        )

        XCTAssertEqual(pill.height, safeAreaTop, accuracy: 0.5)
        XCTAssertEqual(pill.minY, auxLeft.minY, accuracy: 0.5)
        XCTAssertNotEqual(pill.minY, visible.maxY, accuracy: 0.5)
    }

    func test_compactFrame_notchedScreen_widthEqualsLeftPlusNotchPlusRight() {
        let pill = IslandFrameLayout.islandFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )
        let notchWidth = Self.notchedAuxRight.minX - Self.notchedAuxLeft.maxX // 172
        let expectedWidth =
            IslandFrameLayout.leftSideWidth + notchWidth + IslandFrameLayout.rightSideWidth
        XCTAssertEqual(pill.width, expectedWidth, accuracy: 0.5)
    }

    // MARK: - Compact frame placement on a non-notched screen

    func test_compactFrame_externalScreen_isTopCentered() {
        let pill = IslandFrameLayout.islandFrame(
            frame: Self.externalFrame,
            visibleFrame: Self.externalVisible,
            safeAreaTopInset: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
        XCTAssertEqual(pill.midX, Self.externalFrame.midX, accuracy: 0.5)
    }

    func test_compactFrame_externalScreen_widthUsesSyntheticNotch() {
        let pill = IslandFrameLayout.islandFrame(
            frame: Self.externalFrame,
            visibleFrame: Self.externalVisible,
            safeAreaTopInset: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
        let expectedWidth =
            IslandFrameLayout.leftSideWidth
            + IslandFrameLayout.syntheticNotchWidth
            + IslandFrameLayout.rightSideWidth
        XCTAssertEqual(pill.width, expectedWidth, accuracy: 0.5)
    }

    func test_compactFrame_externalScreen_topEdgeFlushWithScreenTop() {
        let pill = IslandFrameLayout.islandFrame(
            frame: Self.externalFrame,
            visibleFrame: Self.externalVisible,
            safeAreaTopInset: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
        XCTAssertEqual(pill.maxY, Self.externalFrame.maxY, accuracy: 0.5)
        XCTAssertEqual(pill.height, 24, accuracy: 0.5) // = menuBarHeight
    }

    // MARK: - Defensive: notched safe area but one aux rect missing

    func test_compactFrame_notchedSafeAreaButAuxLeftMissing_fallsBackToCenteredLayout() {
        // safeAreaInsets.top > 0 but auxLeft is nil — defensive path,
        // fall back to centered (synthetic notch) layout instead of
        // crashing or producing an invalid frame.
        let pill = IslandFrameLayout.islandFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )
        XCTAssertEqual(pill.midX, Self.notchedFrame.midX, accuracy: 0.5)
        let expectedWidth =
            IslandFrameLayout.leftSideWidth
            + IslandFrameLayout.syntheticNotchWidth
            + IslandFrameLayout.rightSideWidth
        XCTAssertEqual(pill.width, expectedWidth, accuracy: 0.5)
    }

    func test_compactFrame_notchedSafeAreaButAuxRightMissing_fallsBackToCenteredLayout() {
        let pill = IslandFrameLayout.islandFrame(
            frame: Self.notchedFrame,
            visibleFrame: Self.notchedVisible,
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: nil
        )
        XCTAssertEqual(pill.midX, Self.notchedFrame.midX, accuracy: 0.5)
        let expectedWidth =
            IslandFrameLayout.leftSideWidth
            + IslandFrameLayout.syntheticNotchWidth
            + IslandFrameLayout.rightSideWidth
        XCTAssertEqual(pill.width, expectedWidth, accuracy: 0.5)
    }

    // MARK: - Notch metrics helper

    func test_notchMetrics_notchedScreen_returnsActualNotchRange() {
        let metrics = IslandFrameLayout.notchMetrics(
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: Self.notchedAuxLeft,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )
        XCTAssertEqual(metrics.width, 172, accuracy: 0.5,
                       "Notch width = auxRight.minX - auxLeft.maxX")
        XCTAssertTrue(metrics.isRealNotch)
    }

    func test_notchMetrics_externalScreen_returnsSyntheticPlaceholder() {
        let metrics = IslandFrameLayout.notchMetrics(
            safeAreaTopInset: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
        XCTAssertEqual(metrics.width, IslandFrameLayout.syntheticNotchWidth, accuracy: 0.5)
        XCTAssertFalse(metrics.isRealNotch)
    }

    func test_notchMetrics_safeAreaButMissingAuxLeft_returnsSyntheticPlaceholder() {
        let metrics = IslandFrameLayout.notchMetrics(
            safeAreaTopInset: Self.notchedSafeAreaTop,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: Self.notchedAuxRight
        )
        XCTAssertEqual(metrics.width, IslandFrameLayout.syntheticNotchWidth, accuracy: 0.5)
        XCTAssertFalse(metrics.isRealNotch)
    }

    // MARK: - Adaptive wing width

    func test_adaptiveWingWidth_clampsUpToFloor() {
        XCTAssertEqual(
            IslandFrameLayout.adaptiveWingWidth(measuredContentWidth: 30, cap: 260),
            IslandFrameLayout.adaptiveWingFloor,
            accuracy: 0.001
        )
    }

    func test_adaptiveWingWidth_clampsDownToCap() {
        XCTAssertEqual(
            IslandFrameLayout.adaptiveWingWidth(measuredContentWidth: 999, cap: 260),
            260,
            accuracy: 0.001
        )
    }

    func test_adaptiveWingWidth_passesThroughBetweenFloorAndCap() {
        XCTAssertEqual(
            IslandFrameLayout.adaptiveWingWidth(measuredContentWidth: 150, cap: 260),
            150,
            accuracy: 0.001
        )
    }

    func test_adaptiveWingFloor_isBelowPlaceholderNeighbourhood() {
        // Floor must sit below the natural "listening…" placeholder width so
        // the placeholder (not the floor) sets the compact start; the floor
        // only catches shorter strings / a zero measurement.
        XCTAssertGreaterThan(IslandFrameLayout.adaptiveWingFloor, 0)
        XCTAssertLessThan(IslandFrameLayout.adaptiveWingFloor, 96)
    }
}

final class IslandAgentComposerOutsideClickPolicyTests: XCTestCase {
    func test_clickOutsideVisibleComposer_cancels() {
        XCTAssertTrue(
            IslandAgentComposerOutsideClickPolicy.shouldCancel(
                composerVisible: true,
                clickInComposerPanel: false
            ),
            "Any click outside the dedicated composer panel means the user left composing."
        )
    }

    func test_clickInsideVisibleComposer_doesNotCancel() {
        XCTAssertFalse(
            IslandAgentComposerOutsideClickPolicy.shouldCancel(
                composerVisible: true,
                clickInComposerPanel: true
            ),
            "Clicks inside the dedicated input panel must keep the caret alive."
        )
    }

    func test_clickWhileComposerHidden_doesNotCancel() {
        XCTAssertFalse(
            IslandAgentComposerOutsideClickPolicy.shouldCancel(
                composerVisible: false,
                clickInComposerPanel: false
            ),
            "No composing field is up — a click cancels nothing."
        )
    }
}

final class IslandAgentComposerArchitectureTests: XCTestCase {
    func test_agentComposingUsesDedicatedComposerPanelInsteadOfRetypingIslandPanel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let islandPanelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/DynamicIsland/IslandPanel.swift"),
            encoding: .utf8
        )
        let composerPanelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/DynamicIsland/IslandAgentComposerPanel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            islandPanelSource.contains("IslandAgentComposerPanel"),
            "Agent text entry should live in a dedicated key-capable composer panel."
        )
        XCTAssertTrue(
            composerPanelSource.contains(".nonactivatingPanel"),
            "The dedicated composer panel must be non-activating so it can overlay sibling fullscreen Spaces."
        )
        XCTAssertFalse(
            composerPanelSource.contains("NSApp.activate(ignoringOtherApps: true)"),
            "The fullscreen composer overlay must not activate Whytap or pull focus into another Space."
        )
        XCTAssertFalse(
            islandPanelSource.contains("styleMask.remove(.nonactivatingPanel)"),
            "The island overlay should stay non-activating instead of being retyped at runtime."
        )
        XCTAssertFalse(
            islandPanelSource.contains("firstTextInputView"),
            "The island overlay should not walk SwiftUI's hosted view tree to steal a TextField responder."
        )
    }
}
