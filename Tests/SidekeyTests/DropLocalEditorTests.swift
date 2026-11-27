import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Drop dictated into one of Whytap's own text editors. Every window here is
/// offscreen and never shown; the user's clipboard is never read or written.
/// WHY: .project-docs/decisions/2026-11-18-drop-into-whytap-editors.md
@MainActor
final class DropLocalEditorTests: XCTestCase {

    // MARK: - The floating Translate input (the reported defect)

    /// A file is on the clipboard, the Translate input has the keyboard and
    /// another app is frontmost. The take must end as speech in the input,
    /// with the clipboard neither read, written nor restored and no Cmd+V.
    func testDictationReachesTheTranslateInputAndNeverTouchesTheClipboard() async throws {
        let translate = try TranslateFixture()
        defer { translate.close() }
        let clipboard = ClipboardSpy(holding: "copied-file.pdf")
        let engine = clipboard.engine(frontmost: .init(pid: 4242, name: "Finder"), window: translate.window)

        engine.rememberDropTarget()
        let delivered = await engine.paste("dictated text")

        XCTAssertTrue(delivered)
        XCTAssertEqual(translate.model.input, "dictated text", "The SwiftUI binding must see the edit")
        XCTAssertEqual(clipboard.contents, "copied-file.pdf")
        XCTAssertEqual(clipboard.reads + clipboard.writes + clipboard.restores, 0)
        XCTAssertTrue(clipboard.postedKeys.isEmpty)
        XCTAssertNil(engine.currentDropTarget().pid, "Smart must not read the frontmost app for this take")
        XCTAssertFalse(translate.window.isVisible || translate.window.isKeyWindow, "The check stays offscreen")
    }

    func testSpaceHoldRecognizesTranslateEvenWhenFinderIsFrontmost() throws {
        let translate = try TranslateFixture()
        defer { translate.close() }
        let editor = try XCTUnwrap(DropLocalEditor(focusedIn: translate.window, isPresented: { _ in true }))
        XCTAssertTrue(SpaceHoldMonitor.isEditableForDrop(pid: 4242, bundleId: "com.apple.finder", localEditor: editor))
        XCTAssertFalse(SpaceHoldMonitor.isEditableForDrop(pid: 4242, bundleId: "com.apple.finder", localEditor: nil))
    }

    func testDictationReplacesTheSelectionAndLeavesTheCaretAfterIt() throws {
        let translate = try TranslateFixture()
        defer { translate.close() }
        translate.editor.insertText("Before selection after", replacementRange: NSRange(location: NSNotFound, length: 0))
        translate.editor.setSelectedRange(NSRange(location: 7, length: 9))
        let target = try XCTUnwrap(DropLocalEditor(focusedIn: translate.window, isPresented: { _ in true }))

        XCTAssertTrue(target.insert("dictated text"))

        XCTAssertEqual(translate.model.input, "Before dictated text after")
        XCTAssertEqual(translate.editor.selectedRange(), NSRange(location: 20, length: 0))
    }

    /// Smart can return paragraphs. Typing them in keeps the same text a
    /// paste of that dictation would have left in this field.
    func testParagraphsArriveAsTheyWouldFromAPaste() throws {
        let translate = try TranslateFixture()
        defer { translate.close() }
        let target = try XCTUnwrap(DropLocalEditor(focusedIn: translate.window, isPresented: { _ in true }))

        XCTAssertTrue(target.insert("first\n\nsecond"))

        XCTAssertEqual(translate.model.input, "first\n\nsecond")
    }

    /// Retry and batch recovery deliver later, through the same engine call.
    /// A palette closed in between (Escape, a click outside) keeps its unsent
    /// input; the late dictation must not land in the hidden field or in the
    /// app that is frontmost by then.
    func testLateDeliveryAfterThePaletteClosedGoesNowhere() async throws {
        let translate = try TranslateFixture()
        defer { translate.close() }
        translate.editor.insertText("unsent", replacementRange: NSRange(location: NSNotFound, length: 0))
        let clipboard = ClipboardSpy(holding: "copied-file.pdf")
        let engine = clipboard.engine(frontmost: .init(pid: 4242, name: "Finder"), window: translate.window,
                                      isPresented: { _ in translate.presented })
        engine.rememberDropTarget()

        translate.presented = false
        let delivered = await engine.paste("recovered take")

        XCTAssertFalse(delivered)
        XCTAssertEqual(translate.model.input, "unsent")
        XCTAssertEqual(clipboard.reads + clipboard.writes + clipboard.restores, 0)
        XCTAssertTrue(clipboard.postedKeys.isEmpty, "Finder must not receive the dictation")

        // The same take retried once the palette is back in front of the user.
        translate.presented = true
        let retried = await engine.paste("recovered take")
        XCTAssertTrue(retried)
        XCTAssertEqual(translate.model.input, "unsentrecovered take")
    }

