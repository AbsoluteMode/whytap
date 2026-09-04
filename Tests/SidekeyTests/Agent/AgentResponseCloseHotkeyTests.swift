import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Sidekey

/// Pins the Carbon registration contract for the agent answer close
/// hotkey (Option+Q). The lifecycle (register when the island answer
/// panel is visible, tear down on idle) is covered by
/// `AgentControllerStreamingTests.testCloseHotkeyLifecycleTracksAnswerPanelVisibility`;
/// this file guards the key combo + Carbon id so a rename can't silently
/// change which shortcut closes the panel.
@MainActor
final class AgentResponseCloseHotkeyTests: XCTestCase {
    func testDefaultCloseHotkeyTargetsOptionQ() {
        // Production wiring of the close hotkey must target kVK_ANSI_Q
        // (12) with the side-agnostic Option modifier and the
        // responseCloseHotKeyID Carbon registration slot. Anchored on the
        // shared CarbonHotkeyMonitor constants so a future rename
        // doesn't silently change the key combo.
        XCTAssertEqual(CarbonHotkeyMonitor.qKeyCode, 12)
        XCTAssertEqual(CarbonHotkeyMonitor.optionModifier, UInt32(optionKey))
        // Carbon `(signature, id)` route — the close hotkey must use a
        // distinct id from the drop (1) and help (2) hotkeys so events
        // don't cross-dispatch.
        XCTAssertNotEqual(
            CarbonHotkeyMonitor.responseCloseHotKeyID,
            CarbonHotkeyMonitor.dropHotKeyID
        )
        XCTAssertNotEqual(
            CarbonHotkeyMonitor.responseCloseHotKeyID,
            CarbonHotkeyMonitor.helpHotKeyID
        )
    }

    func testSetOnHotkeyBeforeStartWiresTheHandlerForLaterFiring() {
        // The owner constructs the adapter, wires the callback via
        // setOnHotkey, then start()s only when the answer surface is
        // visible. setOnHotkey must not throw or require a prior start().
        let preferences = HotkeyPreferences(defaults: makeHotkeyDefaults())
        let hotkey = CarbonResponseCloseHotkey(hotkeyPreferences: preferences)
        var fired = false
        hotkey.setOnHotkey { fired = true }
        // stop() without a prior start() is a no-op (defensive) and must
        // not crash — the lifecycle owner calls it on every hide.
        hotkey.stop()
        XCTAssertFalse(fired, "handler must not fire until the Carbon event arrives")
    }

    private func makeHotkeyDefaults() -> UserDefaults {
        let suiteName = "SidekeyTests.AgentResponseCloseHotkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
