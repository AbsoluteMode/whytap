import AppKit
import Foundation
import os.log

/// `NowPlayingSource` backed by the vendored MediaRemote adapter
/// (`ungive/mediaremote-adapter`): a bundled `/usr/bin/perl` driver loads an
/// unlinked `MediaRemoteAdapter.framework` that reads the private system
/// MediaRemote framework and streams the now-playing state as JSON — with
/// **no TCC / Automation prompt**, unlike the AppleScript path.
///
/// **Shape:** push-based cache, identical external contract to
/// `AppleScriptNowPlayingSource`, so `NowPlayingController` / `Coordinator` /
/// `Config` are unchanged. A long-lived `perl run.pl <framework> stream
/// --no-diff --micros` process emits one self-contained JSON line per
/// update; a `readabilityHandler` frames lines off the main thread, decodes
/// each into a `NowPlayingSnapshot`, and stores it under a lock.
/// `currentSnapshot()` returns the cached value synchronously (the
/// controller polls on its own ~1 s timer).
///
/// **`--no-diff`** is deliberate: every line carries the full current state,
/// so this source never has to reconstruct state from diffs. **`--micros`**
/// makes the time fields integer microseconds (`durationMicros`,
/// `elapsedTimeMicros`, `timestampEpochMicros`) that `MediaRemoteTrackInfo`
/// decodes.
///
/// **Transport** is via `send <MRCommand-id>` (one-shot perl process, the
/// adapter has no stdin protocol): previous = 5, next = 4, play = 0,
/// pause = 1.
///
/// **Resilience:** `SIGPIPE` is ignored process-wide (a dead pipe must not
/// kill the app); a `terminationHandler` clears the cache and relaunches the
/// stream after a short delay while `started`; the stream is also
/// proactively recycled every ~`restartEventThreshold` events to bound any
/// long-lived leak in the private substrate.
///
/// **Privacy:** track metadata is never written to `os_log` (invariant #3);
/// the DEBUG log path only records lifecycle, never titles.
final class MediaRemoteNowPlayingSource: NowPlayingSource, @unchecked Sendable {

    private static let log = OSLog(subsystem: "com.sidekey.nowplaying", category: "mediaremote")

    /// Result of the static `healthCheck()` probe.
    enum Health: Equatable {
        case ok
        case unavailable
    }

    // MARK: - Bundle resolution

