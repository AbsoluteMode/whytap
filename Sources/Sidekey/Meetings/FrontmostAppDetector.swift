import AppKit
import Foundation
import os.log

/// Production helper that resolves frontmost-app bundle ID and, for known
/// browsers, the URL of the active tab via AppleScript.
///
/// PoC scope: used by `MeetingDetector` to fire immediately when the user is
/// in a known meeting app (Zoom/Teams/Slack/etc.) OR has a meeting URL open
/// in a browser tab (Google Meet, Zoom web client, Teams web, Telemost).
///
/// Both lookups are best-effort and synchronous; failures return `nil` and
/// the detector falls back to the mic-active duration path.
@MainActor
final class FrontmostAppDetector: FrontmostAppDetecting {
    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "frontmost")

    /// Native meeting-app bundle IDs. Per Maxim PoC decision 2026-05-19:
    /// keep only the three universal communications apps where the user
    /// reliably runs scheduled work meetings. Everything else (FaceTime,
    /// Discord, Telegram voice, Webex, Telemost native, Kontur native,
    /// any other voice/conference app) is covered via:
    ///   - the browser path when used in a web client (AudioProcessProbe
    ///     detects browser process recording mic — "Notion signal")
    ///   - never, when used as a native app outside this short list (kept
    ///     intentionally narrow to avoid false positives like Telegram
    ///     voice messages).
    static let meetingAppBundleIDs: Set<String> = [
        "us.zoom.xos",                  // Zoom
        "com.tinyspeck.slackmacgap",    // Slack
        "com.microsoft.teams2",         // Microsoft Teams (new client)
        "com.microsoft.teams",          // legacy Teams just in case
    ]

    /// Recognized browsers — used to gate AppleScript URL probe.
    /// Each entry maps bundle ID to an AppleScript snippet that returns
    /// the active-tab URL.
    static let browserURLScripts: [String: String] = [
        "com.google.Chrome":  "tell application \"Google Chrome\" to get URL of active tab of front window",
        "com.brave.Browser":  "tell application \"Brave Browser\" to get URL of active tab of front window",
        "com.microsoft.edgemac": "tell application \"Microsoft Edge\" to get URL of active tab of front window",
        "company.thebrowser.Browser": "tell application \"Arc\" to get URL of active tab of front window",
        "com.apple.Safari":   "tell application \"Safari\" to get URL of current tab of front window",
        "org.mozilla.firefox": "tell application \"Firefox\" to activate", // Firefox AppleScript is very limited; no reliable URL API. Treat as browser but URL probe returns nil.
    ]

    /// Substrings that, when found in the active-tab URL of a recognized
    /// browser, indicate a meeting page. Substring match keeps it tolerant
    /// to subdomains and path variations.
    static let meetingURLSubstrings: [String] = [
        "meet.google.com",
        ".zoom.us/j/",
        ".zoom.us/wc/",
        ".zoom.us/my/",
        "teams.microsoft.com",
        ".teams.live.com",
        "telemost.yandex.ru",
        "telemost.360.yandex.ru",
        "ktalk.ru",            // Kontur Talk (web)
        "talk.kontur.ru",      // Kontur Talk (alt domain)
        "kontur-talk.ru",      // Kontur Talk (alt domain)
        "whereby.com",
        "huddle01.com",
    ]

    /// Snapshot of frontmost app at call time. Returns `nil` when no app
    /// is frontmost (rare — Finder is the usual fallback) or the call
    /// runs off-main and AppKit balks.
    func currentFrontmostBundleID() -> String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// True when frontmost app is in the native meeting whitelist.
    func isMeetingAppFrontmost() -> Bool {
        guard let bid = currentFrontmostBundleID() else { return false }
        return Self.meetingAppBundleIDs.contains(bid)
    }

    /// True when **any** whitelisted meeting app is currently running
    /// (not necessarily frontmost). Combined with mic-in-use this catches
    /// the very common "Zoom call active in background while I work in
    /// a browser / Notion / Slack" scenario. Zoom etc. release the mic
    /// when the call ends, so a running meeting app + active mic is a
    /// strong "in a meeting" signal even without window focus.
    func isMeetingAppRunning() -> Bool {
        let runningBundleIDs = NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleIdentifier }
        for bid in runningBundleIDs where Self.meetingAppBundleIDs.contains(bid) {
            return true
        }
        return false
    }

    /// True when **any** recognized browser (even backgrounded) has a
    /// meeting URL in its active tab. We probe every known browser via
    /// AppleScript regardless of frontmost — catches "Meet/Telemost
    /// open in Chrome while I'm reading Slack/Dia". First-time the
    /// AppleScript runs per browser, macOS prompts for automation
    /// permission; subsequent runs are silent.
    func isMeetingURLOpenInBrowser() -> Bool {
        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        )
        for (bid, script) in Self.browserURLScripts where runningBundleIDs.contains(bid) {
            guard let url = runAppleScriptForURL(script, bid: bid) else { continue }
            for needle in Self.meetingURLSubstrings where url.contains(needle) {
                os_log(
                    "browser URL matches meeting substring (browser: %{public}@, needle: %{public}@)",
                    log: Self.log, type: .info,
                    bid, needle
                )
                return true
            }
        }
        return false
    }

    private func runAppleScriptForURL(_ source: String, bid: String) -> String? {
        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else { return nil }
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // Common: no windows open, automation permission denied, browser
            // does not expose active-tab URL via AppleScript (Firefox).
            // Log at debug to avoid noise; not actionable per tick.
            os_log(
                "AppleScript URL probe failed (browser: %{public}@): %{public}@",
                log: Self.log, type: .debug,
                bid, String(describing: errorInfo)
            )
            return nil
        }
        return result.stringValue
    }
}

