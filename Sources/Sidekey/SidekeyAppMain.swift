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
        guard InstallationGuard.canLaunch() else { return }
        AppDelegate.main()
    }
}
