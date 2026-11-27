import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Costs → "<Feature> · Models used": the detail and the row fill belong to
/// the row under the pointer. Reports: 2026-11-26 (Agent hovered, Translation
/// shown, blinking) and 2026-11-27 (pointer on Drop Fast, Meetings shown).
final class AIUsageModelsHoverTests: XCTestCase {
    private typealias S = AIUsageModelsHoverState
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private var state = S()
    private var now: Date!

    override func setUp() { now = t0; state = S() }

    private func send(_ event: S.Event) { state.send(event, now: now) }
    /// Real pointer motion; `send(.pointer(_))` is a re-read of a resting pointer.
    private func move(_ pointer: S.Pointer) { send(.pointerMoved(pointer)) }
    private func wait(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds); send(.tick) }
    private func assertShows(_ id: String?, _ message: String = "", line: UInt = #line) {
        XCTAssertEqual(state.open, id, message, line: line)
        for row in ["Drop Fast", "Drop Smart", "Meetings", "Agent"] where row != state.pointerRow && row != id {
            XCTAssertFalse(state.highlighted(row), "\(row) must not be highlighted", line: line)
        }
    }

    private func openFromOutside(_ id: String) {
        move(.row(id)); wait(S.openDelay)
        assertShows(id)
    }

    func test_entering_from_outside_opens_after_the_short_delay() {
        move(.row("Agent"))
        XCTAssertNil(state.open); XCTAssertTrue(state.highlighted("Agent"))
        wait(S.openDelay / 2); XCTAssertNil(state.open)
        wait(S.openDelay / 2); assertShows("Agent")
    }

    func test_passing_over_rows_from_outside_opens_only_where_the_pointer_stops() {
        move(.row("Agent")); wait(0.05)
        move(.row("Meetings")); wait(0.05)
        XCTAssertNil(state.open)
        wait(S.openDelay); assertShows("Meetings")
    }

    /// Report 1: Translation's detail stayed while the pointer was on Agent.
    func test_moving_to_another_row_switches_at_once() {
        openFromOutside("Meetings")
        move(.row("Drop Smart")); assertShows("Drop Smart")
        XCTAssertTrue(state.highlighted("Drop Smart")); XCTAssertFalse(state.highlighted("Meetings"))
        move(.row("Drop Fast")); assertShows("Drop Fast")
    }

    func test_moving_onto_the_detail_keeps_it_and_its_row_fill() {
        openFromOutside("Meetings")
        move(.detail)
        wait(5); assertShows("Meetings")
        XCTAssertTrue(state.highlighted("Meetings"))
    }

    /// Report 2: from the Meetings detail (which covers Drop Smart) the
    /// pointer went up to Drop Fast; Meetings stayed open and highlighted.
    func test_leaving_the_detail_up_onto_a_row_shows_that_row() {
        openFromOutside("Meetings")
        move(.detail)
        move(.row("Drop Fast"))
        assertShows("Drop Fast")
        XCTAssertTrue(state.highlighted("Drop Fast")); XCTAssertFalse(state.highlighted("Meetings"))
    }

    func test_leaving_the_detail_down_onto_a_row_shows_that_row() {
        openFromOutside("Meetings")
        move(.detail); move(.row("Agent"))
        assertShows("Agent")
    }

    func test_leaving_row_and_detail_closes_immediately() {
        openFromOutside("Meetings")
        move(.outside); assertShows(nil)
        openFromOutside("Agent")
        move(.detail); move(.outside); assertShows(nil)
        XCTAssertFalse(state.highlighted("Agent"))
    }

    func test_a_click_opens_at_once_and_does_not_hold_against_the_pointer() {
        move(.row("Agent")); send(.clicked("Agent")); assertShows("Agent")
        move(.row("Meetings")); assertShows("Meetings", "no pin outlives the pointer")
    }

    /// The transient popover closes on the mouse-down of a click on its own
    /// row; that click closes it instead of reopening it.
    func test_clicking_the_open_row_closes_it() {
        openFromOutside("Agent")
        send(.clicked("Agent")); assertShows(nil)
        wait(1); assertShows(nil, "it stays closed while the pointer rests on the row")
        send(.clicked("Agent")); assertShows("Agent")
    }

    func test_escape_closes_until_the_pointer_leaves_the_row() {
        openFromOutside("Agent")
        send(.escape); assertShows(nil)
        move(.outside); move(.row("Agent")); wait(S.openDelay)
        assertShows("Agent")
    }

    func test_keyboard_focus_opens_and_the_pointer_takes_over() {
        send(.focused("Agent")); assertShows("Agent")
        XCTAssertTrue(state.highlighted("Agent"))
        send(.unfocused("Agent")); send(.focused("Meetings")); assertShows("Meetings")
        move(.row("Drop Fast")); assertShows("Drop Fast")
        move(.outside); assertShows(nil)
        send(.focused("Agent")); send(.escape); assertShows(nil)
    }

    func test_focus_owns_the_fill_while_the_pointer_rests_elsewhere() {
        openFromOutside("Meetings")
        send(.focused("Agent"))
        XCTAssertTrue(state.highlighted("Agent")); XCTAssertFalse(state.highlighted("Meetings"))
        move(.row("Drop Fast"))
        XCTAssertTrue(state.highlighted("Drop Fast")); XCTAssertFalse(state.highlighted("Agent"))
    }

    /// Repeated activation of one row toggles it, from the mouse or the keyboard.
    func test_repeated_activation_toggles() {
        openFromOutside("Agent")
        for expected in [nil, "Agent", nil, "Agent"] as [String?] {
            send(.clicked("Agent")); assertShows(expected)
        }
        send(.focused("Translation"))
        send(.clicked("Translation")); assertShows(nil)
        send(.clicked("Translation")); assertShows("Translation"); XCTAssertEqual(state.keyboardRow, "Translation")
    }

    /// AppKit cannot close the detail on its own: the popover's behavior is
    /// application-defined, so no late native dismissal exists to misroute
    /// (builder tickets 693, 701, 711).
    func test_the_popover_is_never_closed_by_appkit() {
        XCTAssertEqual(AIUsageModelsHoverController.popoverBehavior, .applicationDefined)
    }

    // Ticket 701: motion versus re-reading a resting pointer, and ownership.

    func test_motion_hands_the_detail_back_but_a_resting_reread_does_not() {
        openFromOutside("Meetings")
        send(.focused("Agent"))
        send(.pointer(.row("Meetings"))); wait(1)
        assertShows("Agent", "a poll at the resting point keeps Tab's detail")
        XCTAssertTrue(state.highlighted("Agent")); XCTAssertFalse(state.highlighted("Meetings"))
        send(.pointerMoved(.row("Meetings")))
        assertShows("Meetings"); XCTAssertTrue(state.highlighted("Meetings"))
        XCTAssertNil(state.keyboardRow)
    }

    func test_motion_onto_the_keyboard_detail_keeps_it_with_its_fill() {
        send(.focused("Agent"))
        send(.pointerMoved(.detail))
        assertShows("Agent"); XCTAssertTrue(state.highlighted("Agent")); XCTAssertNil(state.keyboardRow)
        send(.pointerMoved(.outside)); assertShows(nil)
    }

    func test_focus_leaving_with_the_pointer_outside_closes() {
        send(.focused("Agent"))
        send(.unfocused("Agent"))
        assertShows(nil)
    }

    func test_tab_between_rows_in_either_event_order_ends_on_the_new_row() {
        send(.focused("Agent")); send(.focused("Translation")); send(.unfocused("Agent"))
        XCTAssertEqual(state.open, "Translation"); XCTAssertTrue(state.highlighted("Translation"))
        send(.unfocused("Translation")); send(.focused("Agent"))
        XCTAssertEqual(state.open, "Agent"); XCTAssertTrue(state.highlighted("Agent"))
    }

    func test_return_on_a_focused_row_while_the_pointer_rests_elsewhere_stays_with_the_keyboard() {
        openFromOutside("Meetings")
        send(.clicked("Agent")) // activation not under the pointer
        assertShows("Agent"); XCTAssertEqual(state.keyboardRow, "Agent")
        XCTAssertTrue(state.highlighted("Agent"))
    }

    func test_a_detail_alone_is_never_under_the_pointer_when_nothing_is_open() {
        move(.detail)
        XCTAssertEqual(state.pointer, .outside)
    }

    // MARK: Rows leaving the table (builder finding on ticket 620)

    func test_a_removed_row_never_opens_after_its_delay() {
        move(.row("Agent"))
        send(.rowsChanged(["Meetings"]))
        wait(S.openDelay * 3)
        assertShows(nil); XCTAssertFalse(state.highlighted("Agent"))
    }

    func test_an_emptied_table_retires_everything() {
        openFromOutside("Agent"); move(.detail)
        send(.rowsChanged([]))
        XCTAssertEqual(state, S())
    }

    func test_rows_that_stay_keep_their_state() {
        openFromOutside("Agent")
        send(.rowsChanged(["Agent", "Meetings"]))
        assertShows("Agent")
    }
}

