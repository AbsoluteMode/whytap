import AppKit
import Darwin
import Foundation

/// Local restore points around builds the owner previews before code review.
///
/// The outgoing, already verified app makes one right before a preview build
/// replaces it (`--restore-point create`), with Whytap quit: a same-Mac,
/// byte-exact `LocalRestoreSnapshot` of the settings domain and the covered
/// Application Support folders. A rollback the owner asks for reinstalls the
/// verified app and parks that restore point with `--restore-point apply <id>`;
/// the startup restore transaction applies it before the app delegate on the next
/// launch and keeps the data it replaced as its recovery checkpoint, so nothing
/// written while the preview ran is destroyed. Restore points never leave this
/// Mac and never hold provider keys, the Case vault, History or meeting audio.
/// WHY: .project-docs/decisions/2026-11-26-preview-restore-points.md
enum PreviewRestorePoints {
    /// Info.plist `ExodiaRestorePointVersion`: the build queue widens preview
    /// admission only for an installed app that can make restore points.
    static let version = 1
    static let sections = LocalRestoreSnapshot.sections
    static let kept = 5
    static let freeSpaceReserve: Int64 = 2_000_000_000
    static let maxSequence = 1_000_000_000
    static let recordName = "record.json"
    static let incomingPrefix = ".incoming-"

    struct Record: Codable, Equatable {
        var id: UUID
        /// Increases with every restore point: dates are stored to the second.
        var sequence: Int
        var createdAt: Date
        var reason: String
        var appVersion: String?
        var appBuild: String?
        var archiveBytes: Int64
        var sections: [ArtifactBackupSection]

        /// Numbers and names a record may hold; anything else is not a restore point.
        var isValid: Bool {
            (1...PreviewRestorePoints.maxSequence).contains(sequence)
                && (0...LocalRestoreSnapshot.maxBytes).contains(archiveBytes)
                && !sections.isEmpty && Set(sections).isSubset(of: PreviewRestorePoints.sections)
                && Set(sections).count == sections.count
                && reason.count <= 200 && (appBuild?.count ?? 0) <= 64 && (appVersion?.count ?? 0) <= 64
        }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case appRunning
        case unknownRestorePoint(String)
        case restorePending
        case diskSpace(needed: Int64, available: Int64)
        case unsafeStore
        case usage(String)

        var description: String {
            switch self {
            case .appRunning: return "Whytap is running or another restore point command is: quit it before making or applying a restore point"
            case .unknownRestorePoint(let id): return "No restore point \(id) on this Mac"
            case .restorePending: return "Another restore is parked or unfinished. Open Whytap to finish it, or cancel it in Settings → Backup, before applying a restore point"
            case .diskSpace(let needed, let available):
                return "Not enough free space for a restore point: needs \(needed) bytes, \(available) available"
            case .unsafeStore: return "The restore point folder is not a private folder of this user"
            case .usage(let text): return text
            }
        }
    }

    /// Restore points on this Mac: `<bundle root>/restore-points/<id>/` (mode 0700)
    /// holding `record.json` and the snapshot. A point is published by renaming its
    /// finished `.incoming-<id>` folder, so the record and the snapshot appear and
    /// disappear together.
    struct Store {
        let root: URL

        init(locations: ArtifactBackupLocations) {
            root = locations.restorePointsRoot
        }

        func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }

        /// Creates or checks the private root: a real directory of this user, 0700.
        func prepare() throws {
            do { try ConfigBackupFiles.ensurePrivateDirectory(root) }
            catch { throw Failure.unsafeStore }
            var info = stat()
            guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                  chmod(root.path, 0o700) == 0 else { throw Failure.unsafeStore }
        }

