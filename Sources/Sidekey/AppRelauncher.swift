import AppKit

/// Quits Whytap and opens it again once this process is gone. macOS 27.3
/// applies a keyboard control, Input Monitoring or Screen Recording grant
/// made in System Settings only to a new process; the onboarding keeps its
/// step across the quit (OnboardingLaunch), so the reopened app continues there.
// WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
enum AppRelauncher {
    /// The shell waits up to a minute for this process to end, then opens the
    /// bundle; if the quit was cancelled it opens nothing. The PID and path
    /// are arguments, never part of the script text.
    static let script = """
        i=0
        while /bin/kill -0 "$1" 2>/dev/null && [ "$i" -lt 300 ]; do /bin/sleep 0.2; i=$((i+1)); done
        /bin/kill -0 "$1" 2>/dev/null || /usr/bin/open "$2"
        """

    static func arguments(pid: Int32, bundlePath: String) -> [String] {
        ["-c", script, "whytap-relaunch", String(pid), bundlePath]
    }

    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(pid: ProcessInfo.processInfo.processIdentifier,
                                      bundlePath: Bundle.main.bundlePath)
        do { try process.run() } catch { return }
        NSApp.terminate(nil)
    }
}
