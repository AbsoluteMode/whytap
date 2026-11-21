import AppKit
import XCTest
@testable import Sidekey

/// Shot's hover help: AppKit tool tips never appear in the inactive,
/// screen-saver-level editor, so every control's help goes through
/// ScreenshotHoverHint. Windows stay far offscreen and never become key.
@MainActor
final class ScreenshotHoverHintTests: XCTestCase {
    private var cleanups: [() -> Void] = []
    override func tearDown() async throws {
        await MainActor.run { cleanups.reversed().forEach { $0() }; cleanups.removeAll() }
        try await super.tearDown()
    }

    private func makeToolbar() throws -> ScreenshotToolbar {
        _ = NSApplication.shared
        let suite = "ScreenshotHoverHintTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let image = try XCTUnwrap(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let canvas = ScreenshotCanvas(image: image, size: CGSize(width: 400, height: 200))
        canvas.selection = CGRect(x: 40, y: 40, width: 200, height: 100)
        let toolbar = ScreenshotToolbar(canvas: canvas, defaults: defaults)
        cleanups.append { _ = canvas; defaults.removePersistentDomain(forName: suite) }
        return toolbar
    }

    private func offscreenPanel(_ view: NSView, size: CGSize) -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = view
        cleanups.append { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        return panel
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testEveryToolbarButtonHasShortHelpWithItsShortcut() throws {
        let toolbar = try makeToolbar()
        let buttons = descendants(toolbar).compactMap { $0 as? ScreenshotToolbarButton }
        XCTAssertEqual(buttons.count, 17)
        for button in buttons {
            let help = try XCTUnwrap(button.toolTip, button.identifier?.rawValue ?? button.title)
            XCTAssertFalse(help.isEmpty)
            XCTAssertLessThanOrEqual(help.count, 110, help)
            XCTAssertEqual(button.accessibilityHelp(), help)
        }
        func help(_ id: String) -> String? { buttons.first { $0.identifier?.rawValue == id }?.toolTip }
        XCTAssertEqual(help("command.copyText"),
                       "Copy text — recognize the text in the selection, copy it and close (OCR on this Mac)")
        XCTAssertEqual(help("arrow"), "Arrow · A — draw an arrow pointing to a detail")
        XCTAssertEqual(help("blur"), "Blur · B — blur text and numbers or a whole area")
        XCTAssertEqual(help("command.share"), "Share — send the screenshot with macOS sharing")
        let texts = buttons.compactMap(\.toolTip)
        for expected in ["Undo · ⌘Z", "Redo · ⇧⌘Z", "Download to Downloads · ⌘S", "Copy & exit · Return / ⌘C", "Cancel capture · Esc",
                         "↑ key: Blur", "← key: Rectangle", "→ key: Pen", "↓ key: Text"] {
            XCTAssertTrue(texts.contains { $0.hasPrefix(expected) }, expected)
        }
    }

    func testSettingsControlsUseHoverHelpInsteadOfAppKitToolTips() throws {
        let toolbar = try makeToolbar()
        let controls = descendants(toolbar.toolSettings).compactMap { $0 as? NSControl }
            .filter { $0 is NSColorWell || $0 is NSPopUpButton }
        XCTAssertEqual(controls.count, 4, "Color, width, shape and blur mode")
        for control in controls {
            XCTAssertNil(control.toolTip, "AppKit tool tips do not appear in the editor")
            XCTAssertFalse((control.accessibilityHelp() ?? "").isEmpty, "\(type(of: control)) \(String(describing: control.accessibilityHelp())) cell \(String(describing: control.cell?.accessibilityHelp()))")
        }
    }

    func testHintSitsBelowTheControlFlipsAboveAndStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 22)
        XCTAssertEqual(ScreenshotHoverHint.frame(anchor: CGRect(x: 400, y: 400, width: 30, height: 30), size: size, screen: screen),
                       CGRect(x: 315, y: 372, width: 200, height: 22))
        XCTAssertEqual(ScreenshotHoverHint.frame(anchor: CGRect(x: 400, y: 10, width: 30, height: 30), size: size, screen: screen).minY, 46)
        XCTAssertEqual(ScreenshotHoverHint.frame(anchor: CGRect(x: 0, y: 400, width: 30, height: 30), size: size, screen: screen).minX, 4)
        XCTAssertEqual(ScreenshotHoverHint.frame(anchor: CGRect(x: 990, y: 400, width: 10, height: 30), size: size, screen: screen).maxX, 996)
    }

    func testHoverShowsAfterDelayMovesAtOnceAndHidesOnLeaveAndClose() async throws {
        let toolbar = try makeToolbar()
        // Room below the toolbar, as on a real display; an offscreen window has no screen.
        let size = toolbar.fittingSize, container = NSView(frame: CGRect(x: 0, y: 0, width: size.width + 200, height: size.height + 120))
        toolbar.frame = CGRect(x: 100, y: 120, width: size.width, height: size.height); container.addSubview(toolbar)
        let window = offscreenPanel(container, size: container.frame.size)
        window.orderFrontRegardless(); toolbar.layoutSubtreeIfNeeded()
        let buttons = descendants(toolbar).compactMap { $0 as? ScreenshotToolbarButton }
        let copyText = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "command.copyText" })
        let share = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "command.share" })
        let hint = ScreenshotHoverHint()
        cleanups.append { hint.hide(); hint.panel?.close() }

        hint.hover(copyText, text: copyText.toolTip)
        XCTAssertNil(hint.visibleText, "The first hint waits like an AppKit tool tip")
        try await Task.sleep(nanoseconds: UInt64((ScreenshotHoverHint.delay + 0.25) * 1_000_000_000))
        XCTAssertEqual(hint.visibleText, copyText.toolTip)
        let panel = try XCTUnwrap(hint.panel)
        XCTAssertTrue(panel.isVisible); XCTAssertTrue(panel.ignoresMouseEvents); XCTAssertFalse(panel.canBecomeKey)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.screenSaver.rawValue, "Above Shot's own panels")
        let anchor = window.convertToScreen(copyText.convert(copyText.bounds, to: nil))
        XCTAssertEqual(panel.frame, ScreenshotHoverHint.frame(anchor: anchor, size: panel.frame.size, screen: window.screen?.frame ?? window.frame))
        XCTAssertFalse(panel.frame.intersects(anchor), "Never covers the button")

        hint.leave(share)
        XCTAssertEqual(hint.visibleText, copyText.toolTip, "Leaving another control keeps this hint")
        hint.leave(copyText)
        XCTAssertNil(hint.visibleText); XCTAssertFalse(panel.isVisible)
        hint.hover(share, text: share.toolTip)
        XCTAssertEqual(hint.visibleText, share.toolTip, "The next control's hint appears at once")

        window.orderOut(nil)
        hint.hover(copyText, text: copyText.toolTip)
        XCTAssertNil(hint.visibleText, "A hidden editor never shows a hint")
        hint.hide(); XCTAssertFalse(panel.isVisible)
    }

    /// Offscreen review images for the maintainer; never shown on screen.
    /// The editor's materials draw only in a live window, so the toolbar and the
    /// hint get flat stand-in backgrounds here.
    func testRenderCopyTextHint() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_SHOT_HINT_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_SHOT_HINT_RENDER_DIR to save offscreen review images")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for id in ["command.copyText", "blur", "command.share", "arrow.up"] {
                let toolbar = try makeToolbar()
                let window = offscreenPanel(toolbar, size: toolbar.fittingSize)
                window.appearance = NSAppearance(named: appearance)
                window.setContentSize(toolbar.fittingSize); toolbar.layoutSubtreeIfNeeded()
                let buttons = descendants(toolbar).compactMap { $0 as? ScreenshotToolbarButton }
                let button = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == id }
                                           ?? buttons.first { id == "arrow.up" && $0.toolTip?.hasPrefix("↑") == true }, id)
                let hint = ScreenshotHoverHint()
                cleanups.append { hint.panel?.close() }
                let (panel, hintSize) = hint.prepare(try XCTUnwrap(button.toolTip))
                panel.appearance = NSAppearance(named: appearance)
                panel.setContentSize(hintSize); panel.contentView?.layoutSubtreeIfNeeded()

                let toolbarSize = toolbar.bounds.size, margin: CGFloat = 24
                let canvasSize = CGSize(width: max(toolbarSize.width, hintSize.width) + margin * 2,
                                        height: toolbarSize.height + hintSize.height + 6 + margin * 2)
                let toolbarOrigin = CGPoint(x: margin, y: canvasSize.height - margin - toolbarSize.height)
                let buttonRect = button.convert(button.bounds, to: toolbar).offsetBy(dx: toolbarOrigin.x, dy: toolbarOrigin.y)
                let hintFrame = ScreenshotHoverHint.frame(anchor: buttonRect, size: hintSize, screen: CGRect(origin: .zero, size: canvasSize))

                let image = NSImage(size: canvasSize)
                image.lockFocus()
                let dark = name == "dark"
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                    (dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.86, alpha: 1)).setFill()
                    CGRect(origin: .zero, size: canvasSize).fill()
                    (dark ? NSColor(white: 0.26, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
                    NSBezierPath(roundedRect: CGRect(origin: toolbarOrigin, size: toolbarSize), xRadius: 13, yRadius: 13).fill()
                    (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 1, alpha: 1)).setFill()
                    NSBezierPath(roundedRect: hintFrame, xRadius: 6, yRadius: 6).fill()
                    NSColor.separatorColor.setStroke()
                    NSBezierPath(roundedRect: hintFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()
                }
                image.unlockFocus()
                func draw(_ view: NSView, at origin: CGPoint, radius: CGFloat) throws {
                    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let rect = CGRect(origin: origin, size: view.bounds.size)
                    image.lockFocus()
                    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
                    rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    image.unlockFocus()
                }
                try draw(toolbar, at: toolbarOrigin, radius: 13)
                try draw(try XCTUnwrap(panel.contentView), at: hintFrame.origin, radius: 6)
                let tiff = try XCTUnwrap(image.tiffRepresentation)
                let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                let file = "shot-hint-\(id.replacingOccurrences(of: "command.", with: ""))-\(name).png"
                try png.write(to: directory.appendingPathComponent(file))
            }
        }
    }
}
