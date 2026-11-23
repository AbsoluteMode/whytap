import AppKit

/// Quits Whytap and opens it again. macOS 27.3 applies a keyboard control,
/// Input Monitoring or Screen Recording grant made in System Settings only to
/// a new process; the onboarding keeps its step across the quit
/// (OnboardingLaunch), so the reopened app continues there.
///
/// The same activity rules as an update restart apply: nothing quits during
/// a meeting recording, dictation, a screenshot and the rest
/// (UpdateController.restartDeferralReason). The helper that reopens the app
/// starts only in `applicationWillTerminate` of an accepted restart quit, so
/// a cancelled restart followed by an ordinary Quit never reopens Whytap.
// WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
@MainActor
enum AppRelauncher {
    /// The shell waits up to a minute for this process to end, then opens the
    /// bundle; if it is still running it opens nothing. The PID and path are
    /// arguments, never part of the script text.
    nonisolated static let script = """
        i=0
        while /bin/kill -0 "$1" 2>/dev/null && [ "$i" -lt 300 ]; do /bin/sleep 0.2; i=$((i+1)); done
        /bin/kill -0 "$1" 2>/dev/null || /usr/bin/open "$2"
        """

    nonisolated static func arguments(pid: Int32, bundlePath: String) -> [String] {
        ["-c", script, "whytap-relaunch", String(pid), bundlePath]
    }

    /// A restart quit is under way: `applicationWillTerminate` starts the helper.
    private(set) static var restartAccepted = false

    /// Restarts now, or returns why not (the activity to finish first).
    @discardableResult
    static func relaunch(appState: AppState? = .shared) -> String? {
        if let reason = UpdateController.restartDeferralReason(appState) { return reason }
        restartAccepted = true
        NSApp.terminate(nil)
        // Reached only when the quit was cancelled.
        restartAccepted = false
        return nil
    }

    /// From `applicationWillTerminate`: the quit is final; reopen after it.
    static func startHelperIfRestarting() {
        guard restartAccepted else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(pid: ProcessInfo.processInfo.processIdentifier,
                                      bundlePath: Bundle.main.bundlePath)
        try? process.run()
    }
}
