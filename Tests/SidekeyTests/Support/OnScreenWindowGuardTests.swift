import AppKit
import XCTest

/// The guard itself: every way to show a window leaves the screen untouched,
/// the request is still visible to the code under test, modal UI fails the
/// test instead of stopping the run, and the check after a test is real.
@MainActor
final class OnScreenWindowGuardTests: XCTestCase {
    private typealias Guard = OnScreenWindowGuard

    private func bareWindow(title: String = "Guard fixture") -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        return window
    }

    private func ownScreenWindows() -> [Guard.ScreenWindow] {
        Guard.settledOwnScreenWindows()
    }

    func testInstalledBeforeTheFirstTestWithEveryHook() {
        XCTAssertTrue(Guard.shared.isInstalled, "SidekeyTestBootstrap must install the guard when the bundle loads")
        // A selector AppKit dropped or renamed leaves that path unguarded:
        // this list is the alarm.
        XCTAssertEqual(Guard.shared.hooks, [
            "-[NSWindow orderWindow:relativeTo:]",
            "-[NSWindow orderFrontRegardless]",
            "-[NSWindow _doOrderWindow:]",
            "-[NSWindow isVisible]",
            "-[NSApplication activateIgnoringOtherApps:]",
            "-[NSApplication activate]",
            "-[NSRunningApplication activateWithOptions:]",
            "-[NSRunningApplication activateFromApplication:options:]",
            "-[NSApplication runModalForWindow:]",
            "-[NSAlert runModal]",
            "-[NSAlert beginSheetModalForWindow:completionHandler:]",
            "-[NSSavePanel runModal]",
            "-[NSSavePanel beginWithCompletionHandler:]",
            "-[NSSavePanel beginSheetModalForWindow:completionHandler:]",
            "-[NSMenu popUpMenuPositioningItem:atLocation:inView:]",
            "+[NSMenu popUpContextMenu:withEvent:forView:]",
            "-[NSWorkspace openURL:]",
            "-[NSWorkspace openURL:configuration:completionHandler:]",
            "-[NSWorkspace openApplicationAtURL:configuration:completionHandler:]",
            "-[NSWorkspace openURLs:withApplicationAtURL:configuration:completionHandler:]"
        ])
    }

    // MARK: Windows

    func testEveryWayToShowAWindowKeepsItOffScreenAndVisibleToTheCode() {
        let ways: [(String, (NSWindow) -> Void)] = [
            ("makeKeyAndOrderFront", { $0.makeKeyAndOrderFront(nil) }),
            ("orderFront", { $0.orderFront(nil) }),
            ("orderFrontRegardless", { $0.orderFrontRegardless() }),
            ("orderBack", { $0.orderBack(nil) }),
            ("order(.above)", { $0.order(.above, relativeTo: 0) }),
            ("setIsVisible", { $0.setIsVisible(true) }),
            ("showWindow", { NSWindowController(window: $0).showWindow(nil) })
        ]
        for (name, show) in ways {
            let window = bareWindow(title: name)
            XCTAssertFalse(window.isVisible, name)
            let requests = Guard.recording { show(window) }.requests
            XCTAssertEqual(requests.map(\.kind), [.window], name)
            XCTAssertEqual(requests.first?.test, self.name, name)
            XCTAssertEqual(requests.first?.detail, "NSWindow “\(name)”", name)
            XCTAssertTrue(window.isVisible, "\(name): the code under test sees its window as shown")
            XCTAssertEqual(ownScreenWindows(), [], "\(name): nothing reached the window server")

            window.orderOut(nil)
            XCTAssertFalse(window.isVisible, "\(name): ordered out")
        }
    }

    func testShowingAVisibleWindowAgainIsOneRequestAndCloseHidesIt() {
        let window = bareWindow()
        let requests = Guard.recording {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(window.isVisible)

        window.close()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(Guard.recording { window.orderFront(nil) }.requests.count, 1, "a new show after close counts again")
        window.setIsVisible(false)
        XCTAssertFalse(window.isVisible)
    }

    func testPanelsAndBorderlessWindowsAreCoveredToo() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 30),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.orderFrontRegardless()
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(ownScreenWindows(), [])
        panel.orderOut(nil)
        XCTAssertFalse(panel.isVisible)
    }

    func testSheetDoesNotReachTheScreenAndStillEnds() {
        let parent = bareWindow(title: "Parent")
        let sheet = bareWindow(title: "Sheet")
        parent.makeKeyAndOrderFront(nil)
        var ended = false
        parent.beginSheet(sheet) { _ in ended = true }
        // AppKit attaches a sheet only to a window that is really on screen,
        // so `attachedSheet` stays nil here; the completion still runs.
        XCTAssertEqual(ownScreenWindows(), [])
        parent.endSheet(sheet)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(ended)
        XCTAssertEqual(ownScreenWindows(), [])
        parent.close()
    }

    func testOffscreenWindowStillLaysOutDrawsAndTakesFirstResponder() throws {
        let window = bareWindow()
        let field = NSTextField(string: "Drawn off screen")
        field.frame = NSRect(x: 4, y: 8, width: 72, height: 22)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(field))

        let content = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        XCTAssertEqual(bitmap.pixelsWide, Int(content.bounds.width * (window.backingScaleFactor)))
        XCTAssertEqual(ownScreenWindows(), [])
        window.close()
    }

    /// The one way to a really ordered window, and the proof that the check
    /// after a test sees this process's windows in the window server's list.
    func testWindowOrderedInBeyondEveryDisplayIsRealInvisibleAndListed() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 60, height: 30), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let result = Guard.recording { Guard.orderInBeyondEveryDisplay(window) }
        defer { window.close() }
        XCTAssertTrue(result.value)
        XCTAssertEqual(result.requests.map(\.kind), [.beyondDisplays])
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) })

        // The order-in reaches the window server with the next commit.
        CATransaction.flush()
        var listed = Guard.screenWindows(ofProcess: getpid())
        for _ in 0..<50 where listed.isEmpty {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            listed = Guard.screenWindows(ofProcess: getpid())
        }
        XCTAssertEqual(listed.map(\.number), [window.windowNumber], "the window server lists it for this process")
        XCTAssertEqual(listed.first?.alpha, 0)
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &displays, &displayCount)
        let bounds = try XCTUnwrap(listed.first?.bounds)
        XCTAssertFalse(displays.prefix(Int(displayCount)).contains { CGDisplayBounds($0).intersects(bounds) },
                       "no display shows any part of it")
        XCTAssertEqual(Guard.violations(screenWindows: listed, processIsActive: false).map(\.kind), [.onScreen],
                       "left ordered in, it would fail this test")

        window.orderOut(nil)
        XCTAssertEqual(ownScreenWindows(), [])
    }

    // MARK: Focus

    func testActivationIsRecordedAndNotPerformed() {
        let requests = Guard.recording {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.activate()
        }.requests
        XCTAssertEqual(requests.map(\.kind), [.activation, .activation])
        XCTAssertFalse(NSApplication.shared.isActive)
        XCTAssertFalse(NSRunningApplication.current.isActive)
    }

    func testAnotherAppIsNotBroughtForward() throws {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let other = try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.processIdentifier != frontmost?.processIdentifier
        }, "no second regular app is running")
        let result = Guard.recording { other.activate(options: []) }
        XCTAssertFalse(result.value)
        XCTAssertEqual(result.requests.map(\.kind), [.otherAppActivation])
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost?.processIdentifier)
    }

    // MARK: Modal UI, menus, other apps

    func testModalUIAnswersCancelledInsteadOfStoppingTheRun() {
        let alert = NSAlert()
        alert.messageText = "Guard alert"
        let alertRun = Guard.recording { alert.runModal() }
        XCTAssertEqual(alertRun.value, .abort)
        XCTAssertEqual(alertRun.requests.map(\.kind), [.modal])
        XCTAssertEqual(alertRun.requests.first?.detail, "NSAlert.runModal “Guard alert”")

        let window = bareWindow()
        XCTAssertEqual(Guard.recording { NSApplication.shared.runModal(for: window) }.value, .abort)

        var sheetAnswer: NSApplication.ModalResponse?
        let sheet = Guard.recording { alert.beginSheetModal(for: window) { sheetAnswer = $0 } }
        XCTAssertEqual(sheetAnswer, .abort)
        XCTAssertEqual(sheet.requests.map(\.kind), [.modal])

        var panelAnswer: NSApplication.ModalResponse?
        let panel = Guard.recording {
            NSOpenPanel().begin { panelAnswer = $0 }
            return NSSavePanel().runModal()
        }
        XCTAssertEqual(panelAnswer, .cancel)
        XCTAssertEqual(panel.value, .cancel)
        XCTAssertEqual(panel.requests.map(\.detail), ["NSOpenPanel.begin", "NSSavePanel.runModal"])
        XCTAssertEqual(ownScreenWindows(), [])
    }

    func testMenuPopUpDoesNotOpen() {
        let menu = NSMenu(title: "Guard menu")
        menu.addItem(withTitle: "Item", action: nil, keyEquivalent: "")
        let result = Guard.recording { menu.popUp(positioning: nil, at: .zero, in: nil) }
        XCTAssertFalse(result.value)
        XCTAssertEqual(result.requests, [Guard.Record(test: name, kind: .menu, detail: "NSMenu.popUp “Guard menu”", expected: true)])
    }

    func testWorkspaceOpensNothingAndLogsNoPath() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/private/path?token=secret"))
        let result = Guard.recording { NSWorkspace.shared.open(url) }
        XCTAssertFalse(result.value)
        XCTAssertEqual(result.requests.map(\.detail), ["https://example.invalid"])

        let answered = expectation(description: "completion")
        let configured = Guard.recording {
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                XCTAssertNil(app); XCTAssertNotNil(error)
                answered.fulfill()
            }
        }
        wait(for: [answered], timeout: 1)
        XCTAssertEqual(configured.requests.map(\.kind), [.workspaceOpen])
    }

    func testAModalRequestOutsideRecordingFailsTheTest() {
        XCTExpectFailure("an unexpected alert fails its test", strict: true)
        let alert = NSAlert()
        alert.messageText = "Unexpected"
        _ = alert.runModal()
        Guard.shared.markLatestRequestExpected()
    }

    // MARK: The check after a test

    func testWindowServerListIsReadForAProcessThatHasWindows() throws {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let owner = try XCTUnwrap(list.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
            .first { $0 != getpid() }, "the window server lists no window (no GUI session?)")
        let windows = Guard.screenWindows(ofProcess: owner)
        XCTAssertFalse(windows.isEmpty, "the reader finds the windows the window server lists for pid \(owner)")
        XCTAssertTrue(windows.allSatisfy { $0.number != 0 })
        XCTAssertEqual(ownScreenWindows(), [], "this test process has nothing on screen")
    }

    func testWindowFoundOnScreenOrAnActiveProcessIsAViolation() {
        XCTAssertTrue(Guard.violations(screenWindows: [], processIsActive: false).isEmpty)
        let entry: [String: Any] = [
            kCGWindowOwnerPID as String: 42, kCGWindowNumber as String: 7, kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1.0,
            kCGWindowBounds as String: ["X": 10, "Y": 20, "Width": 900, "Height": 600]
        ]
        let other: [String: Any] = [kCGWindowOwnerPID as String: 43, kCGWindowNumber as String: 8]
        let windows = Guard.screenWindows(in: [entry, other], ofProcess: 42)
        XCTAssertEqual(windows, [Guard.ScreenWindow(number: 7, layer: 0, bounds: CGRect(x: 10, y: 20, width: 900, height: 600), alpha: 1)])
        let found = Guard.violations(screenWindows: windows, processIsActive: true)
        XCTAssertEqual(found.map(\.kind), [.onScreen, .active])
        XCTAssertEqual(found.first?.detail, "window 7, layer 0, 900×600, alpha 1.0")
        XCTAssertTrue(found.allSatisfy(\.kind.fails))
        XCTAssertTrue(Guard.failureText(.onScreen, detail: "window 7").contains("OnScreenWindowGuard"))
    }

    func testSummaryCountsWindowsAndListsOnlyFailingRequests() {
        typealias Record = Guard.Record
        XCTAssertEqual(Guard.summary([]),
                       "OnScreenWindowGuard: 0 window(s) kept off screen in 0 test(s), 0 ordered in beyond every display at zero opacity, 0 activation(s) not performed, 0 failing request(s) (modal UI, menu, open, window on screen).")
        let records = [
            Record(test: "-[A testOne]", kind: .window, detail: "NSWindow “Settings”"),
            Record(test: "-[A testOne]", kind: .window, detail: "NSWindow “Settings”"),
            Record(test: "-[A testOne]", kind: .activation, detail: "NSApp.activate()"),
            Record(test: "-[B testTwo]", kind: .window, detail: "NSPanel"),
            Record(test: "-[B testTwo]", kind: .modal, detail: "NSAlert.runModal “Delete?”"),
            Record(test: "-[C testThree]", kind: .menu, detail: "NSMenu.popUp “Checked”", expected: true)
        ]
        let summary = Guard.summary(records)
        XCTAssertTrue(summary.hasPrefix("OnScreenWindowGuard: 3 window(s) kept off screen in 2 test(s), 0 ordered in beyond every display at zero opacity, 1 activation(s) not performed, 1 failing request(s)"))
        XCTAssertFalse(summary.contains("Checked"), "a request a test recorded on purpose is not a failure")
        XCTAssertTrue(summary.contains("  [modal UI] -[B testTwo]: NSAlert.runModal “Delete?”"))
        XCTAssertFalse(summary.contains("NSPanel"))
        let report = Guard.report(records)
        XCTAssertTrue(report.contains("  -[A testOne]: window kept off screen; NSWindow “Settings” ×2"))
        XCTAssertTrue(report.contains("  -[B testTwo]: window kept off screen; NSPanel ×1"))
        XCTAssertTrue(report.contains("  -[B testTwo]: modal UI (FAILED THE TEST); NSAlert.runModal “Delete?” ×1"))
        XCTAssertTrue(report.contains("  -[C testThree]: menu pop-up; NSMenu.popUp “Checked” ×1"))
    }
}