/// The real Costs view in an NSHostingView inside a window (kept off
/// screen), driven with mouse-moved events. Where each row is comes from the
/// rendered pixels (its separator lines), independent of the controller's
/// geometry, and the row fill is checked in the pixels too.
@MainActor
final class AIUsageModelsHoverHostingTests: XCTestCase {
    private let titles = ["Drop Fast", "Drop Smart", "Meetings", "Agent", "Translation"]
    private var window: NSWindow!
    private var host: NSHostingView<AnyView>!
    private var controller: AIUsageModelsHoverController!
    private var pointer = NSPoint.zero
    /// The controller's clock; tests advance it instead of racing real timers.
    private var clock = Date(timeIntervalSinceReferenceDate: 50_000)
    private var detail: NSRect?
    /// What the controller last presented; must always equal the open row.
    private var presented: String?
    private var storeURL: URL!
    /// Row bands measured before any row carries a fill (a fill touching a
    /// separator hides it); shifted by hand when the test scrolls.
    private var bands: [ClosedRange<CGFloat>] = []

    override func setUp() async throws {
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("hover-\(UUID().uuidString).sqlite")
        let store = AIUsageStore(url: storeURL)
        let now = Date()
        let contexts: [(AIFeature, String)] = [(.dropFast, "a"), (.dropFast, "b"), (.dropSmart, "c"),
                                               (.meetings, "d"), (.meetingNotes, "e"), (.agent, "f"), (.translation, "g")]
        for (feature, model) in contexts {
            try await store.insert(AIUsageEvent(createdAt: now, context: AIUsageContext(feature: feature, account: .openRouter, model: model),
                                                currency: .usd, amount: 0.1, basis: .estimated))
        }
        let model = AIUsageCostsViewModel(store: store, loadPrices: { .init(events: $0) })
        await model.load(AIUsagePeriod.month.interval(now: now, start: now, end: now)!)
        controller = AIUsageModelsHoverController(now: { [unowned self] in clock },
                                                  mouseLocation: { [unowned self] in pointer },
                                                  topWindowNumber: { [unowned self] _ in window.windowNumber })
        controller.detailScreenFrameOverride = { [unowned self] in detail }
        controller.presenter = { [unowned self] row, _ in presented = row?.id }
        host = NSHostingView(rootView: AnyView(AIUsageCostsView(model: model, now: { now }, modelsHover: controller)
            .environment(\.colorScheme, .light)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 700, height: 900),
                          styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        try await settle()
        bands = try measureRowBands()
    }

    override func tearDown() async throws {
        controller.stop()
        window.contentView = nil; window.close()
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func settle() async throws {
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(60)) }
    }