    /// Absolute path to the bundled perl driver
    /// (`Contents/Resources/MediaRemoteAdapter/run.pl`).
    static func runScriptURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "run", withExtension: "pl", subdirectory: "MediaRemoteAdapter")
    }

    /// Absolute path to the bundled adapter framework **directory** (the perl
    /// driver appends the inner Mach-O basename itself, so the argument is the
    /// `.framework` directory, not the binary inside it).
    static func frameworkURL(bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL
            .appendingPathComponent("Contents/Frameworks/MediaRemoteAdapter.framework")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Tunables

    /// Recycle the stream process after this many events to bound any
    /// long-lived resource growth in the private framework.
    private static let restartEventThreshold = 100
    /// Delay before relaunching after the stream exits/crashes.
    private static let relaunchDelay: TimeInterval = 0.2

    // MARK: - State

    private let runScript: URL
    private let framework: URL

    /// Serial queue owning all process lifecycle + stdout handling. The
    /// controller's `currentSnapshot()` only reads the locked cache, never
    /// touches this queue.
    private let queue = DispatchQueue(label: "com.sidekey.nowplaying.mediaremote")

    /// Dedicated queue for one-shot transport `send` processes. Kept separate
    /// from `queue` so a transport click fires immediately even while the
    /// stream queue is busy framing/decoding an inbound now-playing line —
    /// otherwise a command would serialize behind stream `ingest` work and the
    /// user would feel the ~1 s lag the optimistic flip exists to hide.
    private let commandQueue = DispatchQueue(
        label: "com.sidekey.nowplaying.mediaremote.command",
        qos: .userInitiated
    )

    private let lock = NSLock()
    private var _latest: NowPlayingSnapshot?
    /// Last decoded track info, for the same-track artwork-preservation pass.
    private var _previousInfo: MediaRemoteTrackInfo?

    private var process: Process?
    private var framer = LineFramer()
    private var eventCount = 0
    private var started = false

    /// SIGPIPE must be ignored exactly once per process. A write to a dead
    /// transport pipe would otherwise raise SIGPIPE and crash the app.
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    // MARK: - Init

    /// - Returns: `nil` when the bundled assets are missing (fail-closed —
    ///   the factory then falls back to AppleScript).
    init?(bundle: Bundle = .main) {
        guard
            let runScript = Self.runScriptURL(bundle: bundle),
            let framework = Self.frameworkURL(bundle: bundle)
        else {
            return nil
        }
        self.runScript = runScript
        self.framework = framework
        _ = Self.ignoreSIGPIPE
    }

    // MARK: - Lifecycle

    /// Start the streaming process. Idempotent. Called by the factory right
    /// after construction (the controller drives polling separately).
    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.launchStream()
        }
    }

    /// Stop streaming and clear the cache. Safe to call repeatedly.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.teardownProcess()
            self.setLatest(nil)
            self.lock.lock(); self._previousInfo = nil; self.lock.unlock()
        }
    }

    // MARK: - NowPlayingSource

    func currentSnapshot() -> NowPlayingSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return _latest
    }

    func previous() { sendCommand(.previousTrack) }
    func next() { sendCommand(.nextTrack) }
    func playPause(isPlaying: Bool) {
        sendCommand(isPlaying ? .pause : .play)
    }

    // MARK: - Stream process

    private func launchStream() {
        framer = LineFramer()
        eventCount = 0

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [
            runScript.path,
            framework.path,
            "stream", "--no-diff", "--micros",
        ]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardInput = Pipe()
        proc.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.ingest(data) }
        }

        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.handleTermination()
            }
        }

        do {
            try proc.run()
            process = proc
            os_log("mediaremote stream started", log: Self.log, type: .info)
        } catch {
            os_log("mediaremote stream failed to launch", log: Self.log, type: .error)
            process = nil
            scheduleRelaunch()
        }
    }

    /// Frame + decode incoming stdout bytes. Runs on `queue`.
    private func ingest(_ data: Data) {
        for line in framer.feed(data) {
            eventCount += 1
            apply(line: line)
        }
        if eventCount >= Self.restartEventThreshold {
            recycleStream()
        }
    }

    private func apply(line: String) {
        guard let info = MediaRemoteStreamLine.decode(line) else {
            // `null` / blank line is the adapter's "nothing playing" signal.
            setLatest(nil)
            lock.lock(); _previousInfo = nil; lock.unlock()
            return
        }

        lock.lock()
        let previous = _previousInfo
        lock.unlock()

        let merged = MediaRemoteArtworkPreserver.merge(previous: previous, incoming: info)
        let snapshot = MediaRemoteSnapshotMapper.snapshot(from: merged, capturedAt: Date())

        lock.lock()
        _previousInfo = merged
        lock.unlock()

        setLatest(snapshot)
    }

    private func setLatest(_ snapshot: NowPlayingSnapshot?) {
        lock.lock()
        _latest = snapshot
        lock.unlock()
    }

    private func handleTermination() {
        setLatest(nil)
        lock.lock(); _previousInfo = nil; lock.unlock()
        process = nil
        if started {
            os_log("mediaremote stream exited — relaunching", log: Self.log, type: .info)
            scheduleRelaunch()
        }
    }

    /// Intentional recycle (event threshold). Terminating fires the
    /// terminationHandler, which relaunches while `started`.
    private func recycleStream() {
        guard let proc = process else { return }
        os_log("mediaremote stream recycle", log: Self.log, type: .debug)
        proc.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.handleTermination() }
        }
        proc.terminate()
    }

    private func scheduleRelaunch() {
        queue.asyncAfter(deadline: .now() + Self.relaunchDelay) { [weak self] in
            guard let self, self.started, self.process == nil else { return }
            self.launchStream()
        }
    }

    private func teardownProcess() {
        if let proc = process {
            proc.terminationHandler = nil
            if let stdout = proc.standardOutput as? Pipe {
                stdout.fileHandleForReading.readabilityHandler = nil
            }
            proc.terminate()
        }
        process = nil
    }

    // MARK: - Transport (one-shot `send <id>`)

    /// MediaRemote `MRACommand` ids the adapter's `send` accepts.
    private enum MRACommand: Int {
        case play = 0
        case pause = 1
        case nextTrack = 4
        case previousTrack = 5
    }

    private func sendCommand(_ command: MRACommand) {
        let runScript = self.runScript
        let framework = self.framework
        commandQueue.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            proc.arguments = [
                runScript.path, framework.path, "send", String(command.rawValue),
            ]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                os_log("mediaremote send failed", log: Self.log, type: .error)
            }
        }
    }

    // MARK: - Health check (static, bounded)

    /// Probe whether the adapter is usable: a bounded one-shot
    /// `perl run.pl <framework> get`. OK iff the process exits 0 and prints a
    /// parseable line (a payload object, or a bare `null`). Fail-closed when
    /// the bundled assets are missing or the probe times out.
    static func healthCheck(bundle: Bundle = .main, timeout: TimeInterval = 2.0) -> Health {
        guard
            let runScript = runScriptURL(bundle: bundle),
            let framework = frameworkURL(bundle: bundle)
        else {
            return .unavailable
        }

        _ = ignoreSIGPIPE

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = [runScript.path, framework.path, "get"]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return .unavailable
        }

        // Bound the wait: kill the probe if it overruns.
        let deadline = DispatchTime.now() + timeout
        let waiter = DispatchQueue(label: "com.sidekey.nowplaying.mediaremote.health")
        let done = DispatchSemaphore(value: 0)
        var output = Data()
        waiter.async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            return .unavailable
        }
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else { return .unavailable }

        let text = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first
        else {
            return .unavailable
        }
        let line = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        // `null` (nothing playing) is a valid, parseable health response.
        if line == "null" { return .ok }
        // Otherwise it must be JSON-parseable.
        if (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil {
            return .ok
        }
        return .unavailable
    }
}
