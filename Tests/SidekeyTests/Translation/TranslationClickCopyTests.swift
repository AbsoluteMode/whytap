import AppKit
import SwiftUI
@testable import Sidekey
import XCTest

/// A click on a translation copies all of it and says "Copied ✓" for a
/// second. Real mouse events go to the real panel, placed far outside every
/// screen, and copies land on a private pasteboard, never the user's.
// WHY: .project-docs/decisions/2026-11-24-click-to-copy-translation.md
@MainActor
final class TranslationClickCopyTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("translation-click-copy-\(UUID())"))
        pasteboard.clearContents()
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    private var copied: String? { pasteboard.string(forType: .string) }

    private func settle(_ seconds: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in panel: NSWindow,
                       modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: clicks, pressure: 1))
    }

    /// Down and up through the panel, as AppKit delivers them.
    private func click(_ panel: NSWindow, at point: NSPoint, modifiers: NSEvent.ModifierFlags = [],
                       clicks: Int = 1) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            panel.sendEvent(try mouse(type, at: point, in: panel, modifiers: modifiers, clicks: clicks))
            settle()
        }
    }

    private func controller(text: TextTranslationModel? = nil,
                            subtitles: LiveSubtitleModel? = nil) throws -> TranslationWindowController {
        TranslationWindowController(
            textModel: text ?? TextTranslationModel(makeService: { FixtureTranslator() }), subtitleModel: subtitles,
            defaults: try XCTUnwrap(UserDefaults(suiteName: "translation-click-copy-\(UUID())")),
            pasteboard: pasteboard, openSettings: { _ in }, activityChanged: { _ in })
    }

    private func showOffScreen(_ controller: TranslationWindowController, _ mode: TranslationWindowController.Mode,
                               size: NSSize) {
        controller.presentation.mode = mode
        controller.resize(for: mode)
        controller.window.setFrame(NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                   display: false)
        controller.window.orderFrontRegardless()
        settle(0.4)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        controller.window.displayIfNeeded()
        settle()
    }

    /// With WHYTAP_TRANSLATION_RENDER_DIR set, saves what the panel shows.
    private func snapshot(_ panel: NSWindow, _ name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_TRANSLATION_RENDER_DIR"],
              let view = panel.contentView else { return }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: Translate

    /// Type, Return, click the answer: the whole answer is on the clipboard,
    /// "Copied ✓" shows, and it is gone a second later.
    func testClickingTheTranslationCopiesAllOfItForAMoment() async throws {
        let text = TextTranslationModel(makeService: { FixtureTranslator() })
        let controller = try controller(text: text)
        defer { controller.dismiss() }
        showOffScreen(controller, .text, size: NSSize(width: 560, height: 140))
        let panel = controller.window
        XCTAssertNil(controller.hitTargets.frame(of: .copy, in: panel), "the placeholder copies nothing")

        text.input = "Отлично, до завтра!"
        await text.translate()?.value
        settle(0.3)
        let result = text.result
        XCTAssertEqual(result, "Перевод: Отлично, до завтра!")
        let target = try XCTUnwrap(controller.hitTargets.frame(of: .copy, in: panel))

        try click(panel, at: NSPoint(x: target.minX + 20, y: target.midY))
        XCTAssertEqual(copied, result)
        XCTAssertTrue(controller.copier.copied, "Copied ✓ shows")
        settle(0.3)
        try snapshot(panel, "click-copy-text")
        try await Task.sleep(for: .milliseconds(1_300))
        XCTAssertFalse(controller.copier.copied, "and goes after a second")
    }

    /// A drag over the answer is a selection: the panel passes every event
    /// on to the text and copies nothing.
    func testDraggingOverTheTranslationSelectsInsteadOfCopying() async throws {
        let text = TextTranslationModel(makeService: { FixtureTranslator() })
        let controller = try controller(text: text)
        defer { controller.dismiss() }
        showOffScreen(controller, .text, size: NSSize(width: 560, height: 140))
        let panel = controller.window
        text.input = "Слайды пришлю вечером."
        await text.translate()?.value
        settle(0.3)
        let target = try XCTUnwrap(controller.hitTargets.frame(of: .copy, in: panel))
        let start = NSPoint(x: target.minX + 10, y: target.midY)

        XCTAssertFalse(controller.hitTargets.handle(try mouse(.leftMouseDown, at: start, in: panel), in: panel),
                       "the text gets the press")
        for dx in stride(from: 10, through: 120, by: 10) {
            let point = NSPoint(x: start.x + CGFloat(dx), y: start.y)
            XCTAssertFalse(controller.hitTargets.handle(try mouse(.leftMouseDragged, at: point, in: panel), in: panel))
        }
        let end = NSPoint(x: start.x + 120, y: start.y)
        XCTAssertFalse(controller.hitTargets.handle(try mouse(.leftMouseUp, at: end, in: panel), in: panel))
        XCTAssertNil(copied)
        XCTAssertFalse(controller.copier.copied)

        // A double click selects a word; only its first click copies.
        try click(panel, at: start)
        pasteboard.clearContents()
        try click(panel, at: start, clicks: 2)
        XCTAssertNil(copied)
        // Control-click opens the menu, it does not copy.
        try click(panel, at: start, modifiers: .control)
        XCTAssertNil(copied)
    }

    /// While a new translation runs, the old one is gone: nothing to copy.
    func testNothingIsCopiedWhileTranslating() async throws {
        struct SlowTranslator: TextTranslating {
            func translate(_ text: String, target: TranslationTarget) async throws -> String {
                try await Task.sleep(for: .seconds(5))
                return text
            }
        }
        let text = TextTranslationModel(makeService: { SlowTranslator() })
        let controller = try controller(text: text)
        defer { controller.dismiss(); text.cancel() }
        showOffScreen(controller, .text, size: NSSize(width: 560, height: 140))
        text.input = "Привет"
        text.translate()
        settle(0.3)
        XCTAssertTrue(text.isTranslating)
        XCTAssertNil(controller.hitTargets.frame(of: .copy, in: controller.window))
    }

    // MARK: Subtitles

    /// A stopped session with pairs in the 760 x 190 pt overlay.
    private func stoppedOverlay() async throws -> (TranslationWindowController, LiveSubtitleModel) {
        let speech = FakeSpeechTranslation()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), makeAudio: { FixtureSubtitleAudio() },
                                      openTranslator: { _, _ in speech })
        model.sourceCode = "en"
        model.targetCode = "ru"
        let controller = try controller(subtitles: model)
        model.start()
        for _ in 0..<200 where model.phase != .listening { try await Task.sleep(for: .milliseconds(5)) }
        speech.yieldRecorded(until: 20_000)
        for _ in 0..<200 where model.lines.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        model.stop()
        for _ in 0..<400 where model.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
        showOffScreen(controller, .subtitles, size: NSSize(width: 760, height: 190))
        return (controller, model)
    }

    /// A click on the translation column copies every translated phrase;
    /// the original's column and the controls do not.
    func testClickingTheSubtitleTranslationCopiesTheWholeTranslation() async throws {
        let (controller, model) = try await stoppedOverlay()
        defer { controller.dismiss() }
        let panel = controller.window
        XCTAssertFalse(panel.isKeyWindow, "the overlay never takes focus from the video")
        let expected = TranslationView.subtitleTranslation(model.lines)
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(expected, model.lines.compactMap(\.translation).joined(separator: "\n\n"))

        let column = try XCTUnwrap(controller.hitTargets.frame(of: .copy, in: panel))
        let content = try XCTUnwrap(panel.contentView).bounds
        XCTAssertGreaterThan(column.minX, content.width * 0.3, "the original's column is not a copy target")
        let close = try XCTUnwrap(controller.hitTargets.frame(of: .close, in: panel))
        XCTAssertFalse(column.intersects(close))

        // The original does nothing.
        try click(panel, at: NSPoint(x: column.minX - 40, y: column.midY))
        XCTAssertNil(copied)
        XCTAssertTrue(panel.isVisible)

        try click(panel, at: NSPoint(x: column.midX, y: column.midY))
        XCTAssertEqual(copied, expected)
        XCTAssertTrue(controller.copier.copied)
        settle(0.3)
        try snapshot(panel, "click-copy-subtitles")
        try await Task.sleep(for: .milliseconds(1_300))
        XCTAssertFalse(controller.copier.copied)
        XCTAssertTrue(panel.isVisible, "copying keeps the overlay open")
    }

    /// The overlay is moved by dragging it: a press on the translation that
    /// moves becomes a window drag and copies nothing.
    func testDraggingTheSubtitlesMovesTheOverlayInsteadOfCopying() async throws {
        let (controller, _) = try await stoppedOverlay()
        defer { controller.dismiss() }
        let panel = controller.window
        var drags = 0
        controller.hitTargets.startWindowDrag = { _, _ in drags += 1 }
        let column = try XCTUnwrap(controller.hitTargets.frame(of: .copy, in: panel))
        let start = NSPoint(x: column.midX, y: column.midY)

        XCTAssertTrue(controller.hitTargets.handle(try mouse(.leftMouseDown, at: start, in: panel), in: panel))
        XCTAssertTrue(controller.hitTargets.handle(
            try mouse(.leftMouseDragged, at: NSPoint(x: start.x + 2, y: start.y), in: panel), in: panel),
            "a tremor is still a click")
        XCTAssertEqual(drags, 0)
        XCTAssertTrue(controller.hitTargets.handle(
            try mouse(.leftMouseDragged, at: NSPoint(x: start.x + 30, y: start.y + 10), in: panel), in: panel))
        XCTAssertEqual(drags, 1, "the press became a window drag")
        XCTAssertTrue(controller.hitTargets.handle(
            try mouse(.leftMouseUp, at: NSPoint(x: start.x + 30, y: start.y + 10), in: panel), in: panel))
        XCTAssertNil(copied)
        XCTAssertFalse(controller.copier.copied)
    }

    /// Copy translation in the right-click menu shows the same "Copied ✓".
    func testTheCopierWritesTheValueAndTellsVoiceOverWithoutTheSystemClipboard() throws {
        let copier = TranslationView.makeCopier(pasteboard: pasteboard)
        copier.copy("Great, see you tomorrow!")
        XCTAssertEqual(copied, "Great, see you tomorrow!")
        XCTAssertTrue(copier.copied)
        XCTAssertEqual(TranslationView.copiedShownFor, .seconds(1))
    }
}
