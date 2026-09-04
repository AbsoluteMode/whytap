import AppKit
import XCTest
@testable import Sidekey

/// The passive Escape-close monitor must react to BARE Escape only.
/// Modified Escape chords (⌘⎋, ⌥⎋, …) are other apps' / the system's
/// shortcuts, and non-Escape keys must never trigger the close.
final class EscapeCloseEventMonitorTests: XCTestCase {
    func testBareEscapeTriggers() {
        XCTAssertTrue(EscapeCloseEventMonitor.isBareEscape(keyCode: 53, modifierFlags: []))
    }

    func testModifiedEscapeChordsDoNotTrigger() {
        for flags in [NSEvent.ModifierFlags.command, .option, .control, .shift] {
            XCTAssertFalse(
                EscapeCloseEventMonitor.isBareEscape(keyCode: 53, modifierFlags: flags),
                "Escape with \(flags) is a chord, not the bare close key"
            )
        }
    }

    func testKeyboardStateModifiersDoNotBlockEscape() {
        // Caps Lock / fn are keyboard state, not a chord — Esc stays bare Esc.
        XCTAssertTrue(EscapeCloseEventMonitor.isBareEscape(keyCode: 53, modifierFlags: [.capsLock]))
        XCTAssertTrue(EscapeCloseEventMonitor.isBareEscape(keyCode: 53, modifierFlags: [.function]))
    }

    func testOtherKeysDoNotTrigger() {
        XCTAssertFalse(EscapeCloseEventMonitor.isBareEscape(keyCode: 12, modifierFlags: []))
        XCTAssertFalse(EscapeCloseEventMonitor.isBareEscape(keyCode: 0, modifierFlags: []))
    }
}