    /// The panel without a focused editor (Subtitles) is not a destination.
    func testWithoutAFocusedEditorDropKeepsItsOrdinaryClipboardPath() async throws {
        let translate = try TranslateFixture()
        defer { translate.close() }
        XCTAssertTrue(translate.window.makeFirstResponder(nil))
        let clipboard = ClipboardSpy(holding: "copied-file.pdf")
        let engine = clipboard.engine(frontmost: .init(pid: 4242, name: "Notes"), window: translate.window)

        engine.rememberDropTarget()
        let delivered = await engine.paste("dictated text")
        await engine.waitForPendingRestore()

        XCTAssertTrue(delivered)
        XCTAssertEqual(engine.currentDropTarget().pid, 4242)
        XCTAssertEqual(clipboard.writes, 1)
        XCTAssertEqual(clipboard.postedKeys.count, 4)
        XCTAssertEqual(clipboard.restores, 1)
        XCTAssertEqual(clipboard.contents, "copied-file.pdf")
        XCTAssertEqual(translate.model.input, "")
    }

    // MARK: - Any native editor of the app

    func testIslandSearchReceivesTheTakeWithTheCaretAtTheEnd() throws {
        let window = Self.offscreenWindow()
        let search = IslandHoverSearchNativeField(frame: window.contentView!.bounds)
        window.contentView?.addSubview(search)
        XCTAssertTrue(window.makeFirstResponder(search))
        let target = try XCTUnwrap(DropLocalEditor(focusedIn: window, isPresented: { _ in true }))
        XCTAssertTrue(target.insert("translate"))
        XCTAssertEqual(search.stringValue, "translate")
        XCTAssertEqual((window.firstResponder as? NSTextView)?.selectedRange(), NSRange(location: 9, length: 0))
    }

    func testSettingsFieldsReceiveTextThroughTheirBindings() throws {
        for secure in [false, true] {
            var value = ""
            let window = Self.offscreenWindow()
            let fieldView = MacField(placeholder: "Input", text: Binding(get: { value }, set: { value = $0 }), isSecure: secure)
            let host = NSHostingView(rootView: fieldView)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let field = try XCTUnwrap(Self.editableField(in: host))
            XCTAssertTrue(window.makeFirstResponder(field))
            let target = try XCTUnwrap(DropLocalEditor(focusedIn: window, isPresented: { _ in true }))
            XCTAssertTrue(target.insert("sample"))
            XCTAssertEqual(value, "sample")
        }
    }

    func testATextViewTakesTheDictationAtItsSelection() throws {
        let window = Self.offscreenWindow()
        let view = NSTextView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        view.string = "one three"
        XCTAssertTrue(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: 4, length: 0))
        let target = try XCTUnwrap(DropLocalEditor(focusedIn: window, isPresented: { _ in true }))

        XCTAssertTrue(target.insert("two\n"))

