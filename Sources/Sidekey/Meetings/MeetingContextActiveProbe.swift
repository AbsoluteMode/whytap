import Foundation
import os.log

/// Process-level "is the user currently in a meeting?" probe.
///
/// Polls `AudioProcessProbe.bundleIDsCurrentlyRecording()` every 2s and
/// emits `true` whenever **any** bundle in the recording set matches the
/// meeting-context allow-list (Zoom / Slack / Teams + their helper
/// subprocesses, OR a browser process / browser helper). Emits `false`
/// when no meeting-context bundle is recording.
///
/// ## Why this exists (vs. `MicInUseProbe`)
///
/// `MicInUseProbe` answers "is **any** input device running somewhere?".
/// That signal fires for Sidekey's own dictation, Telegram voice messages,
/// macOS Speech-to-Text, etc., and — critically — does NOT release on
/// meeting leave for apps that keep their mic stream open across calls:
///
/// - **Teams** keeps `com.microsoft.teams2.modulehost` claiming the
///   input device for quick rejoin / huddle pre-roll. Device-level
///   "is running somewhere" stays `true` for many seconds after the user
///   hits Leave. Process-level "is teams2 in the recording set" goes
///   `false` immediately because modulehost stops actively reading from
///   the device, even though the AudioUnit handle is retained.
/// - **Zoom** is more aggressive — releases the mic on Leave — but on
///   quick rejoin (back-to-back calls) device-level can flicker once and
///   suppress the new-session reset that Detector relies on.
/// - **Browsers** (Chrome/Arc/Safari/etc.) claim mic only when a tab
///   actually opens it (web Meet / Telemost / Whereby). When the user
///   closes the tab the helper releases — also detectable at process
///   level but reliable enough at device level too.
///
/// Conforms to `MicInUseProbing` (same `subscribe() -> AsyncStream<Bool>`
/// + `stop()` shape) so it slots into `MeetingDetector` and
/// `MeetingRecorder` as a drop-in replacement for `MicInUseProbe`. The
/// protocol name stays for now to avoid a wide rename; semantics are
/// what changed.
///
/// Emission contract matches `MicInUseProbe`:
/// - First value on the stream is the **current** meeting-active state.
/// - Subsequent values are **transitions** only (no repeat ticks).
@MainActor
final class MeetingContextActiveProbe: MicInUseProbing {

    private static let log = OSLog(
        subsystem: "com.sidekey.meetings",
        category: "meeting-context-probe"
    )

    private let pollInterval: TimeInterval
    /// Produces the current "recording right now" bundle-ID snapshot.
    /// Injected so tests can observe the calling thread and substitute
    /// synthetic snapshots; production default is the CoreAudio HAL scan.
    private let scanner: @Sendable () -> Set<String>
    private var pollTask: Task<Void, Never>?
    /// Multi-subscriber broadcast: detector + recorder both subscribe.
    /// Each subscription gets its own AsyncStream; poll task is shared.
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var lastEmitted: Bool?
    /// Counter used to throttle the verbose "currently recording" trace
    /// to roughly one line every 10s instead of every poll. Detector +
    /// recorder share the probe so dense per-tick logging would drown
    /// out the actual transitions.
    private var traceTickCounter: UInt64 = 0

    /// - Parameters:
    ///   - pollInterval: how often to sample `AudioProcessProbe`.
    ///     Production: 2s — matches `MicInUseProbe` cadence so the two
    ///     feels indistinguishable to downstream subscribers.
    ///   - scanner: snapshot source for "who is recording right now".
    ///     Production default: the CoreAudio HAL process scan. Tests inject
    ///     a synthetic snapshot / thread-observing closure.
    init(
        pollInterval: TimeInterval = 2.0,
        scanner: @escaping @Sendable () -> Set<String> = {
            AudioProcessProbe().bundleIDsCurrentlyRecording()
        }
    ) {
        self.pollInterval = pollInterval
        self.scanner = scanner
    }