    private func bitmap() throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Alpha of the pixel at host point (x, y from the top).
    private func ink(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> CGFloat {
        let scale = CGFloat(rep.pixelsHigh) / host.bounds.height
        return rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? 0
    }

    /// Feature rows as host y-ranges (from the top), found from separator
    /// lines in the leading padding, where only separators and fills draw.
    private func rowBands() throws -> [ClosedRange<CGFloat>] { bands }

    private func measureRowBands() throws -> [ClosedRange<CGFloat>] {
        try settleSync()
        let rep = try bitmap()
        // Separators are thin runs of ink; a hover fill is a long one.
        var lines: [CGFloat] = []
        var runStart: CGFloat?
        var y: CGFloat = 0
        while y <= host.bounds.height {
            let inked = y < host.bounds.height && ink(rep, x: 6, y: y) > 0.05
            if inked, runStart == nil { runStart = y }
            if !inked, let start = runStart {
                if y - start <= 1.5 { lines.append(start) }
                runStart = nil
            }
            y += 0.5
        }
        XCTAssertGreaterThanOrEqual(lines.count, titles.count, "separators: \(lines)")
        let rowLines = Array(lines.suffix(titles.count))   // above each feature row
        let height = rowLines[1] - rowLines[0]
        return rowLines.map { $0...($0 + height) }
    }
    private func settleSync() throws { host.layoutSubtreeIfNeeded() }

    private func screenPoint(x: CGFloat, yFromTop: CGFloat) -> NSPoint {
        window.convertToScreen(NSRect(origin: host.convert(NSPoint(x: x, y: yFromTop), to: nil), size: .zero)).origin
    }

    private func center(_ title: String, x: CGFloat = 60) throws -> NSPoint {
        let band = try rowBands()[try XCTUnwrap(titles.firstIndex(of: title))]
        return screenPoint(x: x, yFromTop: (band.lowerBound + band.upperBound) / 2)
    }

    /// Moves the pointer with a real mouse-moved event through the app.
    private func moveMouse(to point: NSPoint) {
        pointer = point
        let local = window.convertPoint(fromScreen: point)
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: local, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 0, pressure: 0) {
            NSApp.sendEvent(event)
        }
        controller.checkPointer() // the poll's backstop, run now for determinism
    }

