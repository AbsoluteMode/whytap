import Foundation
import os.log

struct MeetingReconnectMarker: Codable, Equatable, Sendable {
    let afterAudioSeconds: TimeInterval
    let gapSeconds: TimeInterval
}

/// Durability record for a finalised recording.
///
/// WHY this exists: at Stop time the coordinator hands the recorder's WAV
/// chunks to the on-device / BYOK processor. If the app quits (or the model
/// load fails) before the note lands in the store, the chunks sitting in
/// `meetings-staging/<recorderUUID>/` would be invisible to recovery and a
/// fully recorded meeting silently lost.
///
/// The manifest closes that gap. The coordinator writes it into the
/// recorder's staging dir *before* processing starts, capturing everything
/// the recovery path needs to rebuild the finalized event on the next
/// launch: recorder meeting id, the absolute recording timestamps, duration,
/// the pinned language, and the chunk filenames.
///
/// Lifecycle (see `MeetingsCoordinator.dispatchFinalizedForProcessing`):
/// 1. Written atomically before processing is attempted.
/// 2. Deleted together with the staging dir once the processor stored the
///    note.
/// 3. Left on disk if processing fails, so the next launch can retry.
struct MeetingFinalizeManifest: Codable, Equatable, Sendable {
    /// The recorder-side meeting id. This is the directory name under the
    /// staging root (`meetings-staging/<recorderMeetingId>/`) and the id the
    /// stored note carries.
    let recorderMeetingId: UUID
    /// Absolute wall-clock start of the recording, so the recovered meeting
    /// carries the real recording time, not the recovery time.
    let startedAt: Date
    /// Absolute wall-clock end of the recording (the moment the
    /// coordinator built the manifest at Stop time).
    let endedAt: Date
    /// Rounded total recording duration in seconds. Matches the value
    /// `dispatchFinalizedForProcessing` derives from
    /// `FinalizedEvent.totalDurationSeconds`.
    let durationSeconds: Int
    /// User-pinned protocol language at Stop time (`nil` = the transcriber
    /// auto-detects). Captured here so a language toggle between the
    /// failed Stop and the recovery launch does not change the recovered
    /// meeting's language.
    let language: String?
    /// Chunk WAV filenames (last path component only — the directory is
    /// the manifest's own dir, so the on-disk record stays portable if
    /// the staging root ever moves). Order is chunk-000 → chunk-NNN.
    let chunkFileNames: [String]
    /// Whether the recording is fully finalised (Stop emitted). Always
    /// `true` for the current single-shot finalize path; stored per the
    /// durability spec so a future partial-finalize flow can distinguish
    /// "recover + finalize" from "recover chunks only".
    let isFinal: Bool

    /// Transcript boundaries created by reconnecting to an auto-ended
    /// recording. Defaulted for manifests written by older clients.
    var reconnectMarkers: [MeetingReconnectMarker]? = nil

    /// Canonical filename for the manifest inside the recorder's staging
    /// dir. Sits alongside the WAV chunks + sidecars.
    static let fileName = "manifest.json"
}

/// Atomic read / write / delete / scan helper for `MeetingFinalizeManifest`.
///
/// WHY a dedicated type: the durability spec mandates an ATOMIC write
/// (a crash mid-write must never leave a half-written manifest that
/// poisons recovery) and a decode-tolerant scan (a corrupt manifest is
/// logged + skipped, never crashes, never deletes the chunks). Isolating
/// the IO here keeps `MeetingsCoordinator` focused on orchestration and
/// lets the persistence rules be unit-tested in isolation.
///
/// `Sendable` + value-typed so it can be handed to the detached processing
/// task without actor hops; `FileManager` is the only dependency and is
/// itself thread-safe for the operations used here.
struct MeetingFinalizeManifestStore: Sendable {
    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "manifest")

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// One staging dir that holds a manifest. `dir` is the recorder's
    /// staging directory; `manifest` is its decoded contents.
    struct Entry: Sendable {
        let dir: URL
        let manifest: MeetingFinalizeManifest
    }

    /// Write `manifest` atomically into `dir/manifest.json`.
    ///
    /// `Data.write(options: [.atomic])` writes to a sibling temp file and
    /// renames, so a crash mid-write leaves either the previous manifest
    /// (or none) — never a truncated file. The dir already exists at call
    /// time (the recorder created it to hold the chunks) but we create it
    /// defensively so the write cannot fail on a missing parent.
    func write(_ manifest: MeetingFinalizeManifest, to dir: URL) throws {
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let target = dir.appendingPathComponent(MeetingFinalizeManifest.fileName)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: target, options: [.atomic])
    }

    /// True when `dir` contains a manifest file. Cheap existence check
    /// used by recovery to decide whether a dir is a manifest candidate
    /// before paying the decode cost.
    func manifestExists(in dir: URL) -> Bool {
        fileManager.fileExists(
            atPath: dir.appendingPathComponent(MeetingFinalizeManifest.fileName).path
        )
    }

    /// Delete the manifest in `dir` if present. Used when a stale manifest
    /// is reconciled on recovery. Missing file is a no-op (idempotent
    /// against a double-run).
    func delete(in dir: URL) {
        let target = dir.appendingPathComponent(MeetingFinalizeManifest.fileName)
        guard fileManager.fileExists(atPath: target.path) else { return }
        do {
            try fileManager.removeItem(at: target)
        } catch {
            os_log(
                "manifest delete failed (dir: %{public}@, error: %{public}@)",
                log: Self.log, type: .error,
                target.lastPathComponent, String(describing: error)
            )
        }
    }

    /// Scan `stagingRoot` for every dir that contains a manifest. Decode
    /// failures are logged and skipped — a corrupt manifest must NOT
    /// crash recovery and must NOT cause the chunks to be deleted (the
    /// caller never reaches the delete path for a dir that fails to
    /// decode here). Returns `[]` when the staging root does not yet
    /// exist (fresh install / no meetings recorded).
    func scan(stagingRoot: URL) -> [Entry] {
        guard fileManager.fileExists(atPath: stagingRoot.path) else { return [] }
        let dirs: [URL]
        do {
            dirs = try fileManager.contentsOfDirectory(
                at: stagingRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            os_log(
                "manifest scan failed to list staging root (error: %{public}@)",
                log: Self.log, type: .error,
                String(describing: error)
            )
            return []
        }

        var entries: [Entry] = []
        for dir in dirs {
            let manifestURL = dir.appendingPathComponent(MeetingFinalizeManifest.fileName)
            guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(
                    MeetingFinalizeManifest.self, from: data
                  ) else {
                // Corrupt / unreadable manifest. Log + skip — the chunks
                // are left untouched so a future build can still recover
                // them if the decode rule changes.
                os_log(
                    "manifest corrupt or unreadable — skipping (dir: %{public}@)",
                    log: Self.log, type: .error,
                    dir.lastPathComponent
                )
                continue
            }
            entries.append(Entry(dir: dir, manifest: manifest))
        }
        return entries
    }
}
