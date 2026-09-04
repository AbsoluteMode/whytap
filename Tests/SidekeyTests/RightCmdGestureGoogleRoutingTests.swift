import XCTest
@testable import Sidekey

@MainActor
final class RightCmdGestureGoogleRoutingTests: XCTestCase {
    private func machine() -> RightCmdGestureStateMachine {
        // Agent on R-Cmd (defaults), Google on R-Option (defaults).
        RightCmdGestureStateMachine(
            captureSnapshot: { nil },
            configuration: .defaults
        )
    }

    // Raw CGEventFlags bit for "right option only":
    // NX_DEVICERALTKEYMASK (0x40) plus kCGEventFlagMaskAlternate (0x080000).
    // HotkeyFlags.isOnly(.rightOption, ...) gates on 0x40 and checks that
    // shift/control/command are clear; alternateMask is not checked (right
    // Option itself sets it), so this combination passes isOnly correctly.
    private let rightOptionFlags: UInt64 = 0x40 | 0x080000
    // Right-Command device bit + NSEvent.command — mirrors HotkeyFlags.isOnly.
    private let rightCommandFlags: UInt64 = 0x10 | 0x100000
    private let noFlags: UInt64 = 0

    func testRightOptionTapFiresGoogleText() {
        let m = machine()
        var agentText = 0, googleText = 0
        m.configure(
            onSnapshot: { _ in }, onTap: { agentText += 1 }, onVoiceTap: {},
            onHoldStart: {}, onHoldEnd: {}, onCancel: {},
            onScheduleThreshold: {}, onCancelThreshold: {},
            onGoogleTextTap: { googleText += 1 }, onGoogleVoiceTap: {},
            onGoogleHoldStart: {}, onGoogleHoldEnd: {}, onGoogleCancel: {}
        )
        _ = m.handle(.flagsChanged(rawFlags: rightOptionFlags)) // press R-Option
        _ = m.handle(.flagsChanged(rawFlags: noFlags))          // release < threshold
        XCTAssertEqual(googleText, 1)
        XCTAssertEqual(agentText, 0)
    }

    func testRightOptionHoldFiresGoogleVoice() {
        let m = machine()
        var holdStart = 0, holdEnd = 0
        var agentHoldStart = 0, agentHoldEnd = 0
        m.configure(
            onSnapshot: { _ in }, onTap: {}, onVoiceTap: {},
            onHoldStart: { agentHoldStart += 1 }, onHoldEnd: { agentHoldEnd += 1 },
            onCancel: {},
            onScheduleThreshold: {}, onCancelThreshold: {},
            onGoogleTextTap: {}, onGoogleVoiceTap: {},
            onGoogleHoldStart: { holdStart += 1 }, onGoogleHoldEnd: { holdEnd += 1 },
            onGoogleCancel: {}
        )
        _ = m.handle(.flagsChanged(rawFlags: rightOptionFlags)) // press R-Option
        _ = m.handle(.thresholdElapsed)                         // grace armed (Variant A)
        _ = m.handle(.googleGraceElapsed)                       // no veto → hold starts
        _ = m.handle(.flagsChanged(rawFlags: noFlags))          // release
        XCTAssertEqual(holdStart, 1)
        XCTAssertEqual(holdEnd, 1)
        XCTAssertEqual(agentHoldStart, 0)
        XCTAssertEqual(agentHoldEnd, 0)
    }

    // ANSI 'M' — the character in the default ⌥M Meeting-record combo. Distinct
    // from Escape (53), so a keyDown carrying it is a plain non-modifier press.
    private let mKeyCode: Int64 = 46

    /// BUG-1 FIX (Variant A, founder-approved 2026-07-06): a Google hold no
    /// longer starts the instant the 200 ms threshold elapses — it parks in a
    /// short grace window first. The default ⌥M meeting toggle rides the SAME
    /// right Option, so an M landing in that window used to flash the Google
    /// recording UI (`onGoogleHoldStart` → `onGoogleCancel`) before the
    /// meeting toggled. Now the keypress vetoes the start SILENTLY: no start,
    /// no cancel, nothing for the island to flash. Meeting toggle itself rides
    /// the independent Carbon ⌥M registration (not modelled here).
    ///
    /// NB: only reproduces for users who explicitly enabled Google voice
    /// search (capability默 default OFF, gated in AppDelegate).
    func test_rightOptionHold_then_M_never_starts_google() {
        let m = machine()
        var googleHoldStart = 0, googleHoldEnd = 0, googleCancel = 0
        var graceScheduled = 0, graceCancelled = 0
        m.configure(
            onSnapshot: { _ in }, onTap: {}, onVoiceTap: {},
            onHoldStart: {}, onHoldEnd: {}, onCancel: {},
            onScheduleThreshold: {}, onCancelThreshold: {},
            onGoogleTextTap: {}, onGoogleVoiceTap: {},
            onGoogleHoldStart: { googleHoldStart += 1 },
            onGoogleHoldEnd: { googleHoldEnd += 1 },
            onGoogleCancel: { googleCancel += 1 },
            onScheduleGoogleGrace: { graceScheduled += 1 },
            onCancelGoogleGrace: { graceCancelled += 1 }
        )

        _ = m.handle(.flagsChanged(rawFlags: rightOptionFlags)) // hold R-Option
        _ = m.handle(.thresholdElapsed)                         // 200 ms elapsed

        // The start is PARKED in the grace window — nothing fired yet.
        XCTAssertEqual(googleHoldStart, 0, "threshold parks the Google start in the grace window")
        XCTAssertEqual(graceScheduled, 1)
        XCTAssertEqual(m.state, .googleGraceWaiting)

        // The user presses M (still holding R-Option) inside the window.
        _ = m.handle(.keyDown(keyCode: mKeyCode, rawFlags: rightOptionFlags))

        // Silent veto: no start, no cancel — the island never flashes.
        XCTAssertEqual(googleHoldStart, 0, "M inside the grace window vetoes the Google start")
        XCTAssertEqual(googleCancel, 0, "nothing started, so nothing to cancel")
        XCTAssertEqual(googleHoldEnd, 0)
        XCTAssertEqual(graceCancelled, 1)
        XCTAssertEqual(m.state, .cancelledWaitingForRelease)
    }

