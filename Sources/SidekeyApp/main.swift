import Sidekey

// Top-level code runs on the process main thread; assumeIsolated bridges
// it into the app's @MainActor entry under the package's v5 language mode.
MainActor.assumeIsolated {
    SidekeyAppMain.run()
}