    /// Advances the controller's clock and applies due timers at once, so a
    /// loaded machine cannot reorder them against the test (builder, ticket 693).
    private func wait(_ seconds: TimeInterval) async throws {
        clock = clock.addingTimeInterval(seconds + 0.001)
        controller.checkPointer()
        controller.send(.tick)
        try await settle()
    }

    /// Exactly `title` carries the hover fill in the rendered pixels.
    private func assertFilled(_ title: String?, line: UInt = #line) throws {
        XCTAssertEqual(presented, controller.state.open, "the presented detail is the open row", line: line)
        try settleSync()
        let rep = try bitmap()
        for (name, band) in zip(titles, try rowBands()) {
            let filled = ink(rep, x: 6, y: (band.lowerBound + band.upperBound) / 2) > 0.02
            XCTAssertEqual(filled, name == title, "\(name) fill", line: line)
        }
    }

    /// The real application-defined NSPopover: shown beside the open row's
    /// name, switched in place to another row, closed by the state only.
    func test_real_popover_follows_the_state() async throws {
        controller.presenter = nil
        window.orderFrontRegardless() // far off every display
        defer { window.orderOut(nil) }
        try await settle()
        moveMouse(to: try center("Meetings")); try await wait(AIUsageModelsHoverState.openDelay)
        try await settle()
        XCTAssertEqual(controller.presentedRowID, "Meetings")
        let meetings = try XCTUnwrap(controller.screenFrame(of: "Meetings"))
        let frame = try XCTUnwrap(controller.detailWindowFrame)
        XCTAssertGreaterThan(frame.minX, meetings.minX + 60, "beside the name, not over it")
        // AppKit keeps the popover window on a display; with the window far
        // off screen only its anchor (positioning rect) shows the row.
        let pointsAt = try XCTUnwrap(controller.presentedAnchorScreenRect)
        XCTAssertTrue(meetings.contains(NSPoint(x: pointsAt.midX, y: pointsAt.midY)), "points at the Meetings name")

        moveMouse(to: try center("Drop Fast", x: 40)); try await settle()
        XCTAssertEqual(controller.presentedRowID, "Drop Fast")
        let dropFast = try XCTUnwrap(controller.screenFrame(of: "Drop Fast"))
        let movedTo = try XCTUnwrap(controller.presentedAnchorScreenRect)
        XCTAssertTrue(dropFast.contains(NSPoint(x: movedTo.midX, y: movedTo.midY)), "moved to the Drop Fast name")

        moveMouse(to: screenPoint(x: 60, yFromTop: 20)); try await settle()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(controller.presentedRowID)
    }

