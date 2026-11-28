import AppKit

/// The one public entry point of the app library. The executable target
/// (`Sources/SidekeyApp`) is a thin shim whose whole job is to hand off here.
public enum SidekeyAppMain {
    @MainActor
    public static func run() {
        if CommandLine.arguments.contains("--installation-check") {
            let valid = InstallationGuard.installationCheck()
            print(valid ? "installation-check: ok" : "installation-check: missing packaged resources")
            exit(valid ? 0 : 1)
        }
        // Headless, with Whytap quit: the build queue's restore points around
        // previews. WHY: .project-docs/decisions/2026-11-26-preview-restore-points.md
        if PreviewRestorePoints.runCommandLine(CommandLine.arguments) { return }
        guard InstallationGuard.canLaunch() else { return }
        // Freeze the review deadline at startup, not a later first Calendar click.
        _ = GoogleCalendarReviewSession.current
        guard ApplicationInstanceCoordinator.shared.canLaunch() else { return }
        // Restore before stores open or jobs start; a completed rollback can
        // safely continue, while an unfinished transaction keeps its originals.
        guard ArtifactBackupStartup.finishPendingRestore() else { return }
        AIUsageRecorder.enable()
        AppDelegate.main()
    }
}
