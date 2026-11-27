import AppKit
import XCTest

/// The guard itself: every path is silent, recorded with the test, and only a
/// key the app's own window would beep for counts as unexpected.
@MainActor
final class SystemSoundGuardTests: XCTestCase {
    private func keyDown(in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "x",
            charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
    }

    private func bareWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func testInstalledBeforeTheFirstTest() {
        XCTAssertTrue(SystemSoundGuard.shared.isInstalled,
                      "SidekeyTestBootstrap must install the guard when the bundle loads")
    }

    func testKeyNobodyTakesIsRecordedWithThisTest() throws {
        let window = bareWindow()
        let event = try keyDown(in: window)
        let sounds = SystemSoundGuard.expectingSound { window.sendEvent(event) }.sounds
        XCTAssertEqual(sounds.map(\.kind), [.unhandledKey])
        XCTAssertEqual(sounds.first?.test, name)
        XCTAssertEqual(sounds.first?.expected, true)
        XCTAssertTrue(sounds.first?.detail.contains("NSWindow") == true)
    }

    func testHandledKeyAsksForNoSound() throws {
        final class Taker: NSView {
            var taken = 0
            override var acceptsFirstResponder: Bool { true }
            override func keyDown(with event: NSEvent) { taken += 1 }
        }
        let window = bareWindow()
        let taker = Taker(frame: window.contentLayoutRect)
        window.contentView = taker
        window.makeFirstResponder(taker)
        let event = try keyDown(in: window)
        let sounds = SystemSoundGuard.expectingSound { window.sendEvent(event) }.sounds
        XCTAssertEqual(taker.taken, 1)
        XCTAssertEqual(sounds, [])
    }

    func testKeySentToTheAppWithoutKeyWindowIsAnArtifact() throws {
        // `NSApp` is nil until something creates the application; run alone
        // (`--filter`, a shard) this test is the first to need it.
        let app = NSApplication.shared
        try XCTSkipIf(app.keyWindow != nil, "the test process has a key window")
        let window = bareWindow()
        var seenByLaterMonitor = 0
        let monitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            seenByLaterMonitor += 1
            return event
        })
        defer { NSEvent.removeMonitor(monitor) }
        let before = SystemSoundGuard.shared.allRecords.count
        app.sendEvent(try keyDown(in: window))
        let sounds = Array(SystemSoundGuard.shared.allRecords[before...])
        XCTAssertEqual(seenByLaterMonitor, 1, "monitors of the code under test still see the key")
        XCTAssertEqual(sounds.map(\.kind), [.noKeyWindow])
        XCTAssertEqual(sounds.first?.expected, true, "never fails a test: the app gets no keys without a key window")
    }

    func testSoundFileIsRecordedNotPlayed() throws {
        let sound = try XCTUnwrap(NSSound(contentsOfFile: "/System/Library/Sounds/Pop.aiff", byReference: true))
        let result = SystemSoundGuard.expectingSound { sound.play() }
        XCTAssertTrue(result.value, "callers see a started sound")
        XCTAssertFalse(sound.isPlaying)
        XCTAssertEqual(result.sounds.map(\.kind), [.soundFile])
    }

    func testReportNamesTestsAndCountsRepeats() {
        typealias Record = SystemSoundGuard.Record
        XCTAssertEqual(SystemSoundGuard.report([]), "SystemSoundGuard: no test asked for a sound.")
        let report = SystemSoundGuard.report([
            Record(test: "-[A testOne]", kind: .unhandledKey, detail: "end of chain: NSWindow", expected: false),
            Record(test: "-[A testOne]", kind: .unhandledKey, detail: "end of chain: NSWindow", expected: false),
            Record(test: "-[A testOne]", kind: .unhandledKey, detail: "end of chain: NSWindow", expected: true),
            Record(test: "-[B testTwo]", kind: .noKeyWindow, detail: "key code 49", expected: true)
        ])
        XCTAssertTrue(report.hasPrefix("SystemSoundGuard: 4 sound(s) kept silent, 2 unexpected."))
        XCTAssertTrue(report.contains("[UNEXPECTED] -[A testOne] ×2"))
        XCTAssertTrue(report.contains("[expected] -[A testOne] ×1"))
        XCTAssertTrue(report.contains("[artifact] -[B testTwo] ×1"))
    }
}