    /// The second report's break: every row's NSView claimed the whole window.
    func test_each_row_resolves_to_itself_and_nothing_else() throws {
        for title in titles {
            XCTAssertEqual(controller.resolve(try center(title)), .row(title))
            XCTAssertEqual(controller.resolve(try center(title, x: 400)), .row(title), "the empty middle")
            XCTAssertEqual(controller.resolve(try center(title, x: 660)), .row(title), "the price")
            let frame = try XCTUnwrap(controller.screenFrame(of: title))
            XCTAssertLessThan(frame.height, 120, "\(title) is one row, not the window")
        }
        XCTAssertEqual(controller.resolve(screenPoint(x: 60, yFromTop: 20)), .outside, "the period header")
    }

    func test_pointer_up_from_the_detail_shows_the_row_under_it() async throws {
        moveMouse(to: try center("Meetings")); try await wait(AIUsageModelsHoverState.openDelay)
        XCTAssertTrue(controller.isPresented("Meetings"))
        try assertFilled("Meetings")
        // The detail opens beside the name and covers Drop Smart, as in the
        // owner's screenshot.
        let bands = try rowBands()
        let top = screenPoint(x: 300, yFromTop: bands[1].lowerBound + 20)
        let bottom = screenPoint(x: 690, yFromTop: bands[3].upperBound)
        detail = NSRect(x: top.x, y: bottom.y, width: bottom.x - top.x, height: top.y - bottom.y)
        moveMouse(to: NSPoint(x: detail!.midX, y: detail!.maxY - 10))
        XCTAssertTrue(controller.isPresented("Meetings"))
        try assertFilled("Meetings")

        // Up past the detail onto Drop Fast, right of its name (red arrow).
        moveMouse(to: try center("Drop Fast", x: 350))
        XCTAssertTrue(controller.isPresented("Drop Fast"))
        XCTAssertFalse(controller.isPresented("Meetings"))
        try assertFilled("Drop Fast")
    }

    func test_pointer_down_from_the_detail_and_back_up_past_it() async throws {
        moveMouse(to: try center("Drop Smart")); try await wait(AIUsageModelsHoverState.openDelay)
        let bands = try rowBands()
        let top = screenPoint(x: 300, yFromTop: bands[0].lowerBound + 10)
        let bottom = screenPoint(x: 690, yFromTop: bands[2].upperBound - 10)
        detail = NSRect(x: top.x, y: bottom.y, width: bottom.x - top.x, height: top.y - bottom.y)
        moveMouse(to: NSPoint(x: detail!.midX, y: detail!.minY + 5))
        XCTAssertTrue(controller.isPresented("Drop Smart"))

        // Down out of the detail onto Agent beneath it.
        moveMouse(to: try center("Agent", x: 400))
        XCTAssertTrue(controller.isPresented("Agent"))
        XCTAssertFalse(controller.isPresented("Drop Smart"), "the old detail closes at once")
        try assertFilled("Agent")

        // Back up along the names column past every row.
        detail = nil
        for title in titles.reversed() {
            moveMouse(to: try center(title))
            XCTAssertTrue(controller.isPresented(title), "\(title)'s detail while on \(title)")
            try assertFilled(title)
        }
    }

