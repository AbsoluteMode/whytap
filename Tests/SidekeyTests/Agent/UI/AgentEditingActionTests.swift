import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Sidekey

/// Pins the pure-logic Cmd+C / Cmd+A classifier used by the Dynamic Island
/// answer panel's local key monitor.
///
/// Sidekey runs at `.accessory` (LSUIElement) so it has no main menu.
/// The Edit menu's Copy item is what normally owns Cmd+C and routes
/// it via `NSApplication.sendAction(_:to:from:)` to the first
/// responder. Without that menu, plain Cmd+C on selected
/// `Text(...).textSelection(.enabled)` text silently does nothing
/// (Maxim's bug 2). The island monitor replays the dispatch manually
/// using this classifier.
///
/// `AgentEditingAction.action(for:)` returns the selector the host
/// should dispatch, or nil when the event isn't one of the editing
/// shortcuts we forward.
@MainActor
final class AgentEditingActionTests: XCTestCase {
    func testEditingActionMapsCmdCToCopy() {
        // English (ANSI / QWERTY) layout: physical "C" key yields the
        // character "c". Classifier must return `copy(_:)`.
        let event = Self.makeKeyEquivalentEvent(
            characters: "c",
            modifierFlags: .command,
            keyCode: UInt16(kVK_ANSI_C)
        )
        XCTAssertEqual(
            AgentEditingAction.action(for: event),
            #selector(NSText.copy(_:))
        )
    }

    func testEditingActionMapsCmdAToSelectAll() {
        // English (ANSI / QWERTY) layout: physical "A" key yields "a".
        let event = Self.makeKeyEquivalentEvent(
            characters: "a",
            modifierFlags: .command,
            keyCode: UInt16(kVK_ANSI_A)
        )
        XCTAssertEqual(
            AgentEditingAction.action(for: event),
            #selector(NSResponder.selectAll(_:))
        )
    }

    /// Maxim's bug: on Russian ЙЦУКЕН layout the physical "C" key emits
    /// "с" (U+0441 Cyrillic Es), not Latin "c". A layout-dependent
    /// classifier (string-compare on `charactersIgnoringModifiers`)
    /// silently breaks Cmd+C for the Russian-speaking user base. The
    /// classifier must compare by physical `keyCode` (kVK_ANSI_C = 8)
    /// so the shortcut survives every keyboard layout.
    func testEditingActionMapsCmdCToCopyOnCyrillicLayout() {
        let event = Self.makeKeyEquivalentEvent(
            characters: "\u{0441}", // Cyrillic Es
            modifierFlags: .command,
            keyCode: UInt16(kVK_ANSI_C)
        )
        XCTAssertEqual(
            AgentEditingAction.action(for: event),
            #selector(NSText.copy(_:)),
            "Cmd+C must map to copy regardless of active keyboard layout"
        )
    }

    /// Twin to the Cmd+C cyrillic case: Russian ЙЦУКЕН emits "ф"
    /// (U+0444 Cyrillic Ef) on the physical "A" key. Select-all must
    /// keep working.
    func testEditingActionMapsCmdAToSelectAllOnCyrillicLayout() {
        let event = Self.makeKeyEquivalentEvent(
            characters: "\u{0444}", // Cyrillic Ef
            modifierFlags: .command,
            keyCode: UInt16(kVK_ANSI_A)
        )
        XCTAssertEqual(
            AgentEditingAction.action(for: event),
            #selector(NSResponder.selectAll(_:)),
            "Cmd+A must map to selectAll regardless of active keyboard layout"
        )
    }

    func testEditingActionRejectsCmdXSoReadOnlyPanelDoesNotIntercept() {
        // The answer surface is read-only — Cut has nothing to act on
        // and must not be hijacked away from system fallbacks.
        let event = Self.makeKeyEquivalentEvent(
            characters: "x",
            modifierFlags: .command,
            keyCode: UInt16(kVK_ANSI_X)
        )
        XCTAssertNil(AgentEditingAction.action(for: event))
    }

    func testEditingActionRejectsCmdVSoReadOnlyPanelDoesNotIntercept() {
        let event = Self.makeKeyEquivalentEvent(
            characters: "v",
            modifierFlags: .command,
            keyCode: UInt16(kVK_ANSI_V)
        )
        XCTAssertNil(AgentEditingAction.action(for: event))
    }

    func testEditingActionRejectsCmdShiftCSoOtherShortcutsAreFree() {
        // Cmd+Shift+C is commonly bound by other features (Slack's
        // "copy as plain text", screenshot tools, etc.). Our forwarder
        // must only act on plain Cmd to avoid stealing those.
        let event = Self.makeKeyEquivalentEvent(
            characters: "c",
            modifierFlags: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_C)
        )
        XCTAssertNil(AgentEditingAction.action(for: event))
    }

    func testEditingActionRejectsPlainKeyWithoutCmd() {
        // Without the Cmd modifier the keystroke is a normal character
        // and must flow through to the responder chain untouched.
        let event = Self.makeKeyEquivalentEvent(
            characters: "c",
            modifierFlags: [],
            keyCode: UInt16(kVK_ANSI_C)
        )
        XCTAssertNil(AgentEditingAction.action(for: event))
    }

    func testEditingActionRejectsUnsupportedCmdLetters() {
        // Catch-all: every Cmd+<letter> that isn't C / A must return
        // nil so we don't accidentally extend the contract. Use real
        // physical keyCodes so the negative case mirrors how AppKit
        // actually delivers the events on any keyboard layout.
        let letters: [(String, UInt16)] = [
            ("b", UInt16(kVK_ANSI_B)),
            ("d", UInt16(kVK_ANSI_D)),
            ("f", UInt16(kVK_ANSI_F)),
            ("z", UInt16(kVK_ANSI_Z))
        ]
        for (letter, keyCode) in letters {
            let event = Self.makeKeyEquivalentEvent(
                characters: letter,
                modifierFlags: .command,
                keyCode: keyCode
            )
            XCTAssertNil(
                AgentEditingAction.action(for: event),
                "Cmd+\(letter) must not be intercepted"
            )
        }
    }

    /// Synthesises an `NSEvent` that mimics a key-equivalent press.
    /// `keyDown` is the event type AppKit feeds into
    /// `performKeyEquivalent`. `windowNumber` 0 is fine because the
    /// classifier reads only `modifierFlags` + `keyCode` (and used to
    /// also read `charactersIgnoringModifiers` before the
    /// layout-independent fix — kept on the helper so future layout-
    /// aware tests can vary it independently from `keyCode`).
    private static func makeKeyEquivalentEvent(
        characters: String,
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent {
        // Force-unwrap: `NSEvent.keyEvent(...)` only returns nil when
        // the type isn't a key event; we always pass `.keyDown`.
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
