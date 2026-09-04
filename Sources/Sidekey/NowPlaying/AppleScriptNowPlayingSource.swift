import AppKit
import Carbon
import Foundation
import os.log

/// One AppleScript execution's result, captured as plain values so the
/// bounded runner and tests do not touch `NSAppleScript` /
/// `NSAppleEventDescriptor` directly. `failed` is set when the script
/// raised an error; `stringValue` / `data` are the descriptor's text and
/// raw bytes (the latter only needed for Music artwork).
struct AppleScriptOutput {
    let stringValue: String?
    let data: Data?
    let failed: Bool
}

/// Runs one AppleScript `source` on the **calling thread**, synchronously,
/// returning its output or `nil` when `NSAppleScript` could not even be
/// constructed. Injectable so tests can simulate a hung Apple Event
/// (`Thread.sleep` in the closure) without a real player. The default
/// implementation is `AppleScriptNowPlayingSource.defaultExecutor`.
typealias AppleScriptExecutor = (_ source: String) -> AppleScriptOutput?

/// Concrete `NowPlayingSource` backed by `NSAppleScript` against Apple
/// Music and Spotify.
///
/// **Threading (CRITICAL):** synchronous `NSAppleScript
/// .executeAndReturnError` can block/hang, and the app is hang-sensitive,
/// so scripting NEVER runs on the main thread. The protocol's
/// `currentSnapshot()` is synchronous (the MainActor controller calls it
/// from its poll), so this type keeps a *cached* latest snapshot refreshed
/// on a background serial queue (`scriptQueue`): `currentSnapshot()`
/// returns the cache immediately and kicks an async refresh for the next
/// poll. The cache is guarded by a lock. Net effect: the main thread never
/// waits on AppleScript, yet the controller still gets ~1 s-fresh data.
///
/// **Timeout (CRITICAL):** because even the off-main serial `scriptQueue`
/// could be wedged forever by a hung Music/Spotify Apple Event (refreshes
/// would then stop), every script is run through `executeBounded`: the
/// blocking executor runs on a *separate concurrent* `executionQueue` and
/// `scriptQueue` waits on a semaphore for at most `executionTimeout`. On
/// overrun the read is abandoned and treated as "no fields"/no active
/// player (per spec) — the controller's debounced clear handles it and the
/// next poll retries. The abandoned work item keeps running on the
/// concurrent queue but never blocks the next bounded execution.
///
/// **Automation consent (CRITICAL — the on-device fix):** before reading a
/// player, `consent.ensureConsent(for:)` is called on `scriptQueue`. A raw
/// background Apple-Event send relies on *implicit* consent, which never
/// triggers the macOS Automation (TCC) prompt nor registers the app under
/// Privacy → Automation — so every send would fail with
/// `errAEEventNotPermitted (-1743)` and no track would ever appear, with no
/// way for the user to grant. The consent gate uses
/// `AEDeterminePermissionToAutomateTarget` to present the prompt once and to
/// read status thereafter. That interactive call BLOCKS while the user
/// decides and is therefore NOT wrapped in `executeBounded`'s 2 s timeout —
/// only the read scripts are. A denied app is skipped (cached, no re-prompt);
/// a later grant is picked up cheaply on a subsequent poll.
///
/// **Launch safety:** a player is scripted only when it is already running
/// (`NSWorkspace.runningApplications` matches its bundle id). Scripting a
/// non-running app via `tell application` would launch it — forbidden.
///
/// **Per-app field facts (standard scripting dictionaries):**
/// - Music: `duration`/`player position` in seconds; artwork via
///   `data of artwork 1 of current track` (raw bytes → `NSImage`).
/// - Spotify: `duration` in milliseconds (÷1000); `player position` in
///   seconds; artwork via `artwork url` (https → async fetch + cache).
///
/// **Security:** all scripts are static literals — no untrusted
/// interpolation, so no AppleScript injection surface.
final class AppleScriptNowPlayingSource: NowPlayingSource, @unchecked Sendable {

    private static let log = OSLog(subsystem: "com.sidekey.nowplaying", category: "applescript")

