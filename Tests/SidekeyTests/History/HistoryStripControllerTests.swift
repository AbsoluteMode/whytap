import XCTest
@testable import Sidekey

@MainActor
final class HistoryStripControllerTests: XCTestCase {
    private func makeController(
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> HistoryStripController {
        let suiteName = "history-strip-controller-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return HistoryStripController(
            ownBundleIdentifier: ownBundleIdentifier,
            userDefaults: defaults
        )
    }

    // MARK: - Toggle / Switch / Close

    func testInitiallyClosed() {
        let controller = makeController()
        XCTAssertNil(controller.openMode)
    }

    func testToggleOpensClosedStripWithGivenMode() {
        let controller = makeController()
        controller.toggle(.agent)
        XCTAssertEqual(controller.openMode, .agent)
    }

    func testToggleClosesStripWhenSameModeIsOpen() {
        let controller = makeController()
        controller.toggle(.agent)
        controller.toggle(.agent)
        XCTAssertNil(controller.openMode)
    }

    func testToggleSwitchesModeWhenDifferentModeIsOpen() {
        let controller = makeController()
        controller.toggle(.agent)
        controller.toggle(.drop)
        XCTAssertEqual(controller.openMode, .drop)
    }

    func testCloseClosesStrip() {
        let controller = makeController()
        controller.toggle(.clipboard)
        controller.close()
        XCTAssertNil(controller.openMode)
        XCTAssertNil(controller.expandedEntry)
    }

    // MARK: - Expanded view

    func testExpandSetsExpandedEntryWhenStripIsOpen() {
        let controller = makeController()
        controller.toggle(.agent)
        let entry = HistoryStripExpandedEntry.agent(.text("hello"))
        controller.expand(entry)
        XCTAssertEqual(controller.expandedEntry, entry)
    }

    func testExpandIsIgnoredWhenStripIsClosed() {
        let controller = makeController()
        controller.expand(.agent(.text("hello")))
        XCTAssertNil(controller.expandedEntry)
    }

    func testCollapseClearsExpandedEntryWithoutClosingStrip() {
        let controller = makeController()
        controller.toggle(.drop)
        controller.expand(.drop(.text("dictation")))
        controller.collapseExpanded()
        XCTAssertNil(controller.expandedEntry)
        XCTAssertEqual(controller.openMode, .drop)
    }

    func testCloseClearsBothExpandedAndStrip() {
        let controller = makeController()
        controller.toggle(.agent)
        controller.expand(.agent(.text("hi")))
        controller.close()
        XCTAssertNil(controller.expandedEntry)
        XCTAssertNil(controller.openMode)
    }

    // MARK: - toggleExpand (Round 2 UX 8)

    func testToggleExpandOpensWhenNothingExpanded() {
        let controller = makeController()
        controller.toggle(.agent)
        controller.toggleExpand(.agent(.text("a")))
        XCTAssertEqual(controller.expandedEntry, .agent(.text("a")))
    }

    func testToggleExpandClosesWhenSameEntryAlreadyOpen() {
        let controller = makeController()
        controller.toggle(.agent)
        controller.toggleExpand(.agent(.text("a")))
        controller.toggleExpand(.agent(.text("a")))
        XCTAssertNil(controller.expandedEntry, "second click on same expand button closes")
        XCTAssertEqual(controller.openMode, .agent, "strip stays open")
    }

    func testToggleExpandSwitchesWhenDifferentEntryIsOpen() {
        let controller = makeController()
        controller.toggle(.clipboard)
        controller.toggleExpand(.clipboard(.text("first")))
        controller.toggleExpand(.clipboard(.text("second")))
        XCTAssertEqual(controller.expandedEntry, .clipboard(.text("second")))
    }

    func testToggleExpandIsIgnoredWhenStripIsClosed() {
        let controller = makeController()
        controller.toggleExpand(.agent(.text("ignored")))
        XCTAssertNil(controller.expandedEntry)
        XCTAssertNil(controller.openMode)
    }

