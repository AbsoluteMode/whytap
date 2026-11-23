import AppKit

/// Quits Whytap and opens it again. macOS 27.3 applies a keyboard control,
/// Input Monitoring or Screen Recording grant made in System Settings only to
/// a new process; the onboarding keeps its step across the quit
/// (OnboardingLaunch), so the reopened app continues there.
///
/// The same activity rules as an update restart apply: nothing quits during
/// a meeting recording, dictation, a screenshot and the rest
/// (UpdateController.restartDeferralReason). The helper that reopens the app
/// starts before the quit; if it cannot start, Whytap stays open and says so
/// (the person quits and opens it by hand). A quit that returns was
/// cancelled: the helper is stopped, so a later ordinary Quit never reopens
/// Whytap.
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

    /// Shown when the reopen helper cannot start: nothing quits.
    static let helperFailed = "Whytap couldn’t restart itself. Quit Whytap and open it again."

    /// A restart quit is under way (between the helper's start and the quit).
    private(set) static var restartAccepted = false

    /// Starts the reopen helper; returns how to stop it if the quit is cancelled.
    typealias HelperStarter = (_ pid: Int32, _ bundlePath: String) throws -> () -> Void

    /// Restarts now, or returns why not (the activity to finish first, or a
    /// helper that could not start).
    @discardableResult
    static func relaunch(appState: AppState? = .shared,
                         startHelper: HelperStarter = AppRelauncher.startHelper,
                         terminate: () -> Void = { NSApp.terminate(nil) }) -> String? {
        if let reason = UpdateController.restartDeferralReason(appState) { return reason }
        let stopHelper: () -> Void
        do {
            stopHelper = try startHelper(ProcessInfo.processInfo.processIdentifier, Bundle.main.bundlePath)
        } catch {
            return helperFailed
        }
        restartAccepted = true
        terminate()
        // Reached only when the quit was cancelled: no reopen after a later Quit.
        restartAccepted = false
        stopHelper()
        return nil
    }

    static func startHelper(pid: Int32, bundlePath: String) throws -> () -> Void {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(pid: pid, bundlePath: bundlePath)
        try process.run()
        return { if process.isRunning { process.terminate() } }
    }
}
