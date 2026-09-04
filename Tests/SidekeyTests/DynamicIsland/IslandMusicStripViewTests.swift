import XCTest
@testable import Sidekey

/// Hit-testing contract for the hover-gated Now Playing player strip's
/// transport buttons (⏮ / ▶ / ⏭).
///
/// On-device regression: the strip lives at the TOP of the hover drawer
/// (between the compact pill and the hover panel). Its transport buttons
/// were built with `.onTapGesture` (copied from `IslandUpdateAvailablePill`,
/// which lives in the always-mouse-active COMPACT band). In the EXPANDED
/// hover band — a non-key, non-activating `NSPanel` that is never key — a
/// bare `.onTapGesture` does NOT reliably receive the click, while a SwiftUI
/// `Button` does (the hover PANEL below the strip uses `Button` and works).
/// The fix routes the strip's transport taps through `Button`, the same path
/// `IslandHoverPanelControl` already proves works in this exact band.
final class IslandMusicStripViewTests: XCTestCase {

    func test_transportButtonsUseButtonActionPathNotBareTapGesture() throws {
        let source = try Self.source(
            "Sources/Sidekey/DynamicIsland/IslandMusicStripView.swift"
        )
        let buttonSource = try XCTUnwrap(
            Self.structBody(named: "IslandMusicTransportButton", in: source),
            "IslandMusicTransportButton struct body must be locatable."
        )

        XCTAssertTrue(
            buttonSource.contains("Button(action: action)"),
            "Strip transport buttons must use the SwiftUI Button path — the only one that "
                + "reliably receives clicks in the non-key expanded hover band (the hover panel "
                + "below the strip uses Button and works; bare .onTapGesture does not)."
        )
        XCTAssertFalse(
            buttonSource.contains(".onTapGesture(perform: action)"),
            "Bare .onTapGesture on the strip's transport buttons does not fire in the expanded "
                + "hover band — this is the on-device un-clickable-strip regression."
        )
    }

    func test_liveMode_rendersOnlyPlayPause_gatedOnSnapshotIsLive() throws {
        // Radio / live stream (`snapshot.isLive`): the strip must render ONLY
        // the play/pause button — prev + next are meaningless (nothing to seek
        // or skip). The transport cluster gates the backward/forward buttons on
        // `snapshot.isLive` so they are omitted, leaving play/pause in the
        // trailing-most slot (aligned with the geometric live hit dispatch).
        let source = try Self.source(
            "Sources/Sidekey/DynamicIsland/IslandMusicStripView.swift"
        )
        let stripSource = try XCTUnwrap(
            Self.structBody(named: "IslandMusicStripView", in: source),
            "IslandMusicStripView struct body must be locatable."
        )

        XCTAssertTrue(
            stripSource.contains("snapshot.isLive"),
            "The strip must branch on snapshot.isLive to hide prev/next for live streams."
        )
        // The play/pause button is always present (both branches); the
        // backward/forward buttons must sit inside the non-live branch only.
        XCTAssertTrue(
            stripSource.contains("backward.end.fill"),
            "Previous-track button glyph must still exist for non-live tracks."
        )
        XCTAssertTrue(
            stripSource.contains("forward.end.fill"),
            "Next-track button glyph must still exist for non-live tracks."
        )
    }

    // MARK: - Helpers (mirror IslandHoverPanelControlTests)

    private static func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func structBody(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "struct \(name): View") else {
            return nil
        }
        let tail = source[start.lowerBound...]
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