/// Test seam so `MeetingDetector` can be exercised without AppKit /
/// AppleScript dependencies. Production injects `FrontmostAppDetector`;
/// unit tests inject a controllable stub.
@MainActor
protocol FrontmostAppDetecting {
    /// True when the currently-frontmost app indicates a meeting is
    /// happening — either a whitelisted native app or a browser with a
    /// meeting URL in the active tab.
    func isMeetingAppFrontmost() -> Bool
    func isMeetingURLOpenInBrowser() -> Bool
    /// True when any whitelisted meeting app is currently running
    /// (background-OK). Used so "Zoom call in another desktop / hidden
    /// window + mic active" still fires.
    func isMeetingAppRunning() -> Bool
}

extension FrontmostAppDetecting {
    /// Combined check used by the detector. True = trigger immediately.
    /// Single source of truth: process-level CoreAudio HAL — answers
    /// "which bundle is currently recording from the mic?".
    /// We fire only if that bundle is a meeting app (Zoom/Slack/Teams)
    /// or a browser (Meet/Telemost/Kontur/etc. via browser mic).
    /// Anything else recording mic (Sidekey dictation, Telegram voice
    /// message, macOS Speech-to-Text, etc.) is ignored — even if a
    /// meeting app happens to be running in the background.
    ///
    /// - Parameter scan: snapshot source for "who is recording right now".
    ///   Production default: the CoreAudio HAL process scan. Tests inject a
    ///   thread-observing / synthetic closure.
    func isInMeetingContext(
        scan: @escaping @Sendable () -> Set<String> = {
            AudioProcessProbe().bundleIDsCurrentlyRecording()
        }
    ) async -> Bool {
        // The detector's poll loop lives on the MainActor, so the HAL scan
        // (~50 synchronous Mach IPCs to coreaudiod, unbounded while a
        // meeting's audio devices are coming up) must hop off-main here or
        // it freezes clicks on the meeting nudge every 2s poll tick.
        // WHY: docs/decisions/2026-07-08-meeting-audio-hal-scan-off-main.md
        let recording = await Task.detached(priority: .utility) { scan() }.value
        guard !recording.isEmpty else { return false }
        for bid in recording {
            if FrontmostAppDetector.matchesAnyMeetingBundle(bid) { return true }
            if AudioProcessProbe.matchesAnyBrowserBundle(bid) { return true }
        }
        return false
    }
}

extension FrontmostAppDetector {
    /// Case-insensitive exact OR `<bid>.` prefix match against the
    /// meeting-app allow-list. Handles helper subprocesses that record
    /// the actual mic stream — e.g. Teams uses `com.microsoft.teams2.modulehost`,
    /// Zoom may spawn `us.zoom.xos.helper`, Slack `com.tinyspeck.slackmacgap.helper`.
    static func matchesAnyMeetingBundle(_ recordingBID: String) -> Bool {
        let needle = recordingBID.lowercased()
        for appBID in meetingAppBundleIDs {
            let hay = appBID.lowercased()
            if needle == hay { return true }
            if needle.hasPrefix(hay + ".") { return true }
        }
        return false
    }
}
