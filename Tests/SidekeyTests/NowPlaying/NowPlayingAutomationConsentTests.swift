import Carbon
import Foundation
import XCTest
@testable import Sidekey

/// Unit tests for the per-app Automation-consent gate's caching/decision
/// logic. The real `AEDeterminePermissionToAutomateTarget` call is
/// on-device-only (it can present the system Automation prompt), so these
/// tests inject a FAKE status function and assert the gate's external
/// behaviour:
///
/// - undetermined (`errAEEventWouldRequireUserConsent`) → asks exactly once
///   (one `ask: true` call), then caches the outcome.
/// - granted (`noErr`) → reports granted, never asks again.
/// - denied (`errAEEventNotPermitted`) → reports denied, never re-prompts
///   (no further `ask: true`), but cheaply re-checks with `ask: false`.
/// - denied → granted: a later grant is picked up via the `ask: false`
///   re-check without ever prompting again.
final class NowPlayingAutomationConsentTests: XCTestCase {

    // The Carbon result constants are typed `Int`; the gate works in
    // `OSStatus` (`Int32`). Re-expose them as `OSStatus` so the response
    // arrays type-check.
    private let undetermined = OSStatus(errAEEventWouldRequireUserConsent)
    private let denied = OSStatus(errAEEventNotPermitted)
    private let notRunning = OSStatus(procNotFound)
    private let granted = noErr // already OSStatus


    /// Records every (bundleId, ask) the gate made against the fake, so the
    /// tests can assert the prompt was presented exactly once and never
    /// re-presented after a decision.
    private final class StatusRecorder {
        private(set) var calls: [(bundleID: String, ask: Bool)] = []
        /// Programmable response queue per call; if exhausted, returns the
        /// last response (so a stable terminal state can be modelled).
        var responses: [OSStatus]
        private var index = 0

        init(responses: [OSStatus]) { self.responses = responses }

        func status(_ bundleID: String, _ ask: Bool) -> OSStatus {
            calls.append((bundleID, ask))
            let value = responses[min(index, responses.count - 1)]
            index += 1
            return value
        }

        var askTrueCount: Int { calls.filter { $0.ask }.count }
    }

    private let music = NowPlayingApp.music

    func test_undetermined_asksOnce_thenGranted_isCachedWithoutReasking() {
        // First poll: status is "not yet determined" with ask:false, so the
        // gate must present the prompt once (ask:true) — and the user grants.
        // Subsequent polls must NOT call the status function again at all.
        let recorder = StatusRecorder(responses: [
            undetermined, // initial ask:false probe
            granted       // the single ask:true prompt → granted
        ])
        let gate = NowPlayingAutomationConsent(status: recorder.status)

        XCTAssertTrue(gate.ensureConsent(for: music), "grant after the prompt → allowed")
        XCTAssertEqual(recorder.askTrueCount, 1, "exactly one interactive prompt")

        // Second/third poll: cached granted → no further status calls.
        let callsAfterFirst = recorder.calls.count
        XCTAssertTrue(gate.ensureConsent(for: music))
        XCTAssertTrue(gate.ensureConsent(for: music))
        XCTAssertEqual(
            recorder.calls.count, callsAfterFirst,
            "a cached grant must not re-query the status function"
        )
    }

    func test_undetermined_userDenies_thenNoReprompt_butRechecksWithAskFalse() {
        // The user denies at the prompt. The gate must report denied and
        // NEVER prompt again (no second ask:true), but it MAY cheaply
        // re-check with ask:false so a later grant in System Settings is
        // picked up without a prompt.
        let recorder = StatusRecorder(responses: [
            undetermined, // ask:false probe
            denied,       // ask:true prompt → denied
            denied        // subsequent ask:false re-checks stay denied
        ])
        let gate = NowPlayingAutomationConsent(status: recorder.status)

        XCTAssertFalse(gate.ensureConsent(for: music), "denied at prompt → skipped")
        XCTAssertEqual(recorder.askTrueCount, 1, "the denial prompt was shown once")

        XCTAssertFalse(gate.ensureConsent(for: music))
        XCTAssertFalse(gate.ensureConsent(for: music))
        XCTAssertEqual(
            recorder.askTrueCount, 1,
            "a denied app must never be re-prompted (no further ask:true)"
        )
        // It did keep cheaply re-checking with ask:false.
        XCTAssertGreaterThan(
            recorder.calls.filter { !$0.ask }.count, 1,
            "denied state is cheaply re-probed with ask:false to catch a later grant"
        )
    }

    func test_denied_thenLaterGranted_isPickedUpViaAskFalseRecheck() {
        // After a denial, the user flips the toggle in System Settings →
        // Automation. The next ask:false re-check returns noErr, and the
        // gate must start allowing reads — WITHOUT ever prompting again.
        let recorder = StatusRecorder(responses: [
            undetermined, // ask:false probe
            denied,       // ask:true prompt → denied
            granted       // later ask:false re-check → now granted
        ])
        let gate = NowPlayingAutomationConsent(status: recorder.status)

        XCTAssertFalse(gate.ensureConsent(for: music))
        XCTAssertTrue(
            gate.ensureConsent(for: music),
            "a grant made later in System Settings is picked up via ask:false"
        )
        XCTAssertEqual(
            recorder.askTrueCount, 1,
            "the grant transition must not trigger another prompt"
        )
    }

    func test_alreadyGranted_onFirstProbe_readsWithoutPrompting() {
        // If the system already reports granted on the initial ask:false
        // probe (consent previously determined), the gate allows reads and
        // never prompts.
        let recorder = StatusRecorder(responses: [granted])
        let gate = NowPlayingAutomationConsent(status: recorder.status)

        XCTAssertTrue(gate.ensureConsent(for: music))
        XCTAssertEqual(recorder.askTrueCount, 0, "an already-granted app is never prompted")
    }

    func test_targetNotRunning_staysUndetermined_andRetriesOnNextPoll() {
        // procNotFound (-600) = the target app is not running. The gate must
        // NOT cache this as a terminal decision: once the app launches and
        // consent is grantable, a later poll should still be able to prompt.
        let recorder = StatusRecorder(responses: [
            notRunning,   // app not running yet
            undetermined, // app now running, ask:false probe
            granted       // ask:true prompt → granted
        ])
        let gate = NowPlayingAutomationConsent(status: recorder.status)

        XCTAssertFalse(gate.ensureConsent(for: music), "not running → cannot read this poll")
        XCTAssertEqual(recorder.askTrueCount, 0, "no prompt while the app is not running")

        XCTAssertTrue(
            gate.ensureConsent(for: music),
            "once running and consent grantable, the gate prompts and allows reads"
        )
        XCTAssertEqual(recorder.askTrueCount, 1)
    }
}