    func test_leaving_the_table_closes_immediately() async throws {
        moveMouse(to: try center("Agent")); try await wait(AIUsageModelsHoverState.openDelay)
        XCTAssertTrue(controller.isPresented("Agent"))
        moveMouse(to: screenPoint(x: 60, yFromTop: 20))
        XCTAssertNil(controller.state.open)
        try assertFilled(nil)
    }

    func test_rows_scrolled_under_the_pointer_follow_the_pointer() async throws {
        // A short pane, so the table really scrolls.
        window.setContentSize(NSSize(width: 700, height: 380)); host.frame.size = NSSize(width: 700, height: 380)
        try await settle() // top-aligned content: the bands measured at 900 pt still hold
        let scroll = try XCTUnwrap(findScrollView(host))
        let documentHeight = try XCTUnwrap(scroll.documentView).frame.height
        XCTAssertGreaterThan(documentHeight, scroll.contentView.bounds.height, "content taller than the pane")
        moveMouse(to: try center("Drop Smart")); try await wait(AIUsageModelsHoverState.openDelay)
        let before = try rowBands()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + before[1].lowerBound - before[0].lowerBound + 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        controller.checkPointer() // the pointer rests; the content moved under it
        let delta = before[1].lowerBound - before[0].lowerBound + 40
        bands = before.map { ($0.lowerBound - delta)...($0.upperBound - delta) }
        let after = bands
        let y = window.convertPoint(fromScreen: pointer)
        let hostY = host.convert(y, from: nil).y
        XCTAssertEqual(scroll.contentView.bounds.minY, before[1].lowerBound - before[0].lowerBound + 40, accuracy: 1)
        let under = try XCTUnwrap(zip(titles, after).first { $0.1.contains(hostY) }?.0)
        XCTAssertNotEqual(under, "Drop Smart", "the content scrolled")
        XCTAssertEqual(controller.state.pointerRow, under)
        XCTAssertTrue(controller.isPresented(under))
        try assertFilled(under)
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = findScrollView(sub) { return found } }
        return nil
    }
}

// Builder findings on queue ticket 693 (2026-11-27), kept under the names the
// builder used for its probes.
extension AIUsageModelsHoverTests {
    func testBuilder693TabOpensFocusedRowWithPointerRestingOnAnotherRow() {
        openFromOutside("Meetings")
        send(.focused("Agent"))
        XCTAssertEqual(state.open, "Agent", "Tab gives the focused row its detail even with the pointer resting on another row")
        move(.row("Drop Fast"))
        assertShows("Drop Fast")
    }

    func testBuilder693SecondClickClosesBeforeTheNativePopoverReportsDismissal() {
        move(.row("Agent"))
        send(.clicked("Agent"))
        assertShows("Agent")
        send(.clicked("Agent"))
        XCTAssertNil(state.open, "A second click during presentation closes without needing a native callback")
        wait(1)
        XCTAssertNil(state.open)
    }
}

extension AIUsageModelsHoverHostingTests {
    func testBuilder693DisabledTableDoesNotOpenDetailsOnPointerMovement() async throws {
        let now = Date()
        let store = AIUsageStore(url: storeURL)
        let model = AIUsageCostsViewModel(store: store, loadPrices: { .init(events: $0) })
        await model.load(AIUsagePeriod.month.interval(now: now, start: now, end: now)!)
        host.rootView = AnyView(AIUsageCostsView(model: model, now: { now }, modelsHover: controller)
            .disabled(true).environment(\.colorScheme, .light))
        try await settle()
        bands = try measureRowBands()
        moveMouse(to: try center("Meetings", x: 500))
        try await wait(AIUsageModelsHoverState.openDelay)
        XCTAssertNil(controller.state.open, "The app-wide pointer observer must honor the disabled table")
        try assertFilled(nil)
    }

