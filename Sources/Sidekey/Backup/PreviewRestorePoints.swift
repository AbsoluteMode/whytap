import AppKit
import CryptoKit
import Foundation

/// Local restore points around builds the owner previews before code review.
///
/// The outgoing, already verified app makes one right before a preview build
/// replaces it (`--restore-point create`), with the app quit. A rollback
/// reinstalls the verified app and parks that restore point with
/// `--restore-point apply <id>`; the existing restore transaction applies it
/// before the app delegate on the next launch and keeps the data it replaced
/// as its recovery checkpoint, so nothing written while the preview ran is
/// destroyed. Archives use the backup engine's encrypted format with a local
/// key of their own and never leave this Mac.
/// WHY: .project-docs/decisions/2026-11-26-preview-restore-points.md
enum PreviewRestorePoints {
    /// Info.plist `ExodiaRestorePointVersion`: the build queue widens preview
    /// admission only for an installed app that can make restore points.
    static let version = 1
    static let keyAccount = "backup.restore_point_key"
    /// Never provider keys or the Case vault: a preview that touches
    /// credentials is not admitted, and a rollback must never put older keys
    /// over the owner's current ones.
    static let sections: Set<ArtifactBackupSection> = [.settings, .meetings, .history, .workspace, .planner]
    static let kept = 5
    static let freeSpaceReserve: Int64 = 2_000_000_000

    struct Record: Codable, Equatable {
        var id: UUID
        /// Increases with every restore point: the archive format stores dates
        /// to the second, too coarse to order points made in one second.
        var sequence: Int
        var createdAt: Date
        var reason: String
        var appVersion: String?
        var appBuild: String?
        var archiveBytes: Int64
        var sections: [ArtifactBackupSection]
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case appRunning
        case unknownRestorePoint(String)
        case keyUnavailable
        case diskSpace(needed: Int64, available: Int64)
        case usage(String)

        var description: String {
            switch self {
            case .appRunning: return "Whytap is running: quit it before making or applying a restore point"
            case .unknownRestorePoint(let id): return "No restore point \(id) on this Mac"
            case .keyUnavailable: return "The restore point key is not available"
            case .diskSpace(let needed, let available):
                return "Not enough free space for a restore point: needs \(needed) bytes, \(available) available"
            case .usage(let text): return text
            }
        }
    }

    /// Restore points on this Mac: `<bundle root>/restore-points/<id>.exodiabackup`
    /// with a `<id>.json` record beside it.
    struct Store {
        let root: URL
        let keyStore: TokenStore

        init(locations: ArtifactBackupLocations,
             keyStore: TokenStore = KeychainStore(account: PreviewRestorePoints.keyAccount)) {
            root = locations.bundleRoot.appendingPathComponent("restore-points", isDirectory: true)
            self.keyStore = keyStore
        }

