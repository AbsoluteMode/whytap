import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class ScreenshotInlineTextTests: XCTestCase {
    private func withCanvas(size: CGSize = CGSize(width: 800, height: 400), _ body: (ScreenshotCanvas, ScreenshotCapturePanel) throws -> Void) throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(origin: .zero, size: size))
        let canvas = ScreenshotCanvas(image: try XCTUnwrap(context.makeImage()), size: size)
        canvas.selection = CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10)
        let panel = ScreenshotCapturePanel(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false; panel.keyboardCanvas = canvas; panel.contentView = canvas
        defer { panel.contentView = nil; panel.close() }
        try body(canvas, panel)
        XCTAssertFalse(panel.isVisible, "Fixtures must never present another app window")
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, panel: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    private func click(_ canvas: ScreenshotCanvas, at point: CGPoint, panel: NSWindow) throws {
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: point, panel: panel))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: point, panel: panel))
    }
    private func key(_ code: UInt16, panel: NSWindow, modifiers: NSEvent.ModifierFlags = [], characters: String = "") throws -> NSEvent {
        let value = characters.isEmpty ? [UInt16(123): "\u{f702}", 124: "\u{f703}", 125: "\u{f701}", 126: "\u{f700}"][code] ?? characters : characters
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value,
            isARepeat: false, keyCode: code))
    }
    private func type(_ value: String, canvas: ScreenshotCanvas) throws {
        let editor = try XCTUnwrap(canvas.textEditor)
        editor.insertText(value, replacementRange: editor.selectedRange())
    }

    func testClickTypeAtTwoPositionsAndReturnIncludesLiveText() throws {
        try withCanvas { canvas, panel in
            canvas.selectTool(.text)
            try click(canvas, at: CGPoint(x: 130, y: 280), panel: panel)
            XCTAssertTrue(panel.firstResponder === canvas.textEditor)
            XCTAssertFalse(canvas.canUndo, "An empty insertion is not an edit yet")
            try type("К архивации", canvas: canvas)
            XCTAssertEqual(canvas.annotations.first?.text, "К архивации")
            XCTAssertEqual(try XCTUnwrap(canvas.annotations.first?.points.first).x, 130)
            try click(canvas, at: CGPoint(x: 420, y: 120), panel: panel)
            try type("Second label", canvas: canvas)
            var exported: [String] = []
            canvas.onCommand = { if $0 == .copy { exported = canvas.annotations.map(\.text) } }
            panel.sendEvent(try key(36, panel: panel, characters: "\r"))
            XCTAssertEqual(exported, ["К архивации", "Second label"])
            XCTAssertNil(canvas.textEditor)
            canvas.undo(); XCTAssertEqual(canvas.annotations.map(\.text), ["К архивации"])
            canvas.redo(); XCTAssertEqual(canvas.annotations.map(\.text), ["К архивации", "Second label"])
        }
    }

    func testNativeCaretSelectionPasteArrowAndUndoStayInsideLabel() throws {
        try withCanvas { canvas, panel in
            let crop = canvas.selection
            canvas.selectTool(.text); try click(canvas, at: CGPoint(x: 130, y: 280), panel: panel)
            let editor = try XCTUnwrap(canvas.textEditor)
            // Unshown fixtures do not run a native event loop between synthetic keystrokes.
            let undoManager = try XCTUnwrap(editor.undoManager)
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
            try type("Hello world", canvas: canvas)
            editor.breakUndoCoalescing(); undoManager.endUndoGrouping()
            undoManager.beginUndoGrouping()
            editor.setSelectedRange(NSRange(location: 6, length: 5))
            try type("мир", canvas: canvas)
            editor.breakUndoCoalescing(); undoManager.endUndoGrouping()
            XCTAssertEqual(canvas.annotations.first?.text, "Hello мир")
            panel.sendEvent(try key(123, panel: panel))
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 8, length: 0))
            XCTAssertEqual(canvas.tool, .text, "Bare arrows must not activate toolbar assignments while typing")
            XCTAssertEqual(canvas.selection, crop)
            XCTAssertTrue(NSApp.sendAction(#selector(ScreenshotInlineTextView.undoText(_:)), to: editor, from: nil))
            XCTAssertEqual(editor.string, "Hello world")
            XCTAssertEqual(canvas.annotations.first?.text, "Hello world", "Native text undo must run without removing the annotation")
            XCTAssertTrue(NSApp.sendAction(#selector(ScreenshotInlineTextView.redoText(_:)), to: editor, from: nil))
            XCTAssertEqual(canvas.annotations.first?.text, "Hello мир")
            XCTAssertEqual(canvas.annotations.count, 1)
            canvas.finishTextEditing()
            let annotation = try XCTUnwrap(canvas.annotations.first)
            canvas.selectTool(.select)
            try click(canvas, at: CGPoint(x: annotation.points[0].x + 3, y: annotation.points[0].y + 5), panel: panel)
            XCTAssertNotNil(canvas.textEditor, "Existing text is edited instead of dragged by its content")
            XCTAssertEqual(canvas.annotations.count, 1)
        }
    }

    func testEscapeRestoresExistingTextAndEmptyInsertionDoesNotConsumeRedo() throws {
        try withCanvas { canvas, panel in
            canvas.selectTool(.text); try click(canvas, at: CGPoint(x: 130, y: 280), panel: panel)
            try type("Original", canvas: canvas); canvas.finishTextEditing()
            let original = try XCTUnwrap(canvas.annotations.first)
            canvas.undo(); XCTAssertTrue(canvas.canRedo)
            try click(canvas, at: CGPoint(x: 300, y: 180), panel: panel)
            canvas.finishTextEditing(); XCTAssertTrue(canvas.canRedo)
            canvas.redo()
            try click(canvas, at: CGPoint(x: 135, y: original.points[0].y + 5), panel: panel)
            try type(" changed", canvas: canvas)
            panel.sendEvent(try key(53, panel: panel))
            XCTAssertNil(canvas.textEditor); XCTAssertEqual(canvas.annotations.first?.text, "Original")
            XCTAssertEqual(canvas.annotations.first?.points, original.points)
            canvas.undo(); XCTAssertTrue(canvas.annotations.isEmpty)
        }
    }

    func testHoverHandleDragKeyboardMovementAndExportExcludeChrome() throws {
        try withCanvas { canvas, panel in
            canvas.selectTool(.text); try click(canvas, at: CGPoint(x: 130, y: 280), panel: panel)
            try type("Drag me", canvas: canvas); canvas.finishTextEditing(); canvas.selectTool(.text)
            XCTAssertEqual(canvas.textHandle?.isHidden, true)
            let annotation = try XCTUnwrap(canvas.annotations.first)
            let point = CGPoint(x: annotation.points[0].x + 10, y: annotation.points[0].y + 5)
            canvas.mouseMoved(with: try mouse(.mouseMoved, at: point, panel: panel))
            let handle = try XCTUnwrap(canvas.textHandle)
            XCTAssertFalse(handle.isHidden)
            let crop = canvas.selection
            let start = CGPoint(x: handle.frame.midX, y: handle.frame.midY)
            handle.mouseDown(with: try mouse(.leftMouseDown, at: start, panel: panel))
            XCTAssertTrue(handle.pressed)
            handle.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: start.x + 60, y: start.y - 30), panel: panel))
            handle.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: start.x + 60, y: start.y - 30), panel: panel))
            XCTAssertFalse(handle.pressed); XCTAssertEqual(canvas.selection, crop)
            XCTAssertEqual(canvas.annotations.first?.points, annotation.points.map { CGPoint(x: $0.x + 60, y: $0.y - 30) })
            canvas.undo(); XCTAssertEqual(canvas.annotations.first?.points, annotation.points)
            canvas.redo()
            // Explicit focus keeps arrow keys on the label rather than the configurable tool shortcuts.
            canvas.mouseMoved(with: try mouse(.mouseMoved, at: CGPoint(x: point.x + 60, y: point.y - 30), panel: panel))
            panel.makeFirstResponder(handle)
            let before = try XCTUnwrap(canvas.annotations.first?.points.first)
            panel.sendEvent(try key(124, panel: panel, modifiers: .shift))
            XCTAssertEqual(canvas.annotations.first?.points.first?.x, before.x + 10)
            XCTAssertEqual(canvas.tool, .text); XCTAssertEqual(canvas.selection, crop)
            let output = try ScreenshotRenderer.image(source: canvas.source, size: canvas.documentSize, annotations: canvas.annotations, crop: crop)
            let x = Int(handle.frame.midX - crop.minX), y = Int(crop.maxY - handle.frame.midY)
            let pixel = try XCTUnwrap(output.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
            let rep = NSBitmapImageRep(cgImage: pixel)
            XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)).redComponent, 1, accuracy: 0.01)
            var copies = 0, downloads = 0
            canvas.onCommand = { if $0 == .copy { copies += 1 }; if $0 == .download { downloads += 1 } }
            panel.sendEvent(try key(8, panel: panel, modifiers: .command, characters: "c"))
            XCTAssertEqual(copies, 1)
            XCTAssertTrue(panel.performKeyEquivalent(with: try key(1, panel: panel, modifiers: .command, characters: "s")))
            XCTAssertEqual(downloads, 1)
            panel.sendEvent(try key(6, panel: panel, modifiers: .command, characters: "z"))
            XCTAssertEqual(canvas.annotations.first?.points.first?.x, before.x)
            XCTAssertTrue(panel.firstResponder === canvas, "Hiding an undone label handle must release its focus")
            canvas.mouseMoved(with: try mouse(.mouseMoved, at: CGPoint(x: before.x + 5, y: before.y + 5), panel: panel))
            panel.makeFirstResponder(handle)
            XCTAssertTrue(panel.performKeyEquivalent(with: try key(36, panel: panel, characters: "\r")))
            XCTAssertNotNil(canvas.textEditor); XCTAssertEqual(copies, 1, "Return on the move handle edits instead of exporting")
        }
    }

    func testMultilineStyleAndNativeFixturesAtNarrowAndWideSizes() throws {
        for width in [320, 800] {
            try withCanvas(size: CGSize(width: width, height: 240)) { canvas, panel in
                canvas.selectTool(.text); try click(canvas, at: CGPoint(x: 40, y: 190), panel: panel)
                try type("К архивации — длинная подпись", canvas: canvas)
                let editor = try XCTUnwrap(canvas.textEditor)
                panel.sendEvent(try key(36, panel: panel, modifiers: .shift, characters: "\r"))
                try type("Вторая строка", canvas: canvas)
                XCTAssertTrue(editor.string.contains("\n"))
                canvas.color = .systemBlue; canvas.lineWidth = 5; canvas.applyTextStyle()
                XCTAssertEqual(canvas.annotations.first?.width, 5)
                XCTAssertEqual(editor.font?.pointSize, 30)
                XCTAssertLessThanOrEqual(editor.frame.maxX, canvas.selection.maxX)
                XCTAssertEqual(editor.frame.size.height, ScreenshotTextLayout.size(try XCTUnwrap(canvas.annotations.first)).height)
                let directory = ProcessInfo.processInfo.environment["SCREENSHOT_TEST_RENDER_DIR"]
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    panel.appearance = NSAppearance(named: appearance)
                    if let directory {
                        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
                        canvas.cacheDisplay(in: canvas.bounds, to: rep)
                        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("inline-\(width)-\(appearance.rawValue).png"))
                    }
                }
                canvas.finishTextEditing()
                let text = try XCTUnwrap(canvas.annotations.first)
                let image = try ScreenshotRenderer.image(source: canvas.source, size: canvas.documentSize, annotations: [text], crop: canvas.selection)
                if let directory {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("inline-\(width)-export.png"))
                }
                XCTAssertEqual(image.width, width - 20)
                XCTAssertTrue(ScreenshotTextLayout.frame(text).width <= canvas.selection.width)
            }
        }
    }

    func testReopeningMovedWrappedLabelPreservesLayoutAndUndoHistory() throws {
        try withCanvas(size: CGSize(width: 320, height: 240)) { canvas, panel in
            canvas.selectTool(.text); try click(canvas, at: CGPoint(x: 190, y: 200), panel: panel)
            try type("Несколько слов с переносом", canvas: canvas); canvas.finishTextEditing()
            let handle = try XCTUnwrap(canvas.textHandle)
            let start = CGPoint(x: handle.frame.midX, y: handle.frame.midY)
            handle.mouseDown(with: try mouse(.leftMouseDown, at: start, panel: panel))
            let end = CGPoint(x: start.x - 140, y: start.y)
            handle.mouseDragged(with: try mouse(.leftMouseDragged, at: end, panel: panel))
            handle.mouseUp(with: try mouse(.leftMouseUp, at: end, panel: panel))
            let moved = try XCTUnwrap(canvas.annotations.first)
            let frame = ScreenshotTextLayout.frame(moved)
            try click(canvas, at: CGPoint(x: frame.minX + 5, y: frame.maxY - 8), panel: panel)
            XCTAssertEqual(canvas.annotations.first?.textWidth, moved.textWidth)
            XCTAssertEqual(canvas.textEditor?.frame.origin, frame.origin)
            XCTAssertEqual(canvas.textEditor?.frame.height, frame.height)
            canvas.finishTextEditing()
            XCTAssertEqual(canvas.annotations.first?.points, moved.points)
            canvas.undo()
            XCTAssertEqual(canvas.annotations.first?.points.first?.x, 190, "A click without edits must not add an undo step")
        }
    }
}