    func testBuilder693RenderNormalAndHoveredCosts() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHYTAP_COSTS_QUEUE_RENDER_DIR"] else { throw XCTSkip("No render directory") }
        let dir = URL(fileURLWithPath: path)
        for (state, target) in [("normal", nil), ("hover", "Drop Fast")] as [(String, String?)] {
            if let target { moveMouse(to: try center(target, x: 400)) }
            try await settle()
            try assertFilled(target)
            let rep = try bitmap()
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent("Costs-700-\(state).png"))
        }
    }
}

// Builder findings on queue ticket 701 (2026-11-27), kept under the names the
// builder used for its probes.
extension AIUsageModelsHoverHostingTests {
    func testBuilder701PointerMotionWithinItsRowReclaimsTheDetailFromKeyboardFocus() async throws {
        let start = try center("Meetings", x: 60)
        let across = try center("Meetings", x: 410)
        XCTAssertNotEqual(start, across)
        moveMouse(to: start)
        try await wait(AIUsageModelsHoverState.openDelay)
        XCTAssertTrue(controller.isPresented("Meetings"))

        controller.send(.focused("Agent"))
        try await settle()
        XCTAssertTrue(controller.isPresented("Agent"), "A resting pointer must not override Tab")
        try assertFilled("Agent")
        XCTAssertEqual(controller.resolve(across), .row("Meetings"))

        moveMouse(to: across)
        XCTAssertTrue(controller.isPresented("Meetings"), "A new pointer position within the same row hands back ownership")
        try assertFilled("Meetings")
    }
}

extension AIUsageModelsHoverTests {
    func testBuilder701LeavingAKeyboardRowDoesNotKeepItsDetailUnderAnotherRowsFill() {
        openFromOutside("Meetings")
        send(.focused("Agent"))
        assertShows("Agent")
        send(.unfocused("Agent")) // Focus moves to the period control, not a different model row.
        XCTAssertNotEqual(state.open, "Agent")
        XCTAssertTrue(state.highlighted("Meetings"))
    }

    func testBuilder701ClickOnThePointerRowKeepsDetailAndFillOnThatRow() {
        openFromOutside("Meetings")
        send(.focused("Agent"))
        send(.clicked("Meetings"))
        assertShows("Meetings")
        XCTAssertTrue(state.highlighted("Meetings"))
        XCTAssertFalse(state.highlighted("Agent"))
    }

    func testBuilder701DelayedDismissalDoesNotCloseANewerPresentationOfTheSameRow() {
        openFromOutside("Agent")
        send(.clicked("Agent"))
        assertShows(nil)
        send(.clicked("Agent"))
        assertShows("Agent")
        // No native dismissal exists any more (application-defined popover);
        // the reopened detail stays until the state closes it.
        wait(1)
        assertShows("Agent", "nothing from the first presentation can close the second")
    }
}

extension AIUsageModelsHoverHostingTests {
    func testBuilder701PointerMotionOutsideClosesKeyboardDetail() async throws {
        let start = screenPoint(x: 75, yFromTop: 20)
        let across = screenPoint(x: 350, yFromTop: 20)
        XCTAssertEqual(controller.resolve(start), .outside)
        XCTAssertEqual(controller.resolve(across), .outside)
        moveMouse(to: start)
        controller.send(.focused("Agent"))
        try await settle()
        XCTAssertTrue(controller.isPresented("Agent"))

        moveMouse(to: across)
        XCTAssertNil(controller.state.open, "A new pointer position outside both the detail and its row closes it")
        try assertFilled(nil)
    }
}

