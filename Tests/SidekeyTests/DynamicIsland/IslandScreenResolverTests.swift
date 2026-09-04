import AppKit
import XCTest
@testable import Sidekey

/// Locks the island's display selection (tester feedback 2026-07-07, two
/// monitors): the island must anchor to a STABLE display — the user's
/// explicit pick, else the notched screen, else the primary display (the
/// one holding the global origin / menu bar). `NSScreen.main` is the
/// screen of the key window, so it flips on every click into a window on
/// another monitor; it must never participate in the selection. Removing
/// it from the signature guarantees focus-independence at compile time.
@MainActor
final class IslandScreenResolverTests: XCTestCase {

    // MARK: - Automatic chain (no preferred display)

    func test_automaticSelectsPrimaryDisplayWhenNoScreenHasNotch() {
        let left = makePlainDescriptor(uuid: "left", x: -1920)
        let primary = makePlainDescriptor(uuid: "primary", x: 0)
        let right = makePlainDescriptor(uuid: "right", x: 1920)

        // Descriptor order follows NSScreen.screens, which AppKit does not
        // guarantee to be stable across reconfigurations — the pick must not
        // depend on it.
        let orderings: [[IslandScreenDescriptor]] = [
            [left, primary, right],
            [right, left, primary],
            [primary, right, left],
        ]
        for descriptors in orderings {
            let selected = IslandScreenResolver.selectDescriptor(
                preferredUUID: nil,
                descriptors: descriptors
            )
            XCTAssertEqual(selected.uuid, "primary")
        }
    }

    func test_automaticSelectsNotchedDisplayOverPrimary() {
        let externalPrimary = makePlainDescriptor(uuid: "external", x: 0)
        let notched = makeNotchedDescriptor(
            uuid: "notched", x: 1920, width: 1512, notchLeft: 670, notchRight: 842
        )

        let selected = IslandScreenResolver.selectDescriptor(
            preferredUUID: nil,
            descriptors: [externalPrimary, notched]
        )

        XCTAssertEqual(selected.uuid, "notched")
    }

    func test_clamshellSelectsThePrimaryExternal() {
        let external = makePlainDescriptor(uuid: "external", x: 0)

        let selected = IslandScreenResolver.selectDescriptor(
            preferredUUID: nil,
            descriptors: [external]
        )

        XCTAssertEqual(selected.uuid, "external")
    }

    // MARK: - Preferred display

    func test_preferredDisplayBeatsNotchAndPrimary() {
        let primary = makePlainDescriptor(uuid: "primary", x: 0)
        let notched = makeNotchedDescriptor(
            uuid: "notched", x: 1920, width: 1512, notchLeft: 670, notchRight: 842
        )
        let preferred = makePlainDescriptor(uuid: "preferred", x: 3432)

        let selected = IslandScreenResolver.selectDescriptor(
            preferredUUID: "preferred",
            descriptors: [primary, notched, preferred]
        )

        XCTAssertEqual(selected.uuid, "preferred")
    }

    func test_missingPreferredFallsBackToAutomaticChain() {
        let primary = makePlainDescriptor(uuid: "primary", x: 0)
        let notched = makeNotchedDescriptor(
            uuid: "notched", x: 1920, width: 1512, notchLeft: 670, notchRight: 842
        )

        let withNotch = IslandScreenResolver.selectDescriptor(
            preferredUUID: "missing",
            descriptors: [primary, notched]
        )
        XCTAssertEqual(withNotch.uuid, "notched")

        let second = makePlainDescriptor(uuid: "second", x: 1920)
        let withoutNotch = IslandScreenResolver.selectDescriptor(
            preferredUUID: "missing",
            descriptors: [second, primary]
        )
        XCTAssertEqual(withoutNotch.uuid, "primary")
    }