    /// Serial queue that owns ALL refresh/transport orchestration. Keeping
    /// it serial means two refreshes never run concurrently and the main
    /// thread is never the one driving a refresh. The blocking
    /// `executeAndReturnError` itself runs on `executionQueue` (below) under
    /// a deadline, so a hung Apple Event cannot wedge THIS queue.
    private let scriptQueue = DispatchQueue(label: "com.sidekey.nowplaying.applescript")

    /// Concurrent queue on which the (potentially blocking) AppleScript
    /// executor actually runs, bounded by `executionTimeout`. Concurrent so
    /// that a wedged Apple Event left running after a timeout never serializes
    /// in front of — and therefore never wedges — the next bounded execution.
    private let executionQueue = DispatchQueue(
        label: "com.sidekey.nowplaying.applescript.exec",
        attributes: .concurrent
    )

    /// How long one script may run before the bounded runner gives up and
    /// treats it as "no result" (→ no active player). Per the spec:
    /// "AppleScript error/timeout → treat as no active player".
    private let executionTimeout: TimeInterval

    /// Injectable AppleScript primitive (defaults to real `NSAppleScript`).
    private let executor: AppleScriptExecutor

    /// Per-app Automation-consent gate. Triggers the macOS Automation prompt
    /// the first time and reads status thereafter (see class doc). Injectable
    /// so tests can drive the source without a real consent prompt.
    private let consent: NowPlayingAutomationConsent

    private let workspace: NSWorkspace
    private let lock = NSLock()
    private var cachedSnapshot: NowPlayingSnapshot?
    private var refreshInFlight = false

    /// Per-app wall-clock time the app was last seen `playing`, used as the
    /// most-recently-active tie-break when both report playing.
    private var lastPlayingAt: [String: Date] = [:]

    /// Small artwork cache keyed by Spotify artwork URL so we do not refetch
    /// the same image every poll.
    private var spotifyArtworkCache: [String: NSImage] = [:]

    init(
        workspace: NSWorkspace = .shared,
        executor: @escaping AppleScriptExecutor = AppleScriptNowPlayingSource.defaultExecutor,
        consent: NowPlayingAutomationConsent = NowPlayingAutomationConsent(),
        executionTimeout: TimeInterval = 2.0
    ) {
        self.workspace = workspace
        self.executor = executor
        self.consent = consent
        self.executionTimeout = executionTimeout
    }

