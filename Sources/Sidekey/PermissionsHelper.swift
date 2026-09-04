import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

enum PermissionsHelper {
    struct Snapshot: Equatable {
        let accessibilityGranted: Bool
        let microphoneStatus: AVAuthorizationStatus

        var microphoneGranted: Bool {
            microphoneStatus == .authorized
        }

        var allRequiredGranted: Bool {
            accessibilityGranted && microphoneGranted
        }
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            accessibilityGranted: accessibilityGranted(prompt: false),
            microphoneStatus: microphoneStatus()
        )
    }

    static func allRequiredPermissionsGranted() -> Bool {
        snapshot().allRequiredGranted
    }

    /// Returns whether this process is trusted for Accessibility. The
    /// Accessibility grant gates both `NSEvent.addGlobalMonitorForEvents`
    /// (the R-Cmd agent gesture) and the drop hotkey's active
    /// `CGEventTap` in `SpaceHoldMonitor`. Input Monitoring is only a
    /// lazy fallback — requested once if the tap fails to create while
    /// Accessibility is granted; it is NOT required on verified macOS
    /// versions (empirical: IM list empty, drop works). When `prompt` is
    /// `true`, macOS surfaces the standard "open System Settings" dialog
    /// the first time the call is made.
    static func accessibilityGranted(prompt: Bool) -> Bool {
        guard prompt else {
            return AXIsProcessTrusted()
        }
        if AXIsProcessTrusted() {
            return true
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let granted = accessibilityGranted(prompt: true)
        if !granted {
            openAccessibilitySettings()
        }
        return granted
    }

    /// Whether this process is allowed to post synthesised keyboard events
    /// (`CGEvent.post(tap: .cghidEventTap)`, used for the Cmd+V paste step
    /// after the transcript returns).
    ///
    /// On macOS 10.15+ this is a SEPARATE TCC bucket from Accessibility —
    /// granting Accessibility alone is not enough; the user must also
    /// approve Post Event. The system surfaces a single prompt when
    /// `prompt` is `true` and the permission has never been answered. On
    /// older macOS (which we don't actually support — `LSMinimumSystemVersion`
    /// is 15.0), we fall back to Accessibility so the API contract stays
    /// usable.
    static func postEventAccessGranted(prompt: Bool) -> Bool {
        if #available(macOS 10.15, *) {
            if CGPreflightPostEventAccess() { return true }
            return prompt ? CGRequestPostEventAccess() : false
        }
        return accessibilityGranted(prompt: prompt)
    }

    /// Whether this process is allowed to *observe* the global keystroke
    /// stream through an active `CGEventTap` (`.defaultTap`) — the
    /// **Input Monitoring** TCC bucket. Gates `SpaceHoldMonitor`, which
    /// watches for a Space *hold* to trigger Drop.
    ///
    /// This is the Bool mirror of `postEventAccessGranted`, using the
    /// CoreGraphics listen-access pair (`CGPreflightListenEventAccess()` /
    /// `CGRequestListenEventAccess()`) rather than IOKit/IOHID. The system
    /// surfaces a single prompt when `prompt` is `true` and the permission
    /// has never been answered.
    ///
    /// Historically Sidekey deliberately avoided this bucket (Carbon
    /// `RegisterEventHotKey` + Post Event covered both hotkey and paste
    /// paths); the Space-hold Drop trigger requires an active tap, so the
    /// invariant now admits Input Monitoring (see `CLAUDE.md`). On macOS
    /// older than 10.15 (which we don't support — `LSMinimumSystemVersion`
    /// is 14.2) we fall back to Accessibility so the API contract stays
    /// usable.
    static func inputMonitoringGranted(prompt: Bool) -> Bool {
        if #available(macOS 10.15, *) {
            if CGPreflightListenEventAccess() { return true }
            return prompt ? CGRequestListenEventAccess() : false
        }
        return accessibilityGranted(prompt: prompt)
    }

    /// Current microphone-permission status without triggering a prompt.
    static func microphoneStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Triggers the microphone-permission prompt if the status is undetermined.
    /// No-op (returns current grant) for already-decided statuses.
    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Opens the Privacy & Security → Accessibility pane of System Settings.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Opens the Privacy & Security → Microphone pane of System Settings.
    /// Used when `requestMicrophone()` would silently no-op because the user
    /// has previously denied access (macOS only surfaces the native prompt
    /// while status is `.notDetermined`). Returning to that pane lets the
    /// user flip the toggle without leaving Sidekey.
    static func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Whether the System Audio Recording (TCC `AudioCapture`) permission is
    /// known to be USABLE for opening a CoreAudio process tap.
    ///
    /// macOS exposes **no API** to read this bucket's status, and surfaces
    /// its prompt exactly once — the first time the process creates a
    /// process tap (`AudioHardwareCreateProcessTap`). So there is nothing to
    /// preflight: creating the tap IS the request-if-undetermined, and a
    /// previously-denied grant is indistinguishable at runtime from silence
    /// (the tap starts without error and yields zero buffers forever). The
    /// contract therefore always returns `true` — "go ahead and create the
    /// tap"; callers that get only zero samples must fall back gracefully
    /// (the music wing drops to its sleep idle). Meeting Notes already
    /// relies on the same implicit-prompt behaviour.
    static func systemAudioRecordingUsable() -> Bool {
        true
    }

    /// Opens the Privacy & Security → Automation pane of System Settings.
    /// Used by the Now Playing settings tab so a user who denied Apple Events
    /// control of Music / Spotify can re-grant it. Automation grant is not
    /// readable without prompting, so the tab only deep-links here rather than
    /// showing a live status.
    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Reveals the currently-running app bundle so a dev build can be
    /// manually added via the `+` button in Privacy & Security panes.
    static func revealCurrentAppBundle() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
