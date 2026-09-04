import Carbon.HIToolbox
import XCTest
@testable import Sidekey

@MainActor
final class HotkeyRecorderBareKeyTests: XCTestCase {

    private func keyDown(_ keyCode: Int, _ chars: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(keyCode)
        )!
    }

    private func keyUp(_ keyCode: Int, _ chars: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(keyCode)
        )!
    }

    private func flags(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 0
        )!
    }

    // MARK: - Release-to-commit: building returns nil, release commits

    func testBareLetterCommitsOnKeyUp() {
        var r = HotkeyShortcutRecorder()
        XCTAssertNil(r.record(keyDown(kVK_ANSI_T, "t")), "пока клавиша зажата — не коммитим")
        let committed = r.record(keyUp(kVK_ANSI_T, "t"))
        guard case .combo(let c)? = committed else { return XCTFail("expected bare T combo, got \(String(describing: committed))") }
        XCTAssertEqual(c.modifiers, 0)
        XCTAssertEqual(c.keyTitle, "T")
        XCTAssertEqual(c.contents.count, 1, "один кейкап, без модификаторного глифа")
    }

    func testBareSpaceCommitsHoldSpace() {
        var r = HotkeyShortcutRecorder()
        XCTAssertNil(r.record(keyDown(kVK_Space, " ")))
        XCTAssertEqual(r.record(keyUp(kVK_Space, " ")), .holdSpace)
    }

    func testBareArrowCommitsModifierlessCombo() {
        var r = HotkeyShortcutRecorder()
        XCTAssertNil(r.record(keyDown(kVK_LeftArrow, "")))
        guard case .combo(let c)? = r.record(keyUp(kVK_LeftArrow, "")) else { return XCTFail("expected bare arrow combo") }
        XCTAssertEqual(c.modifiers, 0)
        XCTAssertEqual(c.keyCode, UInt32(kVK_LeftArrow))
    }

    // MARK: - Combo keeps the modifier through key release (the B1/B8 regression)

    func testComboKeepsModifierUntilAllReleased() {
        var r = HotkeyShortcutRecorder()
        _ = r.record(flags(.option))                 // hold ⌥
        _ = r.record(keyDown(kVK_ANSI_D, "d", flags: .option))  // press D
        XCTAssertEqual(r.contents.count, 2, "поле показывает ⌥D пока зажато")
        XCTAssertNil(r.record(keyUp(kVK_ANSI_D, "d", flags: .option)), "D отпущена, ⌥ ещё зажат — не коммитим")
        let committed = r.record(flags([]))          // release ⌥
        guard case .combo(let c)? = committed else { return XCTFail("expected ⌥D, got \(String(describing: committed))") }
        XCTAssertEqual(c.modifiers, UInt32(optionKey))
        XCTAssertEqual(c.keyCode, UInt32(kVK_ANSI_D))
    }

    func testModifierReleasedBeforeKeyStillCommits() {
        // ⌥ released while D is still held: high-water must retain ⌥, and the
        // commit fires only when D (the last held key) also releases.
        var r = HotkeyShortcutRecorder()
        _ = r.record(flags(.option))                             // hold ⌥
        _ = r.record(keyDown(kVK_ANSI_D, "d", flags: .option))   // press D
        XCTAssertNil(r.record(flags([])), "⌥ released but D still held — no commit yet")
        let committed = r.record(keyUp(kVK_ANSI_D, "d"))         // release D → commit
        guard case .combo(let c)? = committed else { return XCTFail("expected ⌥D via high-water, got \(String(describing: committed))") }
        XCTAssertEqual(c.modifiers, UInt32(optionKey))
        XCTAssertEqual(c.keyCode, UInt32(kVK_ANSI_D))
    }

    func testMultiModifierCombo() {
        var r = HotkeyShortcutRecorder()
        _ = r.record(flags([.command, .shift]))                       // hold ⌘⇧
        _ = r.record(keyDown(kVK_ANSI_A, "a", flags: [.command, .shift]))
        _ = r.record(keyUp(kVK_ANSI_A, "a", flags: [.command, .shift]))
        let committed = r.record(flags([]))
        guard case .combo(let c)? = committed else { return XCTFail("expected ⌘⇧A") }
        XCTAssertEqual(c.modifiers, UInt32(cmdKey) | UInt32(shiftKey))
        XCTAssertEqual(c.keyCode, UInt32(kVK_ANSI_A))
    }

    // MARK: - Invalid combinations do not commit

    func testMultipleModifiersWithoutKeyDoesNotCommit() {
        var r = HotkeyShortcutRecorder()
        _ = r.record(flags([.command, .shift]))
        XCTAssertNil(r.record(flags([])), "несколько модификаторов без символа — не коммитим")
    }

    func testLeftBareModifierDoesNotCommit() {
        // A synthesized .option flagsChanged carries no device right-bit, so it is
        // treated as a non-right (left/ambiguous) modifier — invalid alone.
        var r = HotkeyShortcutRecorder()
        _ = r.record(flags(.option))
        XCTAssertNil(r.record(flags([])), "одиночный не-правый модификатор — не коммитим")
    }

    // MARK: - Re-record after commit

    func testNewPressAfterCommitReplaces() {
        var r = HotkeyShortcutRecorder()
        _ = r.record(keyDown(kVK_ANSI_T, "t"))
        _ = r.record(keyUp(kVK_ANSI_T, "t"))          // committed bare T
        _ = r.record(keyDown(kVK_ANSI_N, "n"))         // fresh press resets
        guard case .combo(let c)? = r.record(keyUp(kVK_ANSI_N, "n")) else { return XCTFail("expected bare N") }
        XCTAssertEqual(c.keyTitle, "N")
    }

    // MARK: - keyTitle coverage retained (B1/B3): Tab / F-keys / nav / Delete

    func testTitledKeysRecordReadableTitles() {
        let cases: [(Int, String, String)] = [
            (kVK_Tab, "\t", "Tab"),
            (kVK_F5, "\u{F70E}", "F5"),
            (kVK_Home, "\u{F729}", "Home"),
            (kVK_ForwardDelete, "\u{F728}", "Forward Delete"),
            (kVK_Delete, "\u{7F}", "Delete")
        ]
        for (code, chars, title) in cases {
            var r = HotkeyShortcutRecorder()
            _ = r.record(keyDown(code, chars))
            guard case .combo(let c)? = r.record(keyUp(code, chars)) else { return XCTFail("expected combo for \(title)") }
            XCTAssertEqual(c.keyTitle, title, "keyCode \(code) → \(title)")
        }
    }

    // MARK: - Seeded display

    func testSeededComboShowsInContents() {
        let r = HotkeyShortcutRecorder(shortcut: .combo(.optionD))
        XCTAssertEqual(r.contents.count, 2, "seeded ⌥D показывается до ввода")
    }

    func testSeededModifierOnlyShowsInContents() {
        let r = HotkeyShortcutRecorder(shortcut: .modifier(.rightOption))
        XCTAssertEqual(r.contents.count, 1)
    }
}
