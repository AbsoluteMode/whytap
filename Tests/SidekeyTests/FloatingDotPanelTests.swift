import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class FloatingDotPanelTests: XCTestCase {
    func testCollapsedPanelIsBottomRightAtCurrentPillSize() {
        let panel = FloatingDotPanel()
        defer { panel.close() }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = VoiceOrbView.canvasSize

        XCTAssertEqual(panel.frame.width, size)
        XCTAssertEqual(panel.frame.height, size)
        // Right-edge inset is 72pt (was 80pt before the glow-padding
        // bump that raised `canvasSize` 41 → 57); subtracting half the
        // canvas growth keeps the orb's horizontal centre at the same
        // screen position the user already learned.
        XCTAssertEqual(panel.frame.minX, visible.maxX - size - 72, accuracy: 0.5)
        // Orb panel bottom sits 51pt above `visible.minY` (11 base
        // anchor + 40pt dock-safe buffer; baseMarginBottom dropped 19 →
        // 11 alongside the glow-padding bump that raised `canvasSize`
        // 41 → 57, preserving the orb's vertical centre while still
        // keeping the panel above the dock-safe floor). The orb's
        // visual centre still sits 2.5pt below AgentTextInputPanel's
        // centre — both anchors retain the dock-safe +40 lift so the
        // relative offset is preserved (see
        // `testOrbVisualCenterSitsBelowTextInputVisualCenter`).
        XCTAssertEqual(panel.frame.minY, visible.minY + 51, accuracy: 0.5)
    }

    func testBottomRightFramePlacesPillAtRightMargin() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screen = NSScreen.main
        // Use a synthetic visibleFrame computation by passing nil; FloatingDotPanel
        // falls back to NSScreen.main, so this asserts the formula on whatever
        // screen is reported. Compute expected from the same visibleFrame source.
        let realVisible = screen?.visibleFrame ?? visible
        let size = VoiceOrbView.canvasSize

        let frame = FloatingDotPanel.bottomRightFrame(for: screen, expanded: false)

        XCTAssertEqual(frame.width, size)
        XCTAssertEqual(frame.height, size)
        XCTAssertEqual(frame.minX, realVisible.maxX - size - 72, accuracy: 0.5)
        XCTAssertEqual(frame.minY, realVisible.minY + 51, accuracy: 0.5)
    }

    /// Maxim spec: every overlay panel must keep a 40pt buffer above
    /// `visibleFrame.minY` so a full-bar / magnified Dock never overlaps
    /// the orb. The buffer also has to be expressed as a named constant
    /// so future panels reuse the same dock-safe margin instead of each
    /// invention re-deriving it.
    func testOrbBottomSitsAtLeastDockSafeMarginAboveVisibleMinY() {
        let visible = NSRect(x: 100, y: 50, width: 1440, height: 900)
        let frame = FloatingDotPanel.bottomRightFrame(visibleFrame: visible, expanded: false)
        XCTAssertGreaterThanOrEqual(
            frame.minY - visible.minY,
            FloatingDotPanel.dockSafeBottomMargin,
            "Orb bottom must clear visibleFrame.minY by at least the dock-safe buffer."
        )
    }

    /// Orb window level must beat the Dock (`kCGDockWindowLevelKey` ≈ 20)
    /// AND be high enough that fullscreen apps don't paint over the orb
    /// when Right Cmd triggers Ask mode while a browser / video player
    /// is in a fullscreen Space. `.statusBar` (25) is the same tier the
    /// history panels picked up in PR #110 for the Dock-magnified case.
    func testOrbPanelLevelIsAboveDock() {
        let panel = FloatingDotPanel()
        defer { panel.close() }
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        XCTAssertGreaterThan(
            panel.level.rawValue,
            dockLevel,
            "Orb must order above the Dock — otherwise a magnified or full-bar Dock paints over it."
        )
    }

    /// `canJoinAllSpaces` + `fullScreenAuxiliary` are the
    /// `collectionBehavior` flags that make a panel visible while the
    /// user is in another app's fullscreen Space. Without them the orb
    /// is invisible on the fullscreen Space and Ask mode appears not
    /// to react.
    func testOrbPanelJoinsAllSpacesAndFullScreenAuxiliary() {
        let panel = FloatingDotPanel()
        defer { panel.close() }
        XCTAssertTrue(
            panel.collectionBehavior.contains(.canJoinAllSpaces),
            "Orb must follow the user into other Spaces, including fullscreen."
        )
        XCTAssertTrue(
            panel.collectionBehavior.contains(.fullScreenAuxiliary),
            "Orb must be eligible to appear on top of fullscreen apps."
        )
    }

    func testCollapsedPanelIsClickThrough() {
        let panel = FloatingDotPanel()
        defer { panel.close() }

        XCTAssertTrue(
            panel.ignoresMouseEvents,
            "Collapsed orb should not steal clicks from the active app."
        )
    }

    // `testOrbVisualCenterSitsBelowTextInputVisualCenter` removed: it compared
    // the orb's screen frame to the legacy orb-anchored `AgentTextInputPanel`,
    // which no longer exists — the agent text input is now the island
    // composing wing (geometry covered by `IslandFrameLayout`). The
    // orb-vs-text-panel cohesion relationship it guarded is gone.

    /// Anti-regression for the glow-padding bump: the orb's screen-space
    /// visual centre must stay at the same offset from `visible.maxX`
    /// (right edge) and `visible.minY` (bottom edge) as before the
    /// canvas growth. The point of widening the canvas was to give the
    /// soft-halo radial mask room to fade out before the corners — NOT
    /// to move the visible orb. If `baseMarginBottom` or `marginRight`
    /// drifts away from the compensation (8pt drop each, matching half
    /// the canvas growth) the orb visibly shifts on screen — exactly
    /// the kind of regression the bottom-right-anchor invariant was
    /// introduced (PR #121) to prevent.
    func testOrbVisualCenterIsPreservedAcrossCanvasGrowth() {
        // Synthetic visible frame so the math is deterministic.
        let visible = NSRect(x: 0, y: 100, width: 1440, height: 900)
        let orbFrame = FloatingDotPanel.bottomRightFrame(visibleFrame: visible, expanded: false)

        // Pre-bump (canvasSize 41, baseMarginBottom 19, marginRight 80):
        //   midX = visible.maxX - 80 - 41/2 = visible.maxX - 100.5
        //   midY = visible.minY + 19 + 40 + 41/2 = visible.minY + 79.5
        let expectedMidX = visible.maxX - 100.5
        let expectedMidY = visible.minY + 79.5
        XCTAssertEqual(
            orbFrame.midX, expectedMidX, accuracy: 0.5,
            "Orb horizontal centre must stay at the same screen position after the canvas-around-orb grew (the visible orb did not change size, only the transparent buffer)."
        )
        XCTAssertEqual(
            orbFrame.midY, expectedMidY, accuracy: 0.5,
            "Orb vertical centre must stay at the same screen position after the canvas-around-orb grew."
        )
    }

    /// Round 3 invariant: the orb panel NEVER resizes on hover. The
    /// previous "expand to 108×96" approach made the orb visually
    /// drift up-and-left because the orb stays centred in the panel —
    /// growing the panel moves the orb's screen-space position. The
    /// orb panel stays a fixed square (`VoiceOrbView.canvasSize` per
    /// side, post-shrink 41pt) at the bottom-right anchor; the actions
    /// cluster lives in a separate overlay panel
    /// (`OrbActionsOverlayPanel`) layered on top.
    func testPanelFrameDoesNotChangeOnHover() {
        let panel = FloatingDotPanel()
        defer { panel.close() }
        let frameBefore = panel.frame

        AppState.shared.orbHovered = true
        defer { AppState.shared.orbHovered = false }
        // Pump the runloop so the Combine sink runs.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(
            panel.frame, frameBefore,
            "FloatingDotPanel must stay at its fixed bottom-right canvasSize square frame regardless of orbHovered — round 3 fix for the visual drift."
        )
    }

    /// Anti-regression for the «квадратная рамка вокруг round white orb»
    /// class of bugs: the orb panel's frame size MUST equal
    /// `VoiceOrbView.canvasSize` on both axes — any hardcoded width /
    /// height that drifts from the derived canvas constant produces a
    /// visible square background "frame" around the round orb because
    /// the panel extends past the rendered orb canvas. The constants
    /// `panelWidth`, `collapsedHeight`, and `expandedHeight` inside
    /// `FloatingDotPanel` are all derived from `VoiceOrbView.canvasSize`
    /// (post-shrink 41pt); this test is the canary that catches any
    /// future drift back to a hardcoded literal.
    ///
    /// Covers both the live `FloatingDotPanel()` (collapsed) frame and
    /// the pure-logic `bottomRightFrame(...)` static helper so the
    /// invariant holds for the screen-driven path AND the test-only
    /// frame computation. Asserts both axes independently rather than
    /// a single `==` comparison so a width-vs-height drift is reported
    /// with the failing axis name.
    func testPanelFrameMatchesOrbCanvasSize() {
        let panel = FloatingDotPanel()
        defer { panel.close() }
        let canvas = VoiceOrbView.canvasSize

        XCTAssertEqual(
            panel.frame.width, canvas,
            "Live panel width must equal VoiceOrbView.canvasSize — drift produces a square background visible around the round orb."
        )
        XCTAssertEqual(
            panel.frame.height, canvas,
            "Live panel height must equal VoiceOrbView.canvasSize — drift produces a square background visible around the round orb."
        )

        // Pure-logic path — used by `KeybindingsHintPanel.frameBelowOrb`
        // and tests, so a regression here misaligns the helper chip too.
        let synthetic = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let computed = FloatingDotPanel.bottomRightFrame(
            visibleFrame: synthetic,
            expanded: false
        )
        XCTAssertEqual(
            computed.width, canvas,
            "bottomRightFrame width must equal VoiceOrbView.canvasSize."
        )
        XCTAssertEqual(
            computed.height, canvas,
            "bottomRightFrame height must equal VoiceOrbView.canvasSize."
        )
    }

    // MARK: - Wake-from-sleep hang: panel ordered out on sleep
    //
    // While the orb panel is on screen, its hosted SwiftUI tree includes
    // a `TimelineView(.animation)` ticking every ~16 ms. If the app
    // sleeps with the panel still hosted, on wake the cross-sleep
    // `Date()` jump (hours) cascades into BlobShape's `animatableData`
    // and triggers SwiftUI's `DefaultCombiningAnimation` into a
    // never-converging interpolation that pins the main thread at 100%.
    //
    // Belt-and-suspenders for the animation-side fix in `VoiceOrbView`:
    // `pauseRuntimeForSleep` must order the panel OUT before the system
    // suspends the process so the TimelineView stops ticking entirely
    // and no animation state survives the sleep window.
    func testPauseRuntimeForSleepOrdersPanelOut() throws {
        let source = try loadAppDelegateSource()
        let body = try extractFunctionBody(
            source: source,
            header: "private func pauseRuntimeForSleep()"
        )

        XCTAssertTrue(
            body.contains("panel?.orderOut") || body.contains("panel.orderOut"),
            "pauseRuntimeForSleep must call `panel?.orderOut(nil)` so the hosted SwiftUI TimelineView stops ticking before sleep and no animation state survives the wake — without it, the post-wake `Date()` jump propagates into BlobShape and hangs the main thread. Body:\n\(body)"
        )
    }

    // MARK: - Source loading helpers (mirror VoiceOrbViewTests pattern)

    private func loadAppDelegateSource() throws -> String {
        let candidates = candidateSourceURLs(for: "AppDelegate.swift")
        for url in candidates {
            if let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) {
                return s
            }
        }
        throw XCTSkip("AppDelegate.swift source not reachable from test bundle — tried: \(candidates.map(\.path).joined(separator: ", "))")
    }

    private func candidateSourceURLs(for filename: String) -> [URL] {
        let env = ProcessInfo.processInfo.environment
        var roots: [URL] = []
        if let srcroot = env["SRCROOT"] { roots.append(URL(fileURLWithPath: srcroot)) }
        if let pkgRoot = env["PACKAGE_PATH"] { roots.append(URL(fileURLWithPath: pkgRoot)) }

        let thisFile = URL(fileURLWithPath: #filePath)
        var cursor = thisFile.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent("Package.swift").path) {
                roots.append(cursor)
                break
            }
            cursor = cursor.deletingLastPathComponent()
        }
        return roots.map { $0.appendingPathComponent("Sources/Sidekey/\(filename)") }
    }

    private func extractFunctionBody(source: String, header: String) throws -> String {
        guard let start = source.range(of: header) else {
            throw XCTSkip("Function header not found: \(header)")
        }
        guard let openBrace = source.range(of: "{", range: start.upperBound..<source.endIndex) else {
            throw XCTSkip("No opening brace after \(header)")
        }
        var depth = 1
        var idx = openBrace.upperBound
        while idx < source.endIndex && depth > 0 {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1 }
            idx = source.index(after: idx)
        }
        return String(source[openBrace.upperBound..<idx])
    }
}
