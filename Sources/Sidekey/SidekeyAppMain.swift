import AppKit

/// The one public entry point of the app library. The executable target
/// (`Sources/SidekeyApp`) is a thin shim whose whole job is to hand off here.
public enum SidekeyAppMain {
    @MainActor
    public static func run() {
        AppDelegate.main()
    }
}
