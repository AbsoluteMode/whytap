import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class ScreenshotArrowToolbarTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        super.tearDown()
    }
    private func fixture() throws -> (ScreenshotCanvas, ScreenshotToolbar, HotkeyPreferences, UserDefaults) {
        _ = NSApplication.shared
        let suite = "ScreenshotArrowToolbar.\(UUID().uuidString)"; suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), prefs = HotkeyPreferences(defaults: defaults)
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let canvas = ScreenshotCanvas(image: try XCTUnwrap(context.makeImage()), size: CGSize(width: 400, height: 300),
                                      arrowBindings: { prefs.screenshotArrowBindings })
        canvas.selection = canvas.bounds
        return (canvas, ScreenshotToolbar(canvas: canvas, defaults: defaults, arrowPreferences: prefs), prefs, defaults)
    }

    func testFourAssignmentButtonsEachContainTheirOwnArrowKeycapAndHitArea() throws {
        let (_, toolbar, _, _) = try fixture()
        toolbar.arrowCluster.layoutSubtreeIfNeeded()
        let buttons = toolbar.arrowCluster.buttons
        XCTAssertEqual(buttons.count, 4)
        let up = try XCTUnwrap(buttons[.up]), down = try XCTUnwrap(buttons[.down])
        let left = try XCTUnwrap(buttons[.left]), right = try XCTUnwrap(buttons[.right])
        let ordered = [up, left, right, down]
        let frames = ordered.map { $0.convert($0.bounds, to: toolbar.arrowCluster) }
        for index in 1..<frames.count { XCTAssertGreaterThanOrEqual(frames[index].minX - frames[index - 1].maxX, 11) }
        XCTAssertTrue(frames.allSatisfy { $0.midY == frames[0].midY })
        XCTAssertTrue(buttons.values.allSatisfy { $0.isDescendant(of: toolbar) && toolbar.focusableControls.contains($0) })
        for (direction, button) in buttons {
            XCTAssertEqual(button.assignmentArrow, direction)
            XCTAssertEqual(button.dragAction, ScreenshotArrowBindings.defaults[direction])
            XCTAssertEqual(button.menu?.items.filter { !$0.isSeparatorItem && $0.state == .on }.count, 1)
            XCTAssertTrue(button.toolTip?.contains("Changes save immediately") == true)
            let hint = try XCTUnwrap(button.subviews.first { $0.identifier?.rawValue == "screenshot.arrow-keycap.\(direction.rawValue)" })
            XCTAssertTrue(button.bounds.contains(hint.frame))
            XCTAssertFalse(hint.acceptsFirstResponder)
            XCTAssertNil(hint.hitTest(CGPoint(x: hint.frame.midX, y: hint.frame.midY)))
            for point in [CGPoint(x: 15, y: 15), CGPoint(x: hint.frame.midX, y: hint.frame.midY)] {
                XCTAssertTrue(toolbar.arrowCluster.hitTest(button.convert(point, to: toolbar.arrowCluster)) === button,
                              "The icon and keycap must share one assignment click/drop target")
            }
        }
    }

    func testOnlyOldStockDefaultsMigrateAndCustomOrLaterAssignmentsSurvive() throws {
        let (_, _, _, defaults) = try fixture()
        let oldStock = ["up": "pen", "down": "blur", "left": "undo", "right": "copy"]
        defaults.removeObject(forKey: HotkeyPreferences.screenshotArrowDefaultsVersionKey)
        defaults.set(oldStock, forKey: HotkeyPreferences.screenshotArrowsDefaultsKey)
        XCTAssertEqual(HotkeyPreferences(defaults: defaults).screenshotArrowBindings, .defaults)
        defaults.set(oldStock, forKey: HotkeyPreferences.screenshotArrowsDefaultsKey)
        XCTAssertEqual(HotkeyPreferences(defaults: defaults).screenshotArrowBindings.saved, oldStock,
                       "The one-time migration must not undo a later deliberate assignment")
        defaults.removeObject(forKey: HotkeyPreferences.screenshotArrowDefaultsVersionKey)
        var custom = oldStock; custom["up"] = "text"
        defaults.set(custom, forKey: HotkeyPreferences.screenshotArrowsDefaultsKey)
        XCTAssertEqual(HotkeyPreferences(defaults: defaults).screenshotArrowBindings.saved, custom)
    }

    func testToolbarDragCopiesActionIntoOnlyTargetAndImmediatelyChangesKeyboardBehavior() throws {
        let (canvas, toolbar, prefs, defaults) = try fixture()
        let pasteboard = NSPasteboard(name: .init("ScreenshotArrowToolbar.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        prefs.screenshotArrowBindings[.right] = .copy
        let up = try XCTUnwrap(toolbar.arrowCluster.buttons[.up])
        let right = try XCTUnwrap(toolbar.arrowCluster.buttons[.right])
        let sourceAction = try XCTUnwrap(right.dragAction)
        pasteboard.setString(sourceAction.dragPayload, forType: ScreenshotToolbarButton.actionPasteboardType)
        XCTAssertTrue(up.acceptAssignment(from: pasteboard))
        XCTAssertEqual(prefs.screenshotArrowBindings[.up], .copy)
        XCTAssertEqual(prefs.screenshotArrowBindings[.right], .copy, "Replacing the destination never clears or swaps the source")
        XCTAssertEqual(prefs.screenshotArrowBindings[.left], .rectangle)
        XCTAssertEqual(up.dragAction, .copy, "The source icon and payload update synchronously")
        XCTAssertEqual(HotkeyPreferences(defaults: defaults).screenshotArrowBindings[.up], .copy)
        var copies = 0
        canvas.onCommand = { if $0 == .copy { copies += 1 } }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: ScreenshotArrow.up.keyCode))
        canvas.keyDown(with: event)
        XCTAssertEqual(copies, 1)
        pasteboard.clearContents(); pasteboard.setString("untrusted external text", forType: ScreenshotToolbarButton.actionPasteboardType)
        XCTAssertFalse(up.acceptAssignment(from: pasteboard))
        XCTAssertEqual(prefs.screenshotArrowBindings[.up], .copy)
    }

    func testAssignmentMenuPersistsEveryActionAndResetWithoutExportingOrEditingScreenshot() throws {
        let (canvas, toolbar, prefs, _) = try fixture()
        let button = try XCTUnwrap(toolbar.arrowCluster.buttons[.up])
        var commands = 0
        canvas.onCommand = { _ in commands += 1 }
        for action in ScreenshotEditorAction.allCases {
            let item = try XCTUnwrap(button.menu?.items.first { $0.title == action.title })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(prefs.screenshotArrowBindings[.up], action)
        }
        let reset = try XCTUnwrap(button.menu?.items.last)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(reset.action), to: reset.target, from: reset))
        XCTAssertEqual(prefs.screenshotArrowBindings[.up], .blur)
        XCTAssertEqual(commands, 0, "Choosing a binding must never invoke Copy, Download or Cancel")
        XCTAssertTrue(canvas.annotations.isEmpty)
    }

    func testBusyDisablesAssignmentDropMenuAndFocusAndRestoresAfterProcessing() throws {
        let (canvas, toolbar, prefs, _) = try fixture()
        let button = try XCTUnwrap(toolbar.arrowCluster.buttons[.up])
        let menuItem = try XCTUnwrap(button.menu?.items.first { $0.title == "Share" })
        let pasteboard = NSPasteboard(name: .init("ScreenshotArrowToolbar.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(ScreenshotEditorAction.share.dragPayload, forType: ScreenshotToolbarButton.actionPasteboardType)
        canvas.busy = true; toolbar.refresh()
        XCTAssertTrue(toolbar.arrowCluster.buttons.values.allSatisfy { !$0.isEnabled })
        XCTAssertFalse(toolbar.focusableControls.contains(button))
        XCTAssertFalse(button.acceptAssignment(from: pasteboard))
        _ = NSApp.sendAction(try XCTUnwrap(menuItem.action), to: menuItem.target, from: menuItem)
        XCTAssertEqual(prefs.screenshotArrowBindings[.up], .blur)
        canvas.busy = false; toolbar.refresh()
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.acceptAssignment(from: pasteboard))
        XCTAssertEqual(prefs.screenshotArrowBindings[.up], .share)
    }

    func testEveryVisibleToolbarActionHasDragPayload() throws {
        let (_, toolbar, _, _) = try fixture()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let actions = descendants(toolbar).compactMap { ($0 as? ScreenshotToolbarButton)?.dragAction }
        for action: ScreenshotEditorAction in [.pen, .blur, .arrow, .rectangle, .text, .counter, .copy, .copyText, .share, .download, .cancel, .undo, .redo] {
            XCTAssertTrue(actions.contains(action), "Missing drag source: \(action.title)")
        }
    }

    func testEscapeWhileHoldingCopyCancelsBeforeQueuedMouseUpAndDisabledPressCannotClick() throws {
        let (canvas, toolbar, _, _) = try fixture()
        let window = ScreenshotCapturePanel(contentRect: CGRect(x: -20_000, y: -20_000, width: 800, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = toolbar; window.keyboardCanvas = canvas
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let copy = try XCTUnwrap(descendants(toolbar).compactMap { $0 as? ScreenshotToolbarButton }.first { $0.dragAction == .copy && $0.assignmentArrow == nil })
        toolbar.layoutSubtreeIfNeeded()
        let point = copy.convert(CGPoint(x: copy.bounds.midX, y: copy.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        let up = try mouse(.leftMouseUp), down = try mouse(.leftMouseDown)
        var commands: [ScreenshotCommand] = []
        canvas.onCommand = { commands.append($0) }; toolbar.onCommand = { commands.append($0) }
        var pending = [escape, up]
        copy.trackMousePress(down, in: window, dragAction: .copy, nextEvent: { pending.isEmpty ? nil : pending.removeFirst() }, canContinue: { true })
        XCTAssertEqual(commands, [.cancel]); XCTAssertEqual(pending.count, 1)
        XCTAssertFalse(copy.isHighlighted)
        commands = []
        copy.trackMousePress(down, in: window, dragAction: .copy, nextEvent: { up }, canContinue: { false })
        XCTAssertTrue(commands.isEmpty, "A disabled or hidden source cannot perform its pending click")
        var released = false
        copy.trackMousePress(down, in: window, dragAction: .copy, nextEvent: {
            if released { return nil }; released = true; return up
        }, canContinue: { true })
        XCTAssertEqual(commands, [.copy], "A normal click still invokes the toolbar action exactly once")
        XCTAssertFalse(window.isVisible)
    }

    func testRenderActualScreenshotToolbarWithGroupedShortcutButtons() throws {
        guard let directory = ProcessInfo.processInfo.environment["WHYTAP_SCREENSHOT_ARROW_RENDER_DIR"] else {
            throw XCTSkip("Opt-in native toolbar renders")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for width in [320, 390, 768, 1024, 1440] {
            for dark in [false, true] {
                let (canvas, toolbar, _, _) = try fixture()
                canvas.commit(ScreenshotAnnotation(tool: .pen, points: [.zero, CGPoint(x: 50, y: 50)]))
                toolbar.refresh(); toolbar.configure(availableWidth: CGFloat(width))
                let size = toolbar.fittingSize
                let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                    styleMask: [.borderless], backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = toolbar
                defer { window.contentView = nil; window.close() }
                toolbar.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
                toolbar.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(toolbar.bounds.width, CGFloat(width))
                for button in toolbar.arrowCluster.buttons.values {
                    XCTAssertTrue(toolbar.bounds.contains(button.convert(button.bounds, to: toolbar)))
                }
                func render(_ suffix: String = "") throws -> Data {
                    let bitmap = try XCTUnwrap(toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds))
                    toolbar.cacheDisplay(in: toolbar.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("toolbar-arrows-\(width)-\(dark ? "dark" : "light")\(suffix).png"))
                    return data
                }
                let idle = try render()
                if width == 390 {
                    let button = try XCTUnwrap(toolbar.arrowCluster.buttons[.up])
                    let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
                    button.mouseEntered(with: event)
                    let hovered = try render("-hover")
                    XCTAssertNotEqual(hovered, idle)
                    button.highlight(true)
                    XCTAssertNotEqual(try render("-pressed"), hovered)
                    button.highlight(false)
                    canvas.busy = true; toolbar.refresh()
                    let disabled = try render("-disabled")
                    button.mouseExited(with: event)
                    XCTAssertEqual(try render("-disabled-exit"), disabled, "Disabled shortcut pairs suppress hover")
                }
                XCTAssertFalse(window.isVisible)
            }
        }
    }
}