// Builder findings on queue ticket 711 (2026-11-27). The dismissal-class
// probes are adapted: the detail is an application-defined NSPopover now, so
// AppKit delivers no dismissal and the `.dismissedBySystem` event is gone.
extension AIUsageModelsHoverTests {
    func testBuilder711LayoutChangeUnderRestingPointerPreservesKeyboardOwnership() {
        for reread in [S.Pointer.row("Drop Fast"), .outside, .detail] {
            now = t0
            state = S()
            openFromOutside("Meetings")
            send(.focused("Agent"))
            send(.pointer(reread))

            assertShows("Agent", "A stationary reread (\(reread)) cannot take Tab's detail")
            XCTAssertEqual(state.keyboardRow, "Agent")
            XCTAssertTrue(state.highlighted("Agent"))
        }
    }

    func testBuilder711OldDismissalCannotCloseReopenedRowAfterAnImplicitClose() {
        let exits: [S.Event] = [
            .pointerMoved(.row("Meetings")), .pointerMoved(.outside),
            .focused("Meetings"), .clicked("Meetings")
        ]
        for exit in exits {
            now = t0
            state = S()
            openFromOutside("Agent")
            send(exit)
            XCTAssertNotEqual(state.open, "Agent")
            send(.focused("Agent"))
            wait(1) // AppKit cannot deliver an old dismissal: the popover is application-defined.

            assertShows("Agent", "Nothing from the closed presentation after \(exit) closes the new Agent detail")
        }
    }

    func testBuilder711OldDismissalWhileClosedDoesNotEatTheNextPresentationsDismissal() {
        openFromOutside("Agent")
        send(.clicked("Agent"))
        send(.clicked("Agent"))
        assertShows("Agent")

        // The newer presentation closes through the state (Escape here; also a
        // click, the pointer leaving or focus moving), never a stale token.
        send(.escape)
        assertShows(nil, "Closing the newer presentation is not eaten by the first close")
    }

    func testBuilder711TwoLateDismissalsDoNotCloseTheThirdPresentation() {
        openFromOutside("Agent")
        for _ in 0..<2 {
            send(.clicked("Agent"))
            send(.clicked("Agent"))
        }
        wait(1)

        assertShows("Agent", "Earlier closes leave nothing behind that can close the third presentation")
    }

    func testBuilder711LateCallbackAfterTimeWindowStillBelongsToOriginalPresentation() {
        openFromOutside("Agent")
        send(.clicked("Agent"))
        send(.clicked("Agent"))
        wait(5)

        assertShows("Agent", "No timer turns an old close into a current one")
    }

    func testBuilder711DismissalBeforeClickOnDifferentRowDoesNotConsumeTheClick() {
        openFromOutside("Meetings")
        send(.focused("Agent"))
        send(.clicked("Meetings")) // Mouse-down no longer closes Agent natively; the click moves it.

        assertShows("Meetings", "Closing Agent must not eat the click intended to open Meetings")
        XCTAssertTrue(state.highlighted("Meetings"))
    }
}

extension AIUsageModelsHoverHostingTests {
    func testBuilder711FirstPollIsNotMouseMotionAfterKeyboardFocus() {
        let controllerWithoutMouseEvents = AIUsageModelsHoverController(
            mouseLocation: { NSPoint(x: 500, y: 500) },
            topWindowNumber: { _ in 0 })
        defer { controllerWithoutMouseEvents.stop() }
        controllerWithoutMouseEvents.send(.focused("Agent"))
        controllerWithoutMouseEvents.checkPointer()

        XCTAssertTrue(controllerWithoutMouseEvents.isPresented("Agent"))
        XCTAssertEqual(controllerWithoutMouseEvents.state.keyboardRow, "Agent")
    }

    func testBuilder711HalfPointPointerMotionReclaimsTheDetailFromKeyboardFocus() async throws {
        let start = try center("Meetings", x: 60)
        moveMouse(to: start)
        try await wait(AIUsageModelsHoverState.openDelay)
        controller.send(.focused("Agent"))
        try await settle()
        XCTAssertTrue(controller.isPresented("Agent"))

        moveMouse(to: NSPoint(x: start.x + 0.5, y: start.y))
        XCTAssertTrue(controller.isPresented("Meetings"),
                      "A single physical pixel on a 2x display is real movement")
    }
}