    // MARK: - Esc handling

    func testHandleEscClosesExpandedFirstWhenBothVisible() {
        let controller = makeController()
        controller.toggle(.agent)
        controller.expand(.agent(.text("hi")))

        controller.handleEsc()
        XCTAssertNil(controller.expandedEntry)
        XCTAssertEqual(controller.openMode, .agent, "first esc only collapses expanded")

        controller.handleEsc()
        XCTAssertNil(controller.openMode, "second esc closes the strip")
    }

    func testHandleEscClosesStripWhenOnlyStripVisible() {
        let controller = makeController()
        controller.toggle(.drop)
        controller.handleEsc()
        XCTAssertNil(controller.openMode)
    }

    func testHandleEscNoOpWhenNothingOpen() {
        let controller = makeController()
        controller.handleEsc()  // must not crash
        XCTAssertNil(controller.openMode)
        XCTAssertNil(controller.expandedEntry)
    }

    // MARK: - Outside click

    func testHandleOutsideClickClosesEverything() {
        let controller = makeController()
        controller.toggle(.clipboard)
        controller.expand(.clipboard(.text("clip")))
        controller.handleOutsideClick()
        XCTAssertNil(controller.openMode)
        XCTAssertNil(controller.expandedEntry)
    }

    // MARK: - ROO-208: Unified strip filter

    func testRememberedFilterDefaultsToClipboard() {
        XCTAssertEqual(makeController().rememberedFilter(), .clipboard)
    }

    func testRememberedFilterPersistsAcrossControllerInstances() {
        let suiteName = "history-strip-controller-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = HistoryStripController(userDefaults: defaults)
        first.toggle(.clipboard)
        first.setFilter(.drop)
        first.close()

        let second = HistoryStripController(userDefaults: defaults)
        XCTAssertEqual(second.rememberedFilter(), .drop)
    }

    func testSetFilterSwitchesActiveModeWithoutClosing() {
        // Sidebar click changes the visible filter while the strip stays
        // open. Equivalent to mode switch but without the toggle-to-close
        // branch that `toggle(_:)` carries for legacy orb taps.
        let controller = makeController()
        controller.toggle(.clipboard)
        XCTAssertEqual(controller.openMode, .clipboard)
        controller.setFilter(.agent)
        XCTAssertEqual(controller.openMode, .agent, "sidebar pick switches filter")
    }

    func testSetFilterIsNoOpWhenStripIsClosed() {
        // Sidebar buttons are only interactive while the strip is on
        // screen; programmatic calls when closed must not open the strip.
        let controller = makeController()
        controller.setFilter(.agent)
        XCTAssertNil(controller.openMode)
    }

    func testSetFilterClearsExpandedEntryWhenSwitching() {
        // Switching filter while a card is expanded would render the
        // expanded panel for a card from the OLD filter — same guard as
        // `toggle(_:)` for mode switches.
        let controller = makeController()
        controller.toggle(.clipboard)
        controller.expand(.clipboard(.text("a")))
        controller.setFilter(.drop)
        XCTAssertNil(controller.expandedEntry)
    }

    func testSetFilterToSameFilterIsNoOp() {
        // Re-tapping the active sidebar filter must not re-emit a change
        // (avoids cross-fade flash) and must not collapse any expanded.
        let controller = makeController()
        controller.toggle(.clipboard)
        controller.expand(.clipboard(.text("a")))
        controller.setFilter(.clipboard)
        XCTAssertEqual(controller.openMode, .clipboard)
        XCTAssertEqual(
            controller.expandedEntry,
            .clipboard(.text("a")),
            "tapping the already-active filter is a no-op"
        )
    }

    // MARK: - ROO-208 iter 15: hover + target app

    /// Helper card used by hover tests. The clipboard text variant is
    /// the cheapest to construct (no SQLite roundtrip) and Equatable
    /// already by `HistoryStripCard`'s synthesized conformance.
    private static func makeClipboardCard(id: Int64, text: String) -> HistoryStripCard {
        .clipboard(.init(
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            payload: .text(text)
        ))
    }

