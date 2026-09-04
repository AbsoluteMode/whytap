import SwiftUI
import XCTest
@testable import Sidekey

/// Smoke tests for the three-icon row that replaces the orb + helper
/// when the user hovers. Verifies the contract that drives the visual
/// swap without depending on real frame coordinates.
@MainActor
final class OrbActionsViewTests: XCTestCase {
    // MARK: - Smoke render

    func testRendersInsideHostingControllerWithoutCrashing() {
        let view = OrbActionsView()
        let hosting = NSHostingController(rootView: view)

        XCTAssertNotNil(hosting.view)
    }

    // MARK: - Icon set

    func testThreeIconsAreAgentDropClipboardInOrder() {
        // Maxim's described order: Agent (pink/violet small orb), Drop
        // (white/neutral small orb), Clipboard. The order is exposed as
        // a static array so tests can pin it without rendering.
        let icons = OrbActionsView.iconOrder

        XCTAssertEqual(icons, [.agent, .drop, .clipboard])
    }

    // MARK: - Helper chip contents
    //
    // ROO-208: the per-mode `⌥1` / `⌥2` / `⌥3` hotkeys were removed in
    // favour of a single `⌥V` unified-strip hotkey. The orb action rows
    // now hide the helper chip entirely (sidebar filter inside the strip
    // is the canonical surface) so no per-row keycap content is exposed.
    func testHelperContentsIsNilForAllRows() {
        for id in OrbActionsView.iconOrder {
            XCTAssertNil(
                OrbActionsView.helperContents(for: id),
                "row \(id) must not carry an inline ⌥N helper chip after ROO-208"
            )
        }
    }

    // MARK: - Round 4: anchor + padding fit (Fix A) + icon size (Fix B)

    /// Round 4 Fix A: row magnification uses `.center` anchor so growth
    /// is symmetric. Combined with the frame's horizontal content
    /// padding, this guarantees the magnified row (helper chip + icon)
    /// stays inside the rounded-rect frame on BOTH sides — round 3 used
    /// `.trailing` anchor, which let the helper chip escape leftward
    /// past the frame at peak scale 1.30.
    ///
    /// Contract: at peak scale, the row grows by `rowWidth × (peak - 1)`
    /// total. With `.center` anchor half of that growth goes to each
    /// side, so each side needs at least `rowWidth × (peak - 1) / 2`
    /// of clearance inside the frame's content padding. Pure math —
    /// no rendering needed.
    func testFrameHorizontalPaddingFitsMagnifiedRowAtPeakScale() {
        let rowWidth = OrbActionsView.approximateRowWidth
        let peak = OrbActionsView.magnificationPeak
        let neededClearance = rowWidth * (peak - 1) / 2

        XCTAssertGreaterThanOrEqual(
            OrbActionsView.frameContentHorizontalPadding,
            neededClearance,
            "Frame horizontal padding must be at least \(neededClearance)pt so a row magnified to \(peak)x stays inside the rounded rect. rowWidth=\(rowWidth), padding=\(OrbActionsView.frameContentHorizontalPadding). Increase `OrbActionsView.frameContentHorizontalPadding` or shrink `magnificationPeak`."
        )
    }

    /// Round 4 Fix B: orb glyph size grew 22pt → 28pt (~27% bump) per
    /// Maxim's "процентов на 20–25". Pinned so a future tuning round
    /// doesn't silently shrink the glyphs back.
    func testIconSizeIs28ptAfterRound4Bump() {
        XCTAssertEqual(
            OrbActionsView.iconSize, 28,
            "Round 4 bumped icon glyph size from 22pt to 28pt (~27%). If this drifts back below 26pt the icons read as too small inside the frame."
        )
    }

    // MARK: - PDF resource resolution

    /// Each `IconID` maps to a bundled PDF resource. The mapping is
    /// pinned as a pure helper so unit tests can assert the spelling
    /// without rendering. Catches the case where a future rename of
    /// the SVG source forgets to update the in-code reference.
    func testIconResourceNames() {
        XCTAssertEqual(OrbActionIcon.agent.pdfResourceName, "orb-icon-agent")
        XCTAssertEqual(OrbActionIcon.drop.pdfResourceName, "orb-icon-drop")
        XCTAssertEqual(OrbActionIcon.clipboard.pdfResourceName, "copy-icon-neon")
    }

    /// The 3 PDFs converted from Maxim's SVGs must be reachable inside
    /// the test bundle / app bundle. If `dev-run.sh` and `build-dmg.sh`
    /// stop copying them into Contents/Resources/, this test trips
    /// before a visual smoke does.
    ///
    /// SPM does NOT auto-bundle the `Resources/` directory for the
    /// executable target — that's why `dev-run.sh` / `build-dmg.sh`
    /// copy named files explicitly. In the test bundle, however, the
    /// resources are only present if the test target lists them. The
    /// test falls back to a project-rooted file lookup so it catches
    /// the "PDF missing on disk" regression even if the test bundle
    /// doesn't ship them.
    /// Step 2 (history strip): clicking a row invokes the injected
    /// `onAction` callback with the matching IconID. We don't actually
    /// drive a click through the SwiftUI hierarchy here — instead we
    /// pin the contract that `perform(_:)` forwards to `onAction` by
    /// inspecting the wired callback through the public initializer.
    /// The full click → strip-toggle path is exercised manually after
    /// the wire-up; this guards the injection point itself.
    func testOnActionCallbackIsConfigurable() {
        var lastID: OrbActionsView.IconID?
        let view = OrbActionsView(onAction: { id in lastID = id })
        view.onAction(.drop)
        XCTAssertEqual(lastID, .drop)
    }

    func testIconPDFsExistInProjectResources() {
        for id in OrbActionsView.iconOrder {
            let icon = OrbActionIcon(from: id)
            // Walk up to find Package.swift, then check Resources/.
            let thisFile = URL(fileURLWithPath: #filePath)
            var cursor = thisFile.deletingLastPathComponent()
            var found: URL?
            for _ in 0..<8 {
                let candidate = cursor
                    .appendingPathComponent("Resources")
                    .appendingPathComponent("\(icon.pdfResourceName).pdf")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    found = candidate
                    break
                }
                cursor = cursor.deletingLastPathComponent()
            }
            XCTAssertNotNil(
                found,
                "PDF asset \(icon.pdfResourceName).pdf is missing from Resources/. Did the SVG→PDF conversion run? Did dev-run.sh / build-dmg.sh forget to copy it?"
            )
        }
    }
}