        func archiveURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased() + ".exodiabackup") }
        func recordURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased() + ".json") }

        func key(create: Bool) throws -> Data {
            if let encoded = try keyStore.read(), let key = Data(base64Encoded: encoded), key.count == 32 {
                return key
            }
            guard create else { throw Failure.keyUnavailable }
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try keyStore.save(key.base64EncodedString())
            return key
        }

        /// Newest first; a record without its archive is not a restore point.
        func records() -> [Record] {
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }
                .compactMap { try? JSONDecoder.artifactBackup.decode(Record.self, from: Data(contentsOf: $0)) }
                .filter { FileManager.default.fileExists(atPath: archiveURL($0.id).path) }
                .sorted { ($0.sequence, $0.createdAt) > ($1.sequence, $1.createdAt) }
        }

        func save(_ record: Record) throws {
            let data = try JSONEncoder.artifactBackup.encode(record)
            try data.write(to: recordURL(record.id), options: .atomic)
        }

        func prune(keeping count: Int) {
            for record in records().dropFirst(count) {
                try? FileManager.default.removeItem(at: archiveURL(record.id))
                try? FileManager.default.removeItem(at: recordURL(record.id))
            }
        }
    }

    // MARK: - Create and apply

    @MainActor
    static func create(reason: String, environment: ArtifactBackupEnvironment = ArtifactBackupEnvironment(),
                       store: Store? = nil,
                       available: (URL) -> Int64? = PreviewRestorePoints.availableBytes) async throws -> Record {
        let store = store ?? Store(locations: environment.locations)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let largest = store.records().map(\.archiveBytes).max() ?? 0
        if let free = available(store.root), free < largest + freeSpaceReserve {
            throw Failure.diskSpace(needed: largest + freeSpaceReserve, available: free)
        }
        let key = try store.key(create: true)
        let id = UUID()
        let url = store.archiveURL(id)
        let summary: ArtifactBackupSummary
        do {
            summary = try await ArtifactBackupEngine(environment: environment)
                .createArchive(at: url, key: key, sections: sections)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let record = Record(
            id: id, sequence: (store.records().map(\.sequence).max() ?? 0) + 1,
            createdAt: environment.now(), reason: reason,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            archiveBytes: summary.totalBytes,
            sections: summary.sections.sorted { $0.rawValue < $1.rawValue })
        try store.save(record)
        store.prune(keeping: kept)
        return record
    }

    /// Verifies the restore point and parks it; the next normal launch applies
    /// it before any store opens and keeps what it replaced as a checkpoint.
    @MainActor
    static func stage(id: UUID, only requested: Set<ArtifactBackupSection>? = nil,
                      environment: ArtifactBackupEnvironment = ArtifactBackupEnvironment(),
                      store: Store? = nil) async throws -> Record {
        let store = store ?? Store(locations: environment.locations)
        guard let record = store.records().first(where: { $0.id == id }) else {
            throw Failure.unknownRestorePoint(id.uuidString.lowercased())
        }
        let carried = Set(record.sections)
        let chosen = requested.map { $0.intersection(carried) } ?? carried
        guard !chosen.isEmpty else { throw Failure.usage("None of those sections is in this restore point") }
        try await ArtifactBackupEngine(environment: environment)
            .stageRestore(from: store.archiveURL(id), key: store.key(create: false), sections: chosen)
        return record
    }

    static func availableBytes(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Command line

    /// `--restore-point create --reason <text>`, `--restore-point apply <id>
    /// [--sections settings,meetings]` or `--restore-point list`, run from the
    /// app's own executable while Whytap is quit. Prints one JSON object and
    /// exits: 0 done, 1 failed, 2 usage, 3 Whytap is running. Returns false
    /// when the arguments are not a restore point command.
    @MainActor
    static func runCommandLine(_ arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: "--restore-point") else { return false }
        let rest = Array(arguments[(index + 1)...])
        Task { @MainActor in
            let code = await execute(rest)
            exit(code)
        }
        dispatchMain()
    }

    @MainActor
    static func execute(_ arguments: [String],
                        environment: ArtifactBackupEnvironment = ArtifactBackupEnvironment(),
                        store: Store? = nil,
                        otherInstanceRunning: () -> Bool = PreviewRestorePoints.otherInstanceRunning,
                        output: (String) -> Void = { print($0) }) async -> Int32 {
        func emit(_ value: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
            output(String(data: data, encoding: .utf8) ?? "{}")
        }
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let store = store ?? Store(locations: environment.locations)
        do {
            switch arguments.first {
            case "list":
                emit(["restore_points": store.records().map(describe)])
                return 0
            case "create":
                guard !otherInstanceRunning() else { throw Failure.appRunning }
                let record = try await create(reason: value(after: "--reason") ?? "preview install",
                                              environment: environment, store: store)
                emit(["restore_point": describe(record)])
                return 0
            case "apply":
                guard arguments.count > 1, let id = UUID(uuidString: arguments[1]) else {
                    throw Failure.usage("apply needs a restore point ID")
                }
                guard !otherInstanceRunning() else { throw Failure.appRunning }
                var requested: Set<ArtifactBackupSection>?
                if let list = value(after: "--sections") {
                    let names = list.split(separator: ",").map(String.init)
                    let parsed = names.compactMap(ArtifactBackupSection.init(rawValue:))
                    guard parsed.count == names.count else { throw Failure.usage("Unknown section in \(list)") }
                    requested = Set(parsed)
                }
                let record = try await stage(id: id, only: requested, environment: environment, store: store)
                emit(["staged": describe(record),
                      "next": "Launch Whytap normally: the restore is applied before it starts, and the data it replaces is kept as a recovery checkpoint"])
                return 0
            default:
                throw Failure.usage("Use --restore-point create --reason <text>, apply <id> [--sections a,b] or list")
            }
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

    static func otherInstanceRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: BuildConfig.bundleID)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }
}