        /// Newest first. A folder without a valid record, or whose record names
        /// another ID, is not a restore point.
        func records() -> [Record] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            return names.compactMap { name -> Record? in
                guard let id = UUID(uuidString: name), id.uuidString.lowercased() == name,
                      let data = try? Data(contentsOf: directory(id).appendingPathComponent(PreviewRestorePoints.recordName)),
                      data.count <= 64 * 1024,
                      let record = try? JSONDecoder.artifactBackup.decode(Record.self, from: data),
                      record.id == id, record.isValid else { return nil }
                return record
            }.sorted { ($0.sequence, $0.createdAt) > ($1.sequence, $1.createdAt) }
        }

        /// Keeps the newest `count` and the one an armed restore points at; removes
        /// unpublished work and folders that are not restore points.
        func prune(keeping count: Int, protecting protected: String?) {
            let keep = Set(records().prefix(count).map { directory($0.id).standardizedFileURL.path })
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for name in names {
                let url = root.appendingPathComponent(name, isDirectory: true)
                let path = url.standardizedFileURL.path
                guard !keep.contains(path), path != protected else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Create and apply

    @MainActor
    static func create(reason: String, environment: ArtifactBackupEnvironment = ArtifactBackupEnvironment(),
                       available: (URL) -> Int64? = PreviewRestorePoints.availableBytes) throws -> Record {
        let store = Store(locations: environment.locations)
        try store.prepare()
        let existing = store.records()
        let protected = environment.transaction().plannedRestore()?.localSnapshot
        // Earlier interrupted work is never a restore point: clear it first.
        store.prune(keeping: Int.max, protecting: protected)
        let needed = try neededBytes(environment.locations)
        if let free = available(store.root), free < needed {
            throw Failure.diskSpace(needed: needed, available: free)
        }
        let latest = existing.map(\.sequence).max() ?? 0
        guard latest < maxSequence else { throw Failure.unsafeStore }
        let id = UUID()
        let incoming = store.root.appendingPathComponent(incomingPrefix + id.uuidString.lowercased(), isDirectory: true)
        guard mkdir(incoming.path, 0o700) == 0 else { throw ArtifactBackupError.writeFailed }
        do {
            let manifest = try LocalRestoreSnapshot.capture(
                into: incoming, sections: sections, locations: environment.locations,
                defaults: environment.defaults, domain: environment.defaultsDomain, now: environment.now())
            let record = Record(
                id: id, sequence: latest + 1, createdAt: environment.now(),
                reason: reason,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                archiveBytes: manifest.totalBytes, sections: manifest.sections)
            guard FileManager.default.createFile(
                atPath: incoming.appendingPathComponent(recordName).path,
                contents: try JSONEncoder.artifactBackup.encode(record),
                attributes: [.posixPermissions: 0o600]) else { throw ArtifactBackupError.writeFailed }
            try ConfigBackupFiles.synchronizeDirectory(incoming)
            // One rename publishes the record and the snapshot together.
            guard rename(incoming.path, store.directory(id).path) == 0 else { throw ArtifactBackupError.writeFailed }
            try ConfigBackupFiles.synchronizeDirectory(store.root)
            store.prune(keeping: kept, protecting: protected)
            return record
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            throw error
        }
    }

    /// Bytes of every covered root plus the reserve. Clones share blocks with
    /// the live files, so this is an upper bound.
    static func neededBytes(_ locations: ArtifactBackupLocations) throws -> Int64 {
        var total = freeSpaceReserve
        for root in LocalRestoreSnapshot.roots(locations) {
            var sizes = [(try? root.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0]
            let enumerator = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: [.fileSizeKey])
            while let url = enumerator?.nextObject() as? URL {
                sizes.append((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            for size in sizes {
                let (sum, overflow) = total.addingReportingOverflow(Int64(size))
                guard !overflow else { throw ArtifactBackupError.tooLarge }
                total = sum
            }
        }
        return total
    }

    /// Verifies the restore point whole and parks it for the next launch. Exactly
    /// the requested sections, every one of them carried by the point, or nothing.
    @MainActor
    static func stage(id: UUID, only requested: Set<ArtifactBackupSection>? = nil,
                      environment: ArtifactBackupEnvironment = ArtifactBackupEnvironment())
        throws -> (record: Record, sections: Set<ArtifactBackupSection>) {
        let store = Store(locations: environment.locations)
        try store.prepare()
        guard let record = store.records().first(where: { $0.id == id }) else {
            throw Failure.unknownRestorePoint(id.uuidString.lowercased())
        }
        let carried = Set(record.sections)
        let chosen = requested ?? carried
        guard !chosen.isEmpty, chosen.isSubset(of: carried) else {
            let missing = chosen.subtracting(carried).map(\.rawValue).sorted().joined(separator: ", ")
            throw Failure.usage("This restore point does not carry: \(missing)")
        }
        let transaction = environment.transaction()
        guard !transaction.hasPendingWork else { throw Failure.restorePending }
        let snapshot = store.directory(id)
        let manifest = try LocalRestoreSnapshot.verify(snapshot, locations: environment.locations)
        guard Set(manifest.sections) == carried else { throw ArtifactBackupError.damaged }
        do { try transaction.armLocal(snapshot: snapshot, manifest: manifest, sections: chosen) }
        catch ArtifactBackupError.applyInProgress { throw Failure.restorePending }
        return (record, chosen)
    }

    static func availableBytes(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Command line

    enum Command: Equatable {
        case list
        case create(reason: String)
        case apply(UUID, Set<ArtifactBackupSection>?)
    }

    /// The whole command or a usage error: no flag is optional by accident, no
    /// operand is ignored, and a selection is never narrowed or widened.
    static func parse(_ arguments: [String]) throws -> Command {
        let usage = Failure.usage("Use --restore-point list, create --reason <text>, or apply <id> [--sections a,b]")
        switch arguments.first {
        case "list":
            guard arguments.count == 1 else { throw usage }
            return .list
        case "create":
            guard arguments.count == 3, arguments[1] == "--reason" else { throw usage }
            let reason = arguments[2]
            guard !reason.trimmingCharacters(in: .whitespaces).isEmpty, !reason.hasPrefix("--"),
                  reason.count <= 200,
                  !reason.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw Failure.usage("--reason needs a short one-line text")
            }
            return .create(reason: reason)
        case "apply":
            guard arguments.count == 2 || (arguments.count == 4 && arguments[2] == "--sections"),
                  let id = UUID(uuidString: arguments[1]) else { throw usage }
            guard arguments.count == 4 else { return .apply(id, nil) }
            let names = arguments[3].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            var chosen = Set<ArtifactBackupSection>()
            for name in names {
                guard let section = ArtifactBackupSection(rawValue: name), sections.contains(section),
                      chosen.insert(section).inserted else {
                    throw Failure.usage("--sections is a comma list of distinct names from: "
                        + sections.map(\.rawValue).sorted().joined(separator: ", "))
                }
            }
            return .apply(id, chosen)
        default:
            throw usage
        }
    }

    /// `--restore-point …`, run from the app's own executable. Prints one JSON
    /// object and exits: 0 done, 1 failed, 2 usage, 3 Whytap (or another restore
    /// point command) is running. Returns false when the arguments are not a
    /// restore point command.
    @MainActor
    static func runCommandLine(_ arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: "--restore-point") else { return false }
        exit(execute(Array(arguments[(index + 1)...])))
    }

    /// The exclusive hold a create or apply keeps for its whole run: the same
    /// advisory lease every Whytap flavor (production and beta) takes before it
    /// starts, so a launch or a second command waits out this one, plus a check for
    /// running copies that predate the lease. Nil when any of them is running.
    static func acquireLease() -> ApplicationInstanceLease? {
        guard case .acquired(let lease)? = try? ApplicationInstanceLease.acquire(
            directory: ApplicationInstanceCoordinator.leaseDirectory, ownerPID: getpid()) else { return nil }
        let running = NSWorkspace.shared.runningApplications.contains {
            !$0.isTerminated && $0.processIdentifier != getpid()
                && ApplicationInstanceCoordinator.bundleIdentifiers.contains($0.bundleIdentifier ?? "")
        }
        return running ? nil : lease
    }

    @MainActor
    static func execute(_ arguments: [String],
                        environment: ArtifactBackupEnvironment = ArtifactBackupEnvironment(),
                        lease: () -> AnyObject? = { PreviewRestorePoints.acquireLease() },
                        available: (URL) -> Int64? = PreviewRestorePoints.availableBytes,
                        output: (String) -> Void = { print($0) }) -> Int32 {
        func emit(_ value: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
            output(String(data: data, encoding: .utf8) ?? "{}")
        }
        do {
            let command = try parse(arguments)
            if case .list = command {
                // Read-only: listing may run beside Whytap.
                emit(["restore_points": Store(locations: environment.locations).records().map(describe)])
                return 0
            }
            guard let held = lease() else { throw Failure.appRunning }
            defer { withExtendedLifetime(held) {} }
            switch command {
            case .create(let reason):
                emit(["restore_point": describe(try create(reason: reason, environment: environment,
                                                           available: available))])
            case .apply(let id, let requested):
                let staged = try stage(id: id, only: requested, environment: environment)
                emit(["staged": describe(staged.record),
                      "sections": staged.sections.map(\.rawValue).sorted(),
                      "next": "Launch Whytap normally: the restore is applied before it starts, and the data it replaces is kept as a recovery checkpoint"])
            case .list:
                break
            }
            return 0
        } catch let failure as Failure {
            emit(["error": failure.description])
            switch failure {
            case .usage: return 2
            case .appRunning: return 3
            default: return 1
            }
        } catch {
            emit(["error": String(describing: error)])
            return 1
        }
    }

    static func describe(_ record: Record) -> [String: Any] {
        var value: [String: Any] = ["id": record.id.uuidString.lowercased(), "sequence": record.sequence,
                                    "created_at": ISO8601DateFormatter().string(from: record.createdAt),
                                    "reason": record.reason, "archive_bytes": record.archiveBytes,
                                    "sections": record.sections.map(\.rawValue)]
        if let version = record.appVersion { value["app_version"] = version }
        if let build = record.appBuild { value["app_build"] = build }
        return value
    }
}