        XCTAssertEqual(view.string, "one two\nthree")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 8, length: 0))
    }

    /// A window has one field editor for all its fields. After focus moves
    /// to another field the remembered one is gone, even though the field
    /// editor object is the same.
    func testFocusMovedToAnotherFieldOfTheWindowIsALostTarget() throws {
        let window = Self.offscreenWindow()
        let first = NSTextField(frame: NSRect(x: 0, y: 40, width: 200, height: 24))
        let second = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        XCTAssertTrue(window.makeFirstResponder(first))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let target = try XCTUnwrap(DropLocalEditor(focusedIn: window, isPresented: { _ in true }))

        XCTAssertTrue(window.makeFirstResponder(second))
        XCTAssertTrue(window.firstResponder === editor, "Precondition: the field editor is shared")

        XCTAssertFalse(target.insert("dictated text"))
        XCTAssertEqual(first.stringValue, "")
        XCTAssertEqual(second.stringValue, "")

        XCTAssertTrue(window.makeFirstResponder(first))
        XCTAssertTrue(target.insert("dictated text"), "Back in the remembered field it is the target again")
        XCTAssertEqual(first.stringValue, "dictated text")
    }

    func testAReleasedWindowOrEditorIsALostTarget() throws {
        var window: NSWindow? = Self.offscreenWindow()
        var view: NSTextView? = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        window?.contentView?.addSubview(view!)
        XCTAssertTrue(window!.makeFirstResponder(view))
        let target = try XCTUnwrap(DropLocalEditor(focusedIn: window, isPresented: { _ in true }))

        view?.removeFromSuperview()
        XCTAssertFalse(target.insert("dictated text"), "Removed from its window, it lost the keyboard")
        view = nil
        window = nil
        XCTAssertFalse(target.insert("dictated text"))
    }

    /// The edit goes through the editor's own rules, as typing does: a field
    /// that refuses the characters (Case approval minutes) stays unchanged.
    func testAnEditorThatRefusesTheTextStaysUnchanged() throws {
        let window = Self.offscreenWindow()
        let view = NSTextView(frame: window.contentView!.bounds)
        let refusing = RefusingDelegate()
        view.delegate = refusing
        window.contentView?.addSubview(view)
        view.string = "15"
        XCTAssertTrue(window.makeFirstResponder(view))
        let target = try XCTUnwrap(DropLocalEditor(focusedIn: window, isPresented: { _ in true }))

        XCTAssertFalse(target.insert("dictated text"))

        XCTAssertEqual(view.string, "15")
        XCTAssertEqual(refusing.offered, ["dictated text"])
    }

    func testOnlyAShownWindowWithAnEditableTextEditorIsATarget() {
        XCTAssertNil(DropLocalEditor(focusedIn: nil))

        let window = Self.offscreenWindow()
        let view = NSTextView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertNil(DropLocalEditor(focusedIn: window), "A window that is not on screen is not where the user types")
        XCTAssertNotNil(DropLocalEditor(focusedIn: window, isPresented: { _ in true }))

        view.isEditable = false
        XCTAssertNil(DropLocalEditor(focusedIn: window, isPresented: { _ in true }), "Selectable text is not an editor")

        let button = NSButton(title: "OK", target: nil, action: nil)
        window.contentView?.addSubview(button)
        window.makeFirstResponder(button)
        XCTAssertNil(DropLocalEditor(focusedIn: window, isPresented: { _ in true }))
    }

    func testAnEditorMadeReadOnlyAfterTheTakeBeganIsALostTarget() throws {
        let window = Self.offscreenWindow()
        let view = NSTextView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        let target = try XCTUnwrap(DropLocalEditor(focusedIn: window, isPresented: { _ in true }))

        view.isEditable = false

        XCTAssertFalse(target.insert("dictated text"))
        XCTAssertEqual(view.string, "")
    }

    // MARK: - Fixtures

    private static func editableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(editableField).first
    }

    private static func offscreenWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private final class RefusingDelegate: NSObject, NSTextViewDelegate {
        var offered: [String] = []
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            offered.append(replacementString ?? "")
            return false
        }
    }

    /// The production Translate panel with its real SwiftUI input focused.
    @MainActor
    private final class TranslateFixture {
        let controller: TranslationWindowController
        let model: TextTranslationModel
        let editor: NSTextView
        var presented = true
        private let defaults: UserDefaults
        private let suite = "DropLocalEditorTests-" + UUID().uuidString
        var window: NSWindow { controller.window }

        init() throws {
            _ = NSApplication.shared
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            model = TextTranslationModel(makeService: { FixtureTranslator() })
            controller = TranslationWindowController(
                textModel: model,
                subtitleModel: LiveSubtitleModel(makeAudio: { FixtureSubtitleAudio() },
                                                 openTranslator: { _, _ in FixtureSubtitleUpstream() }),
                defaults: defaults, openSettings: { _ in }, activityChanged: { _ in }
            )
            let content = try XCTUnwrap(controller.window.contentView)
            content.layoutSubtreeIfNeeded()
            let field = try XCTUnwrap(DropLocalEditorTests.editableField(in: content), "The Translate input is a native text field")
            XCTAssertTrue(controller.window.makeFirstResponder(field))
            editor = try XCTUnwrap(controller.window.firstResponder as? NSTextView)
        }

        func close() {
            controller.window.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// Stands in for the system clipboard and the event tap, and counts every
    /// access the engine makes to them.
    @MainActor
    private final class ClipboardSpy {
        var contents: String
        private(set) var reads = 0
        private(set) var writes = 0
        private(set) var restores = 0
        private(set) var postedKeys: [CGKeyCode] = []
        private(set) var changeCount = 0
        private let original: String

        init(holding value: String) {
            contents = value
            original = value
        }

        func engine(frontmost: AutoPasteEngine.RememberedTarget, window: NSWindow,
                    isPresented: @escaping (NSWindow) -> Bool = { _ in true }) -> AutoPasteEngine {
            AutoPasteEngine(
                flagsState: { [] }, frontmostAppInfo: { frontmost }, activate: { _ in true },
                isTerminated: { _ in false }, permissionGranted: { _ in true },
                pasteboardWrite: { [unowned self] text in
                    self.writes += 1
                    self.contents = text
                    self.changeCount += 1
                    return (before: self.changeCount - 1, after: self.changeCount)
                },
                postEvent: { [unowned self] code, _, _ in self.postedKeys.append(code) },
                sleepUs: { _ in }, nowMs: { 0 }, logEmit: { _, _ in },
                pasteboardSnapshot: { [unowned self] in
                    self.reads += 1
                    return PasteboardSnapshot(items: [])
                },
                pasteboardRestore: { [unowned self] _ in
                    self.restores += 1
                    self.contents = self.original
                    self.changeCount += 1
                },
                currentChangeCount: { [unowned self] in self.changeCount },
                localEditor: { [weak window] in
                    guard let editor = DropLocalEditor(focusedIn: window, isPresented: isPresented) else { return nil }
                    return AutoPasteEngine.LocalEditorTarget(name: "Whytap", insert: { editor.insert($0) })
                }
            )
        }
    }
}