    /// Returns a fresh stream. Poll task is started on first subscribe
    /// and shared across all subscribers. New subscribers immediately
    /// see the last-known value (no waiting for the next transition).
    func subscribe() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        continuations[id] = continuation
        if let lastEmitted {
            continuation.yield(lastEmitted)
        }
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        if pollTask == nil {
            startPollTask()
        }
        return stream
    }

    private func startPollTask() {
        let interval = pollInterval
        let scanner = self.scanner
        pollTask = Task.detached(priority: .utility) { [weak self] in
            let intervalNs = UInt64(interval * 1_000_000_000)
            while !Task.isCancelled {
                // The HAL scan stays on this detached (utility) executor —
                // NEVER hop it to the MainActor. Each scan is ~50 synchronous
                // Mach IPCs to coreaudiod; while a meeting's audio devices
                // are coming up (Zoom opening streams, Bluetooth switching
                // to HFP) those IPCs stall for hundreds of ms, and running
                // them on main froze clicks on the meeting nudge.
                // WHY: docs/decisions/2026-07-08-meeting-audio-hal-scan-off-main.md
                let bundles = scanner()
                let meetingBundles = bundles.filter { Self.isMeetingContextBundle($0) }
                let active = !meetingBundles.isEmpty
                await self?.handlePoll(active: active, meetingBundles: meetingBundles, allBundles: bundles)
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    /// `internal` (not `private`) so `MeetingContextActiveProbeTests` can drive
    /// a synthetic poll snapshot and assert the state transitions without standing
    /// up the CoreAudio HAL. Production only ever calls it from `startPollTask`.
    func handlePoll(
        active: Bool,
        meetingBundles: Set<String>,
        allBundles: Set<String>
    ) {
        // Periodic verbose trace — ~every 10s (5 ticks @ 2s) — so when
        // Teams "doesn't release after leave" we can see in the log
        // exactly which bundles still claim input. Throttled to avoid
        // log flooding under shared-probe load.
        traceTickCounter &+= 1
        if traceTickCounter % 5 == 0 {
            let meetingList = meetingBundles.sorted().joined(separator: ", ")
            let allList = allBundles.sorted().joined(separator: ", ")
            os_log(
                "tick (active: %{public}@, meeting_bundles: [%{public}@], all_recording: [%{public}@])",
                log: Self.log, type: .info,
                active ? "true" : "false",
                meetingList,
                allList
            )
        }

        guard lastEmitted == nil || lastEmitted != active else { return }
        lastEmitted = active
        // On every transition: log the exact bundles that flipped the
        // signal. This is the primary diagnostic for "Teams didn't
        // release" / "quick reconnect didn't fire" complaints.
        let meetingList = meetingBundles.sorted().joined(separator: ", ")
        let allList = allBundles.sorted().joined(separator: ", ")
        os_log(
            "transition (active: %{public}@, meeting_bundles: [%{public}@], all_recording: [%{public}@])",
            log: Self.log, type: .info,
            active ? "true" : "false",
            meetingList,
            allList
        )
        for cont in continuations.values {
            cont.yield(active)
        }
    }

    /// Cancels polling and terminates all open subscriptions.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for cont in continuations.values { cont.finish() }
        continuations.removeAll()
        lastEmitted = nil
        traceTickCounter = 0
    }

    deinit {
        pollTask?.cancel()
        for cont in continuations.values { cont.finish() }
    }

    // MARK: - Meeting-context matching

    /// True if `bundleID` is one of the whitelisted native meeting apps
    /// (Zoom/Slack/Teams) — exact or `<bid>.` prefix for helper
    /// subprocesses (e.g. `com.microsoft.teams2.modulehost`) — OR a
    /// recognized browser process / browser helper.
    ///
    /// Allow-lists are inlined (rather than calling
    /// `FrontmostAppDetector.matchesAnyMeetingBundle` /
    /// `AudioProcessProbe.matchesAnyBrowserBundle`) because
    /// `FrontmostAppDetector` is a `@MainActor` type and calling into it
    /// would force this helper itself to be MainActor-only. The probe
    /// needs to do this matching from a detached poll task without
    /// round-tripping to the MainActor for every bundle ID. Strings here
    /// MUST stay in sync with those two source-of-truth allow-lists.
    nonisolated static func isMeetingContextBundle(_ bundleID: String) -> Bool {
        let needle = bundleID.lowercased()
        // Native meeting apps — mirror of FrontmostAppDetector.meetingAppBundleIDs
        let meetingApps: [String] = [
            "us.zoom.xos",
            "com.tinyspeck.slackmacgap",
            "com.microsoft.teams2",
            "com.microsoft.teams",
        ]
        for app in meetingApps {
            if needle == app { return true }
            if needle.hasPrefix(app + ".") { return true }
        }
        // Browsers / browser helpers — mirror of AudioProcessProbe.browserBundleIDs.
        // `com.apple.webkit` covers Safari WebRTC capture surfacing as
        // `com.apple.WebKit.GPU` rather than `com.apple.Safari`.
        let browsers: [String] = [
            "com.google.chrome",
            "com.apple.safari",
            "com.apple.webkit",
            "com.brave.browser",
            "com.microsoft.edgemac",
            "company.thebrowser.browser",
            "company.thebrowser.dia",
            "org.mozilla.firefox",
        ]
        for browser in browsers {
            if needle == browser { return true }
            if needle.hasPrefix(browser + ".") { return true }
        }
        // The Browser Company shared helper namespace (Arc + Dia spawn
        // `company.thebrowser.browser.helper` for tab subprocesses).
        if needle.hasPrefix("company.thebrowser.") && needle.contains(".browser.helper") {
            return true
        }
        return false
    }
}