    func test_preferredDisplayWinsAgainWhenItReconnects() {
        let primary = makePlainDescriptor(uuid: "primary", x: 0)
        let preferred = makePlainDescriptor(uuid: "preferred", x: 1920)

        let whileDisconnected = IslandScreenResolver.selectDescriptor(
            preferredUUID: "preferred",
            descriptors: [primary]
        )
        XCTAssertEqual(whileDisconnected.uuid, "primary")

        let afterReconnect = IslandScreenResolver.selectDescriptor(
            preferredUUID: "preferred",
            descriptors: [primary, preferred]
        )
        XCTAssertEqual(afterReconnect.uuid, "preferred")
    }

    // MARK: - Degenerate input

    func test_fallbackDescriptorIsStableWhenNoScreensAreAvailable() {
        let selected = IslandScreenResolver.selectDescriptor(
            preferredUUID: nil,
            descriptors: []
        )

        XCTAssertEqual(selected.frame, IslandScreenResolver.fallbackDescriptor.frame)
        XCTAssertEqual(selected.visibleFrame, IslandScreenResolver.fallbackDescriptor.visibleFrame)
    }

    // MARK: - Cross-surface consistency

    func test_dynamicIslandAndMeetingSuggestionUseSameSelectedScreenSnapshot() {
        let descriptor = makeNotchedDescriptor(
            uuid: "selected", x: 100, width: 1512, notchLeft: 670, notchRight: 842
        )

        let islandFrame = IslandFrameLayout.islandFrame(on: descriptor)
        let suggestionFrame = MeetingPillPanel.suggestionFrame(on: descriptor)

        XCTAssertEqual(suggestionFrame.width, islandFrame.width, accuracy: 0.001)
        XCTAssertEqual(suggestionFrame.midX, islandFrame.midX, accuracy: 0.001)
        XCTAssertEqual(
            suggestionFrame.maxY,
            islandFrame.minY - MeetingPillPanel.suggestionGapBelowIsland,
            accuracy: 0.001
        )
    }

    // MARK: - IslandScreenCache end-to-end (no NSScreen involved)

    func test_cacheSelectsFromInjectedDescriptorsWithoutTouchingNSScreen() {
        let cache = IslandScreenCache.shared
        // Restore live-screen descriptors so later suites in this process see
        // real geometry again.
        defer { cache.rebuild() }

        let primary = makePlainDescriptor(uuid: "primary", x: 0)
        let notched = makeNotchedDescriptor(
            uuid: "notched", x: 1920, width: 1512, notchLeft: 670, notchRight: 842
        )
        cache.rebuild(descriptors: [primary, notched])

        XCTAssertEqual(cache.selectedDescriptor(preferredUUID: nil).uuid, "notched")
        XCTAssertEqual(cache.selectedDescriptor(preferredUUID: "primary").uuid, "primary")
        XCTAssertEqual(cache.descriptorsByUUID["notched"]?.uuid, "notched")
    }

    // MARK: - Fixtures

    private func makePlainDescriptor(
        uuid: String,
        x: CGFloat,
        width: CGFloat = 1920
    ) -> IslandScreenDescriptor {
        IslandScreenDescriptor(
            uuid: uuid,
            frame: NSRect(x: x, y: 0, width: width, height: 1080),
            visibleFrame: NSRect(x: x, y: 0, width: width, height: 1055),
            safeAreaTopInset: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
    }

    private func makeNotchedDescriptor(
        uuid: String,
        x: CGFloat,
        width: CGFloat,
        notchLeft: CGFloat,
        notchRight: CGFloat
    ) -> IslandScreenDescriptor {
        let height: CGFloat = 982
        let menuBarHeight: CGFloat = 38
        return IslandScreenDescriptor(
            uuid: uuid,
            frame: NSRect(x: x, y: 0, width: width, height: height),
            visibleFrame: NSRect(x: x, y: 76, width: width, height: height - 114),
            safeAreaTopInset: menuBarHeight,
            auxiliaryTopLeftArea: NSRect(x: x, y: height - menuBarHeight, width: notchLeft, height: menuBarHeight),
            auxiliaryTopRightArea: NSRect(
                x: x + notchRight,
                y: height - menuBarHeight,
                width: width - notchRight,
                height: menuBarHeight
            )
        )
    }
}