    func testSetHoveredCardStoresEnterTransition() {
        let controller = makeController(ownBundleIdentifier: nil)
        controller.toggle(.clipboard)
        let card = Self.makeClipboardCard(id: 1, text: "alpha")
        controller.setHoveredCard(card, from: card)
        XCTAssertEqual(controller.hoveredCard, card)
    }

    func testSetHoveredCardExitClearsWhenEmitterMatches() {
        let controller = makeController(ownBundleIdentifier: nil)
        controller.toggle(.clipboard)
        let card = Self.makeClipboardCard(id: 1, text: "alpha")
        controller.setHoveredCard(card, from: card)
        controller.setHoveredCard(nil, from: card)
        XCTAssertNil(controller.hoveredCard)
    }

    func testSetHoveredCardExitFromDifferentEmitterIsIgnored() {
        // Fast diagonal cursor sweep: enter B fires before A's exit.
        // The stale exit from A must not clear B's hover state.
        let controller = makeController(ownBundleIdentifier: nil)
        controller.toggle(.clipboard)
        let a = Self.makeClipboardCard(id: 1, text: "a")
        let b = Self.makeClipboardCard(id: 2, text: "b")
        controller.setHoveredCard(a, from: a)
        controller.setHoveredCard(b, from: b)         // sweep to B
        controller.setHoveredCard(nil, from: a)       // stale exit from A
        XCTAssertEqual(controller.hoveredCard, b, "B's hover survives A's stale exit")
    }

    func testCloseClearsHoverAndTargetApp() {
        let controller = makeController(ownBundleIdentifier: nil)
        controller.toggle(.clipboard)
        controller.setHoveredCard(Self.makeClipboardCard(id: 1, text: "a"), from: nil)
        controller.setTargetAppName("TextEdit")
        controller.close()
        XCTAssertNil(controller.hoveredCard)
        XCTAssertNil(controller.targetAppName)
    }

    func testSwitchingFiltersClearsHover() {
        // Switching filters while a card is hovered would point the
        // hover state at a card that's no longer in the visible feed.
        let controller = makeController(ownBundleIdentifier: nil)
        controller.toggle(.clipboard)
        controller.setHoveredCard(Self.makeClipboardCard(id: 1, text: "a"), from: nil)
        controller.setFilter(.drop)
        XCTAssertNil(controller.hoveredCard)
    }

    func testSetTargetAppNameUpdatesPublishedValue() {
        // ROO-208 iter 17: target is set ONCE by AppDelegate after the
        // AX text-focus check; this test exercises the published-value
        // contract that the strip view observes.
        let controller = makeController(ownBundleIdentifier: nil)
        controller.toggle(.clipboard)
        controller.setTargetAppName("Slack")
        XCTAssertEqual(controller.targetAppName, "Slack")
        // The setter still accepts overwrite — tests may simulate
        // a re-open scenario.
        controller.setTargetAppName("Notes")
        XCTAssertEqual(controller.targetAppName, "Notes")
    }

    func testSetTargetAppNameAcceptsNilForNonEditableTargets() {
        // ROO-208 iter 17: `nil` represents the "captured app has no
        // editable focused element" case (Desktop / Finder / Safari
        // with no text input). The hint must collapse and Enter must
        // become a silent no-op when this is the active value.
        let controller = makeController(ownBundleIdentifier: nil)
        controller.toggle(.clipboard)
        controller.setTargetAppName(nil)
        XCTAssertNil(controller.targetAppName)
    }

    func testTogglingTheCurrentFilterClosedClearsTargetApp() {
        let controller = makeController(ownBundleIdentifier: nil)
        controller.toggle(.clipboard)
        controller.setTargetAppName("Slack")
        controller.toggle(.clipboard)
        XCTAssertNil(controller.targetAppName)
    }
}
