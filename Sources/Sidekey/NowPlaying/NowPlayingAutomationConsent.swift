import AppKit
import Carbon
import Foundation
import os.log

/// Queries (and, the first time, requests) macOS **Automation** consent for
/// sending Apple Events to a target media app.
///
/// **Why this exists (the on-device bug it fixes):** the read path drives
/// `NSAppleScript` on a background thread, which relies on macOS's *implicit*
/// Apple-Events consent. A raw background Apple-Event send does NOT trigger
/// the Automation (TCC) consent prompt and does NOT register the app under
/// System Settings → Privacy & Security → Automation. The send just fails
/// with `errAEEventNotPermitted (-1743)` forever, the user never sees a
/// prompt, and no track ever appears. The sanctioned way to (a) trigger the
/// prompt and (b) read status is `AEDeterminePermissionToAutomateTarget`,
/// which this type wraps.
///
/// A closure-injected `status` function (`(bundleId, askUserIfNeeded) ->
/// OSStatus`) defaults to the real `AEDeterminePermissionToAutomateTarget`
/// call; tests inject a fake to exercise the per-app caching/decision logic
/// without a real player or a real (blocking, on-device) consent prompt.
///
/// **Threading:** intended to be driven from the source's background
/// `scriptQueue`. The interactive `ask: true` call BLOCKS while the user
/// decides — that is fine off-main, and it must NOT be wrapped in the read
/// path's 2 s timeout (a user can take longer than 2 s). See
/// `AppleScriptNowPlayingSource`.
final class NowPlayingAutomationConsent: @unchecked Sendable {

    /// `(bundleId, askUserIfNeeded) -> OSStatus`. The real implementation
    /// calls `AEDeterminePermissionToAutomateTarget`; tests inject a fake.
    typealias StatusFunction = (_ bundleID: String, _ askUserIfNeeded: Bool) -> OSStatus

    private static let log = OSLog(subsystem: "com.sidekey.nowplaying", category: "automation-consent")

    /// Terminal per-app decision we cache so we never re-prompt. A `nil`
    /// cache entry (the default) means "not yet decided" — we still probe.
    private enum Decision {
        case granted
        case denied
    }

    private let status: StatusFunction
    private let lock = NSLock()
    private var decisions: [String: Decision] = [:]

    init(status: @escaping StatusFunction = NowPlayingAutomationConsent.realStatus) {
        self.status = status
    }

    /// Ensure Automation consent for `app`, prompting at most once.
    ///
    /// Returns `true` when reads may proceed (consent granted), `false` when
    /// they must be skipped this poll (denied, app not running, or consent
    /// still pending after a refused prompt).
    ///
    /// Decision flow (idempotent across polls):
    /// - cached `granted` → `true`, no system call.
    /// - cached `denied` → cheaply re-probe with `ask: false`; if the user
    ///   has since granted in System Settings, flip to granted (`true`);
    ///   otherwise stay denied (`false`). **Never** re-prompts.
    /// - undecided → probe with `ask: false`:
    ///   - `noErr` → cache granted, `true`.
    ///   - `errAEEventNotPermitted` → cache denied, `false` (already
    ///     determined-denied; prompting again would be a no-op).
    ///   - `errAEEventWouldRequireUserConsent` → present the prompt once with
    ///     `ask: true` (blocks); cache+return its outcome (`noErr` → granted,
    ///     anything else → denied).
    ///   - `procNotFound` (app not running) → do NOT cache; `false` and retry
    ///     on a later poll once the app is up.
    func ensureConsent(for app: NowPlayingApp) -> Bool {
        let bundleID = app.bundleIdentifier

        lock.lock()
        let cached = decisions[bundleID]
        lock.unlock()

        switch cached {
        case .granted:
            return true
        case .denied:
            // Cheap, non-prompting re-check so a later grant in System
            // Settings is picked up without ever showing another prompt.
            if status(bundleID, false) == OSStatus(noErr) {
                store(.granted, for: bundleID)
                return true
            }
            return false
        case nil:
            return resolveUndecided(bundleID)
        }
    }

    private func resolveUndecided(_ bundleID: String) -> Bool {
        let probe = status(bundleID, false)
        switch probe {
        case OSStatus(noErr):
            store(.granted, for: bundleID)
            return true
        case OSStatus(errAEEventNotPermitted):
            store(.denied, for: bundleID)
            return false
        case OSStatus(errAEEventWouldRequireUserConsent):
            // Present the system Automation prompt exactly once. This BLOCKS
            // until the user decides — caller guarantees we are off-main and
            // not under the read timeout.
            let answer = status(bundleID, true)
            let granted = (answer == OSStatus(noErr))
            store(granted ? .granted : .denied, for: bundleID)
            return granted
        case OSStatus(procNotFound):
            // App not running yet — not a decision. Leave uncached so the
            // next poll (once the app is up) can prompt.
            return false
        default:
            os_log(
                "automation consent probe returned %{public}d for %{public}@",
                log: Self.log, type: .debug, probe, bundleID
            )
            return false
        }
    }

    /// Non-prompting status check for UI (e.g. the Settings row): `true`
    /// only when consent is already granted. Never presents a prompt.
    func isGranted(for app: NowPlayingApp) -> Bool {
        status(app.bundleIdentifier, false) == OSStatus(noErr)
    }

    private func store(_ decision: Decision, for bundleID: String) {
        lock.lock()
        decisions[bundleID] = decision
        lock.unlock()
    }

    // MARK: - Real backend

    /// The production `status` function: builds an Apple-Event address
    /// descriptor from the bundle id and asks the system for Automation
    /// permission via `AEDeterminePermissionToAutomateTarget` with a
    /// wildcard event class/id. `aeDesc` is valid only while `target` is
    /// alive, so the call happens inside this scope.
    static let realStatus: StatusFunction = { bundleID, askUserIfNeeded in
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return OSStatus(paramErr) }
        // `desc` points into `target`'s internal storage and is valid only
        // while `target` is alive. Keep `target` alive across the call so ARC
        // cannot release it before `AEDeterminePermissionToAutomateTarget`
        // dereferences `desc` (use-after-free in optimized builds).
        return withExtendedLifetime(target) {
            AEDeterminePermissionToAutomateTarget(
                desc,
                OSType(typeWildCard),
                OSType(typeWildCard),
                askUserIfNeeded
            )
        }
    }
}
