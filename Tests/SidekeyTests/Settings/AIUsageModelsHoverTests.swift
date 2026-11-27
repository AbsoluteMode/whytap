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
    private func move(_ pointer: S.Pointer) { send(.pointer(pointer)) }
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
        send(.dismissedBySystem("Agent")); now = now.addingTimeInterval(0.05); send(.clicked("Agent"))
        assertShows(nil)
        wait(1); assertShows(nil, "it stays closed while the pointer rests on the row")
        send(.clicked("Agent")); assertShows("Agent")
    }

    func test_escape_closes_until_the_pointer_leaves_the_row() {
        openFromOutside("Agent")
        send(.escape); assertShows(nil)
        move(.outside); move(.row("Agent")); wait(S.openDelay)
        assertShows("Agent")
    }

    func test_a_late_dismissal_of_the_previous_row_does_not_close_the_new_one() {
        openFromOutside("Agent")
        move(.row("Meetings"))
        send(.dismissedBySystem("Agent"))
        assertShows("Meetings")
    }

    func test_keyboard_focus_opens_and_the_pointer_takes_over() {
        send(.focused("Agent")); assertShows("Agent")
        XCTAssertTrue(state.highlighted("Agent"))
        send(.unfocused("Agent")); send(.focused("Meetings")); assertShows("Meetings")
        move(.row("Drop Fast")); assertShows("Drop Fast")
        move(.outside); assertShows(nil)
        send(.focused("Agent")); send(.escape); assertShows(nil)
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
    private var detail: NSRect?
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
        controller = AIUsageModelsHoverController(mouseLocation: { [unowned self] in pointer },
                                                  topWindowNumber: { [unowned self] _ in window.windowNumber })
        controller.detailScreenFrameOverride = { [unowned self] in detail }
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

    private func wait(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000) + 60))
    }

    /// Exactly `title` carries the hover fill in the rendered pixels.
    private func assertFilled(_ title: String?, line: UInt = #line) throws {
        try settleSync()
        let rep = try bitmap()
        for (name, band) in zip(titles, try rowBands()) {
            let filled = ink(rep, x: 6, y: (band.lowerBound + band.upperBound) / 2) > 0.02
            XCTAssertEqual(filled, name == title, "\(name) fill", line: line)
        }
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