    /// A legit Google hold (no combo key) still starts — one grace tick later.
    func test_google_hold_starts_after_grace_elapses_and_ends_on_release() {
        let m = machine()
        var googleHoldStart = 0, googleHoldEnd = 0, googleCancel = 0
        m.configure(
            onSnapshot: { _ in }, onTap: {}, onVoiceTap: {},
            onHoldStart: {}, onHoldEnd: {}, onCancel: {},
            onScheduleThreshold: {}, onCancelThreshold: {},
            onGoogleTextTap: {}, onGoogleVoiceTap: {},
            onGoogleHoldStart: { googleHoldStart += 1 },
            onGoogleHoldEnd: { googleHoldEnd += 1 },
            onGoogleCancel: { googleCancel += 1 }
        )

        _ = m.handle(.flagsChanged(rawFlags: rightOptionFlags))
        _ = m.handle(.thresholdElapsed)
        XCTAssertEqual(googleHoldStart, 0)
        _ = m.handle(.googleGraceElapsed)
        XCTAssertEqual(googleHoldStart, 1, "grace elapsed with no veto → recording starts")
        XCTAssertEqual(m.state, .holding)

        _ = m.handle(.flagsChanged(rawFlags: 0)) // release
        XCTAssertEqual(googleHoldEnd, 1)
        XCTAssertEqual(googleCancel, 0)
        XCTAssertEqual(m.state, .idle)
    }

    /// Releasing R⌥ inside the grace window ends the gesture silently — the
    /// sub-grace hold never started, so no start/end/cancel ever fire.
    func test_release_inside_grace_window_is_silent() {
        let m = machine()
        var googleHoldStart = 0, googleHoldEnd = 0, googleCancel = 0
        var graceCancelled = 0
        m.configure(
            onSnapshot: { _ in }, onTap: {}, onVoiceTap: {},
            onHoldStart: {}, onHoldEnd: {}, onCancel: {},
            onScheduleThreshold: {}, onCancelThreshold: {},
            onGoogleTextTap: {}, onGoogleVoiceTap: {},
            onGoogleHoldStart: { googleHoldStart += 1 },
            onGoogleHoldEnd: { googleHoldEnd += 1 },
            onGoogleCancel: { googleCancel += 1 },
            onScheduleGoogleGrace: {},
            onCancelGoogleGrace: { graceCancelled += 1 }
        )

        _ = m.handle(.flagsChanged(rawFlags: rightOptionFlags))
        _ = m.handle(.thresholdElapsed)
        _ = m.handle(.flagsChanged(rawFlags: 0)) // release inside the window

        XCTAssertEqual(googleHoldStart, 0)
        XCTAssertEqual(googleHoldEnd, 0)
        XCTAssertEqual(googleCancel, 0)
        XCTAssertEqual(graceCancelled, 1)
        XCTAssertEqual(m.state, .idle)
    }

    /// Agent voice hold (R⌘) is untouched by the grace: threshold still fires
    /// the hold-start immediately — the veto is scoped to the Google action.
    func test_agent_hold_still_starts_immediately_at_threshold() {
        let m = machine()
        var agentHoldStart = 0, googleHoldStart = 0
        m.configure(
            onSnapshot: { _ in }, onTap: {}, onVoiceTap: {},
            onHoldStart: { agentHoldStart += 1 }, onHoldEnd: {}, onCancel: {},
            onScheduleThreshold: {}, onCancelThreshold: {},
            onGoogleTextTap: {}, onGoogleVoiceTap: {},
            onGoogleHoldStart: { googleHoldStart += 1 },
            onGoogleHoldEnd: {}, onGoogleCancel: {}
        )

        _ = m.handle(.flagsChanged(rawFlags: rightCommandFlags))
        _ = m.handle(.thresholdElapsed)

        XCTAssertEqual(agentHoldStart, 1, "R⌘ agent hold is not grace-parked")
        XCTAssertEqual(googleHoldStart, 0)
        XCTAssertEqual(m.state, .holding)
    }
}