    /// Real `NSAppleScript` execution on the calling thread. Returns `nil`
    /// only when the script source cannot be compiled into an
    /// `NSAppleScript`; a runtime AppleScript error is reported via
    /// `AppleScriptOutput.failed` so the caller can distinguish the two.
    static let defaultExecutor: AppleScriptExecutor = { source in
        guard let appleScript = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            #if DEBUG
            // Surface the AppleScript error number in DEBUG so a lingering
            // -1743 (errAEEventNotPermitted) after consent SHOULD have been
            // granted is distinguishable from ordinary script errors (e.g. a
            // track with no artwork). The real consent gating is done by
            // `NowPlayingAutomationConsent`, not by parsing this number.
            let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if number == errAEEventNotPermitted {
                os_log(
                    "AppleScript read denied (errAEEventNotPermitted -1743) despite consent gate",
                    log: AppleScriptNowPlayingSource.log, type: .debug
                )
            }
            #endif
            return AppleScriptOutput(stringValue: nil, data: nil, failed: true)
        }
        return AppleScriptOutput(
            stringValue: result.stringValue,
            data: result.data,
            failed: false
        )
    }

    // MARK: - NowPlayingSource

    func currentSnapshot() -> NowPlayingSnapshot? {
        kickRefreshIfIdle()
        lock.lock(); defer { lock.unlock() }
        return cachedSnapshot
    }

    func previous() {
        runTransport("previous track")
    }

    func playPause(isPlaying: Bool) {
        // Discrete command based on known state avoids `playpause` toggle
        // races (two polls could otherwise double-toggle).
        runTransport(isPlaying ? "pause" : "play")
    }

    func next() {
        runTransport("next track")
    }

    // MARK: - Background refresh

    /// Kick a background refresh unless one is already running. Coalesces so
    /// rapid polls do not pile up scripts on the serial queue.
    private func kickRefreshIfIdle() {
        lock.lock()
        if refreshInFlight {
            lock.unlock()
            return
        }
        refreshInFlight = true
        lock.unlock()

        scriptQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.readActiveSnapshot()
            self.lock.lock()
            self.cachedSnapshot = snapshot
            self.refreshInFlight = false
            self.lock.unlock()
        }
    }

    /// Read both players (when running), build candidates, and select the
    /// active one. Runs on `scriptQueue` only.
    private func readActiveSnapshot() -> NowPlayingSnapshot? {
        let runningBundleIDs = Set(
            workspace.runningApplications.compactMap { $0.bundleIdentifier }
        )
        let now = Date()
        var candidates: [NowPlayingCandidate] = []

        for app in [NowPlayingApp.music, NowPlayingApp.spotify]
        where runningBundleIDs.contains(app.bundleIdentifier) {
            // Gate the read on Automation consent. The first undetermined
            // app presents the system prompt here (blocking on this
            // background `scriptQueue`, deliberately NOT under the read
            // timeout); a denied app is skipped without re-prompting.
            guard consent.ensureConsent(for: app) else { continue }
            guard let fields = readFields(for: app, capturedAt: now) else { continue }
            guard let snapshot = NowPlayingMapper.snapshot(from: fields, capturedAt: now) else {
                continue
            }
            if snapshot.isPlaying {
                lastPlayingAt[app.bundleIdentifier] = now
            }
            candidates.append(
                NowPlayingCandidate(
                    snapshot: snapshot,
                    lastActiveAt: lastPlayingAt[app.bundleIdentifier]
                )
            )
        }

        return NowPlayingMapper.selectActive(candidates)
    }

    // MARK: - Per-app field reading

    /// Read one player's fields via a single tab-delimited AppleScript
    /// result (`state \t title \t artist \t album \t duration \t position`),
    /// normalizing units per app. Returns `nil` on any script error /
    /// stopped player.
    private func readFields(for app: NowPlayingApp, capturedAt: Date) -> NowPlayingRawFields? {
        let script = """
        tell application "\(app.scriptingName)"
            set ps to player state as text
            if ps is "stopped" then return "stopped"
            set t to name of current track
            set ar to artist of current track
            set al to album of current track
            set dur to duration of current track
            set pos to player position
            return ps & "\t" & t & "\t" & ar & "\t" & al & "\t" & (dur as text) & "\t" & (pos as text)
        end tell
        """

        guard let raw = run(script, context: "fields(\(app.scriptingName))") else { return nil }
        let parts = raw.components(separatedBy: "\t")
        guard parts.count >= 6 else { return nil }

        let state = NowPlayingPlayerState(rawValue: parts[0])
        guard state != .stopped else { return nil }

        let rawDuration = Double(parts[4]) ?? 0
        let rawPosition = Double(parts[5]) ?? 0
        // Per-app duration unit (Spotify ms vs Music s) is normalized by the
        // pure mapper so the divisor is unit-tested in one place.
        let durationSeconds = NowPlayingMapper.normalizeDuration(rawDuration, for: app)

        let artwork = loadArtwork(for: app)

        return NowPlayingRawFields(
            app: app,
            playerState: state,
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            durationSeconds: durationSeconds,
            elapsedSeconds: rawPosition,
            artwork: artwork
        )
    }

    // MARK: - Artwork

    private func loadArtwork(for app: NowPlayingApp) -> NSImage? {
        switch app {
        case .music:
            return loadMusicArtwork()
        case .spotify:
            return loadSpotifyArtwork()
        }
    }

    /// Music exposes raw artwork bytes via `data of artwork 1`. The bounded
    /// runner returns the descriptor's raw `data` bytes, which we decode to
    /// `NSImage`.
    private func loadMusicArtwork() -> NSImage? {
        // Guard: a track with no artwork raises an AppleScript error, which
        // `executeBounded` reports as failed (→ nil) — fine, the UI shows a
        // placeholder glyph. Routing through the bounded runner means this
        // script is also covered by the hang timeout.
        let script = """
        tell application "Music"
            set rawData to data of artwork 1 of current track
            return rawData
        end tell
        """
        guard let bytes = executeBounded(script, context: "musicArtwork")?.data,
              !bytes.isEmpty
        else { return nil }
        return NSImage(data: bytes)
    }

    /// Spotify exposes an `artwork url` (https). Fetch once and cache by URL.
    private func loadSpotifyArtwork() -> NSImage? {
        let script = """
        tell application "Spotify"
            return artwork url of current track
        end tell
        """
        guard let urlString = run(script, context: "spotifyArtworkURL"),
              let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" || url.scheme == "http"
        else { return nil }

        if let cached = spotifyArtworkCache[urlString] { return cached }

        // Synchronous fetch with a short timeout — we are already on the
        // background `scriptQueue`, so blocking here never touches main.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config)

        var image: NSImage?
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: url) { data, _, _ in
            if let data, let img = NSImage(data: data) { image = img }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 3.5)

        if let image {
            spotifyArtworkCache[urlString] = image
            // Bound the cache so it cannot grow unbounded over a long session.
            if spotifyArtworkCache.count > 16 {
                spotifyArtworkCache.removeValue(forKey: spotifyArtworkCache.keys.first!)
            }
        }
        return image
    }

    // MARK: - Transport

    /// Run a transport command against whichever player is currently the
    /// active one. Routed through the cached snapshot's `app` so prev/next/
    /// play-pause hit the player the user sees in the UI.
    private func runTransport(_ command: String) {
        lock.lock()
        let app = cachedSnapshot?.app
        lock.unlock()
        guard let app else { return }

        scriptQueue.async { [weak self] in
            let script = "tell application \"\(app.scriptingName)\" to \(command)"
            _ = self?.run(script, context: "transport")
        }
    }

    // MARK: - AppleScript runner

    /// Execute a script and return its string value, or `nil` on error /
    /// timeout. Thin wrapper over `executeBounded`.
    private func run(_ source: String, context: String) -> String? {
        executeBounded(source, context: context)?.stringValue
    }

    /// Run one script under a hard deadline so a wedged Apple Event cannot
    /// block the caller forever. The (potentially blocking) `executor` runs
    /// on the concurrent `executionQueue`; this method waits on a semaphore
    /// for at most `executionTimeout`. On overrun it returns `nil` (treated
    /// as "no result" → no active player) and lets the abandoned work item
    /// finish on its own without blocking future executions.
    ///
    /// **Race-freedom:** `box` is the only shared state. The work item
    /// writes it *before* signalling; the waiter reads it *only* after a
    /// successful `.success` wait (the semaphore establishes the
    /// happens-before edge). On timeout the waiter returns without touching
    /// `box`, so a still-running work item's later write never races a read.
    ///
    /// **Deadlock-freedom:** the blocking executor runs on a *different*
    /// queue than the caller, and that queue is concurrent — a caller on the
    /// serial `scriptQueue` only ever waits on the semaphore (bounded), never
    /// on a queue that is itself waiting on `scriptQueue`.
    private func executeBounded(_ source: String, context: String) -> AppleScriptOutput? {
        final class Box { var output: AppleScriptOutput? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let executor = self.executor

        executionQueue.async {
            box.output = executor(source)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + executionTimeout) == .success else {
            os_log(
                "AppleScript timed out after %{public}.1fs (%{public}@)",
                log: Self.log, type: .debug,
                executionTimeout, context
            )
            return nil
        }

        let output = box.output
        if output?.failed ?? true {
            os_log(
                "AppleScript failed (%{public}@)",
                log: Self.log, type: .debug, context
            )
            return nil
        }
        return output
    }

    // MARK: - Test seam

    #if DEBUG
    /// Run one script through the bounded runner synchronously and return
    /// its string value (or `nil` on error/timeout). Lets tests pin the
    /// timeout behaviour with an injected hanging executor without a real
    /// player. Not used in production.
    func runScriptForTesting(_ source: String) -> String? {
        run(source, context: "test")
    }
    #endif
}
