import CoreAudio
import Foundation
import os.log

/// Process-level audio activity probe — answers "is any browser currently
/// recording from the microphone?".
///
/// Rationale (per Maxim's observation 2026-05-19): browsers do not casually
/// claim the microphone. If Chrome/Safari/Arc/Dia/Edge/Brave/Firefox has the
/// input stream open right now, the user is overwhelmingly in a web meeting
/// (Google Meet, Zoom web client, Teams web, Telemost, Kontur Talk, Whereby,
/// Discord web, Slack huddle web, etc.). Same signal Notion uses to detect
/// browser-based meetings — explains both its accurate hits AND its known
/// false positives (Google Search voice query, OpenAI Playground STT, etc.).
///
/// Public API since macOS 13 (Ventura): `kAudioHardwarePropertyProcessObjectList`
/// enumerates running audio process objects; per-process properties expose
/// bundle ID and "is currently recording input" state.
///
/// Acceptable false-positive surface: voice search, web-based STT testing,
/// browser voice messages. Acceptable because:
///   1. Same FPs Notion has — industry-standard trade-off
///   2. User can dismiss pill in 1 second
///   3. Native dictation tools (Sidekey itself, macOS dictation) are NOT
///      browsers / WebKit media helpers — process bundle ID never matches
///      the browser allow-list.
///
/// **Threading:** deliberately NOT `@MainActor`. Every property read here is
/// a synchronous Mach IPC to `coreaudiod`; a full scan is ~50 processes × 2
/// round-trips (measured 6–25 ms at rest, unbounded while coreaudiod is busy
/// bringing up a meeting's devices / switching Bluetooth profiles). Callers
/// must keep these scans OFF the main thread or the UI freezes exactly when
/// the meeting nudge is on screen.
struct AudioProcessProbe {
    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "audio-process")

    /// Browsers and browser media-helper namespaces whose mic activity
    /// counts as a meeting signal. Starts with
    /// `FrontmostAppDetector.browserURLScripts` keys + Firefox (which lacks
    /// AppleScript URL probe but still has detectable mic usage), plus
    /// WebKit's shared helper namespace: modern Safari/WebKit WebRTC capture
    /// can surface to CoreAudio as `com.apple.WebKit.GPU` instead of
    /// `com.apple.Safari`.
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.apple.WebKit",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
        "company.thebrowser.dia",      // Dia
        "org.mozilla.firefox",
    ]

    /// Returns the bundle IDs of every audio process whose input stream is
    /// currently active. Empty when nothing is recording. Best-effort; CoreAudio
    /// permission / OS-version variance returns an empty array rather than
    /// throwing — caller treats "unknown" as "no signal".
    func bundleIDsCurrentlyRecording() -> Set<String> {
        let processes = audioProcessObjectIDs()
        var recording = Set<String>()
        for processObject in processes {
            guard isProcessRecordingInput(processObject) else { continue }
            guard let bid = bundleID(for: processObject) else { continue }
            recording.insert(bid)
        }
        return recording
    }

    /// True if any of the listed browser bundle IDs (or a helper subprocess
    /// of one) has an active input stream. Browsers use multi-process
    /// architecture — the actual mic-recording subprocess often reports
    /// a bundle ID like `com.google.Chrome.helper` /
    /// `com.google.Chrome.helper.Renderer` /
    /// `company.thebrowser.browser.helper` (Arc + Dia shared helper) /
    /// `com.apple.WebKit.GPU` (Safari/WebKit media capture).
    /// Match exact OR `<browser_bid>.` prefix, case-insensitive.
    func isAnyBrowserRecording() -> Bool {
        let recording = bundleIDsCurrentlyRecording()
        for recordingBID in recording {
            if Self.matchesAnyBrowserBundle(recordingBID) {
                os_log(
                    "browser currently recording mic (bundle: %{public}@)",
                    log: Self.log, type: .info, recordingBID
                )
                return true
            }
        }
        return false
    }

    /// Case-insensitive exact OR `<bid>.` prefix match against the
    /// browser allow-list. Plus a catch-all for The Browser Company's
    /// shared helper namespace (`company.thebrowser.browser.helper`)
    /// which Arc and Dia both spawn for tab subprocesses.
    static func matchesAnyBrowserBundle(_ recordingBID: String) -> Bool {
        let needle = recordingBID.lowercased()
        for browserBID in browserBundleIDs {
            let hay = browserBID.lowercased()
            if needle == hay { return true }
            if needle.hasPrefix(hay + ".") { return true }
        }
        // Arc and Dia (and any future Browser Company product) share the
        // same `company.thebrowser.browser.helper` subprocess identifier
        // when a tab claims media. Treat anything in that namespace as a
        // browser.
        if needle.hasPrefix("company.thebrowser.") && needle.contains(".browser.helper") {
            return true
        }
        return false
    }

    // MARK: - CoreAudio HAL helpers

    private func audioProcessObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
        )
        guard status == noErr else { return [] }
        return objects
    }

    private func isProcessRecordingInput(_ processObject: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            processObject, &address, 0, nil, &size, &isRunning
        )
        guard status == noErr else { return false }
        return isRunning != 0
    }

    private func bundleID(for processObject: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = UInt32(MemoryLayout<CFString?>.size)
        var bundleID: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &bundleID) { ptr in
            AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let s = bundleID as String
        return s.isEmpty ? nil : s
    }
}
