import CryptoKit
import Darwin
import Foundation

/// Same-Mac restore: a byte-exact copy of the owner's settings domain and of the
/// Application Support folders listed in `roots`, made with Whytap quit and put back
/// verbatim by the startup restore transaction (`ArtifactRestoreTransaction` with
/// `ArtifactRestorePlan.localSnapshot`). It exists only for preview restore points.
///
/// It is deliberately a separate path from the cross-Mac backup import, which makes
/// a restored configuration inert on purpose (parked Monitor servers, disabled
/// Notify sources, files written 0600, an allowlist of preferences). A same-Mac
/// rollback must give back exactly what this Mac had, so nothing here is parked,
/// filtered or rewritten: directories, regular files with their permission bits,
/// and symbolic links as links. The snapshot never holds provider keys (Keychain),
/// the Case vault, Harness access, History, meeting audio, models or backups.
/// WHY: .project-docs/decisions/2026-11-26-preview-restore-points.md
enum LocalRestoreSnapshot {
    static let schema = 1
    static let manifestName = "manifest.json"
    static let preferencesName = "preferences.plist"
    static let filesName = "files"
    static let maxEntries = 500_000
    static let maxBytes: Int64 = 1 << 40
    /// Preferences a restore never changes: backup and settings-sync bookkeeping
    /// (`backup.`) and the updater's state (`SU`). Rolling them back would make
    /// those services act on a past they already left.
    static let preservedPreferencePrefixes = ["backup.", "SU"]

    struct Root: Equatable, Sendable {
        let id: String
        let section: ArtifactBackupSection
        let url: URL
    }

    /// What a restore point covers, per section. A root that does not exist at
    /// capture is recorded as absent, so a rollback removes what a preview created.
    static func roots(_ locations: ArtifactBackupLocations) -> [Root] {
        let whytap = locations.agentWorkspace.deletingLastPathComponent()
        var roots = [
            Root(id: "drop-learning", section: .settings,
                 url: locations.bundleRoot.appendingPathComponent("drop-learning", isDirectory: true)),
            Root(id: "meetings", section: .meetings, url: locations.meetingsCatalog),
            Root(id: "meeting-spaces", section: .meetings,
                 url: whytap.appendingPathComponent("meeting-spaces", isDirectory: true)),
            Root(id: "planner", section: .planner, url: locations.plannerArchive.deletingLastPathComponent()),
            Root(id: "monitor", section: .workspace, url: locations.monitorRoot),
            Root(id: "notifications", section: .workspace, url: locations.notifyRoot),
            Root(id: "agent", section: .workspace, url: locations.agentWorkspace),
            Root(id: "project-agents", section: .workspace,
                 url: whytap.appendingPathComponent("project-agents", isDirectory: true)),
            Root(id: "projects", section: .workspace,
                 url: locations.bundleRoot.appendingPathComponent("projects", isDirectory: true)),
        ]
        // Costs: the database and its companions, merged with what was spent while
        // the preview ran (that spending really happened).
        for (index, target) in ArtifactUsageBackup.checkpointTargets(locations: locations).enumerated() {
            roots.append(Root(id: ["usage", "usage-journal", "usage-wal", "usage-shm"][index],
                              section: .history, url: target))
        }
        return roots
    }

    static let sections: Set<ArtifactBackupSection> = [.settings, .meetings, .history, .workspace, .planner]

    struct Entry: Codable, Equatable {
        enum Kind: String, Codable { case directory, file, symlink }
        var root: String
        /// Relative to the root; "" is the root itself.
        var path: String
        var kind: Kind
        var mode: UInt16
        var bytes: Int64
        var sha256: String?
        var target: String?
    }

    struct Manifest: Codable, Equatable {
        var schema: Int
        var id: UUID
        var createdAt: Date
        var sections: [ArtifactBackupSection]
        /// Roots that existed at capture. A covered root missing here is removed
        /// by a restore.
        var presentRoots: [String]
        var entries: [Entry]
        var totalBytes: Int64
        /// Digest of `preferences.plist`, when settings were captured.
        var preferencesSHA256: String?
        var warnings: [String]
    }

    // MARK: Capture

    /// Copies the covered roots into `directory` (APFS clones where possible) and
    /// the settings domain into `preferences.plist`. The caller holds the instance
    /// lease, so no Whytap process writes meanwhile.
    static func capture(into directory: URL, sections wanted: Set<ArtifactBackupSection>,
                        locations: ArtifactBackupLocations, defaults: UserDefaults,
                        domain: String, now: Date) throws -> Manifest {
        let sections = wanted.intersection(Self.sections)
        guard !sections.isEmpty else { throw ArtifactBackupError.nothingSelected }
        let files = directory.appendingPathComponent(filesName, isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var entries: [Entry] = []
        var present: [String] = []
        var warnings: [String] = []
        var total: Int64 = 0
        for root in roots(locations) where sections.contains(root.section) {
            var info = stat()
            guard lstat(root.url.path, &info) == 0 else {
                guard errno == ENOENT else { throw ArtifactBackupError.readFailed }
                continue
            }
            // A covered root is never a link: a restore would write through it.
            guard info.st_mode & S_IFMT == S_IFDIR || info.st_mode & S_IFMT == S_IFREG else {
                throw ArtifactBackupError.unsafeContent
            }
            present.append(root.id)
            try copy(root.url, rootID: root.id, relative: "",
                     into: files.appendingPathComponent(root.id), entries: &entries,
                     total: &total, warnings: &warnings)
        }
        var preferencesDigest: String?
        if sections.contains(.settings) {
            let values = (defaults.persistentDomain(forName: domain) ?? [:])
                .filter { key, _ in !isPreserved(key) }
            let data: Data
            do { data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) }
            catch { throw ArtifactBackupError.writeFailed }
            let url = directory.appendingPathComponent(preferencesName)
            guard FileManager.default.createFile(atPath: url.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw ArtifactBackupError.writeFailed
            }
            preferencesDigest = ArtifactBackupDigest.hex(SHA256.hash(data: data))
        }
        let manifest = Manifest(schema: schema, id: UUID(), createdAt: now,
                                sections: sections.sorted { $0.rawValue < $1.rawValue },
                                presentRoots: present, entries: entries, totalBytes: total,
                                preferencesSHA256: preferencesDigest, warnings: Array(warnings.prefix(32)))
        let data = try JSONEncoder.artifactBackup.encode(manifest)
        guard FileManager.default.createFile(atPath: directory.appendingPathComponent(manifestName).path,
                                             contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ArtifactBackupError.writeFailed
        }
        return manifest
    }

    static func isPreserved(_ key: String) -> Bool {
        preservedPreferencePrefixes.contains { key.hasPrefix($0) }
    }

    private static func copy(_ source: URL, rootID: String, relative: String, into destination: URL,
                             entries: inout [Entry], total: inout Int64, warnings: inout [String]) throws {
        guard entries.count < maxEntries else { throw ArtifactBackupError.tooLarge }
        var info = stat()
        guard lstat(source.path, &info) == 0 else { throw ArtifactBackupError.readFailed }
        let mode = UInt16(info.st_mode & 0o7777)
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            entries.append(Entry(root: rootID, path: relative, kind: .directory, mode: mode, bytes: 0))
            let names = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
            for name in names {
                try copy(source.appendingPathComponent(name), rootID: rootID,
                         relative: relative.isEmpty ? name : relative + "/" + name,
                         into: destination.appendingPathComponent(name), entries: &entries,
                         total: &total, warnings: &warnings)
            }
        case S_IFREG:
            // copyfile clones on APFS: no extra space until either copy changes.
            guard Darwin.copyfile(source.path, destination.path, nil,
                                  copyfile_flags_t(COPYFILE_CLONE | COPYFILE_DATA | COPYFILE_EXCL)) == 0 else {
                throw ArtifactBackupError.readFailed
            }
            guard chmod(destination.path, 0o600) == 0 else { throw ArtifactBackupError.writeFailed }
            let digest = try ArtifactBackupDigest.ofFile(destination)
            let (sum, overflow) = total.addingReportingOverflow(digest.bytes)
            guard !overflow, sum <= maxBytes else { throw ArtifactBackupError.tooLarge }
            total = sum
            entries.append(Entry(root: rootID, path: relative, kind: .file, mode: mode,
                                 bytes: digest.bytes, sha256: digest.digest))
        case S_IFLNK:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            entries.append(Entry(root: rootID, path: relative, kind: .symlink, mode: mode, bytes: 0,
                                 target: target))
        default:
            // Sockets and pipes are runtime endpoints, recreated by their owners.
            warnings.append("Skipped a special file in \(rootID)")
        }
    }

    // MARK: Verify

    /// Reads and checks the whole snapshot against its manifest (names, numbers,
    /// kinds, sizes and digests) before anything on this Mac changes.
    static func verify(_ directory: URL, locations: ArtifactBackupLocations) throws -> Manifest {
        let manifest = try readManifest(directory)
        let known = Dictionary(uniqueKeysWithValues: roots(locations).map { ($0.id, $0) })
        let files = directory.appendingPathComponent(filesName, isDirectory: true)
        var seen = Set<String>()
        for entry in manifest.entries {
            guard let root = known[entry.root], manifest.sections.contains(root.section),
                  manifest.presentRoots.contains(entry.root),
                  seen.insert(entry.root + "/" + entry.path).inserted else { throw ArtifactBackupError.damaged }
            let url = entry.path.isEmpty ? files.appendingPathComponent(entry.root)
                : files.appendingPathComponent(entry.root).appendingPathComponent(entry.path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw ArtifactBackupError.requiredFileMissing(entry.path) }
            switch entry.kind {
            case .directory:
                guard info.st_mode & S_IFMT == S_IFDIR else { throw ArtifactBackupError.damaged }
            case .file:
                guard info.st_mode & S_IFMT == S_IFREG else { throw ArtifactBackupError.damaged }
                let digest = try ArtifactBackupDigest.ofFile(url)
                guard digest.bytes == entry.bytes, digest.digest == entry.sha256 else {
                    throw ArtifactBackupError.damaged
                }
            case .symlink:
                guard info.st_mode & S_IFMT == S_IFLNK,
                      (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == entry.target else {
                    throw ArtifactBackupError.damaged
                }
            }
        }
        for id in manifest.presentRoots where !seen.contains(id + "/") { throw ArtifactBackupError.damaged }
        if manifest.sections.contains(.settings) {
            let data = try Data(contentsOf: directory.appendingPathComponent(preferencesName))
            guard ArtifactBackupDigest.hex(SHA256.hash(data: data)) == manifest.preferencesSHA256 else {
                throw ArtifactBackupError.damaged
            }
        }
        return manifest
    }

    /// The manifest, with every number and name validated before use.
    static func readManifest(_ directory: URL) throws -> Manifest {
        let url = directory.appendingPathComponent(manifestName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.int64Value <= 256 * 1024 * 1024 else {
            throw ArtifactBackupError.damaged
        }
        let manifest: Manifest
        do { manifest = try JSONDecoder.artifactBackup.decode(Manifest.self, from: Data(contentsOf: url)) }
        catch { throw ArtifactBackupError.damaged }
        guard manifest.schema == schema, !manifest.sections.isEmpty,
              Set(manifest.sections).isSubset(of: sections),
              manifest.entries.count <= maxEntries,
              (0...maxBytes).contains(manifest.totalBytes) else { throw ArtifactBackupError.damaged }
        var total: Int64 = 0
        for entry in manifest.entries {
            guard (0...maxBytes).contains(entry.bytes), entry.mode <= 0o7777, isSafeRelative(entry.path),
                  entry.kind != .file || entry.sha256?.count == 64,
                  entry.kind != .symlink || entry.target != nil else { throw ArtifactBackupError.damaged }
            let (sum, overflow) = total.addingReportingOverflow(entry.bytes)
            guard !overflow else { throw ArtifactBackupError.damaged }
            total = sum
        }
        guard total == manifest.totalBytes,
              manifest.sections.contains(.settings) == (manifest.preferencesSHA256 != nil) else {
            throw ArtifactBackupError.damaged
        }
        return manifest
    }

    private static func isSafeRelative(_ path: String) -> Bool {
        if path.isEmpty { return true }
        return path.count <= 4096 && path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }
    }

    static func preferences(in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(preferencesName))
        guard let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            as? [String: Any] else { throw ArtifactBackupError.damaged }
        return values
    }

    // MARK: Install

    /// Puts one root back exactly as captured. The target must not exist: the
    /// transaction has moved the current one aside into its checkpoint.
    static func install(_ root: Root, from directory: URL, manifest: Manifest) throws {
        let source = directory.appendingPathComponent(filesName, isDirectory: true)
            .appendingPathComponent(root.id)
        let entries = manifest.entries.filter { $0.root == root.id }
        guard entries.first?.path == "" else { throw ArtifactBackupError.damaged }
        try FileManager.default.createDirectory(at: root.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var directories: [(URL, UInt16)] = []
        for entry in entries {
            let from = entry.path.isEmpty ? source : source.appendingPathComponent(entry.path)
            let to = entry.path.isEmpty ? root.url : root.url.appendingPathComponent(entry.path)
            switch entry.kind {
            case .directory:
                try FileManager.default.createDirectory(at: to, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                directories.append((to, entry.mode))
            case .file:
                guard Darwin.copyfile(from.path, to.path, nil,
                                      copyfile_flags_t(COPYFILE_CLONE | COPYFILE_DATA | COPYFILE_EXCL)) == 0,
                      chmod(to.path, mode_t(entry.mode)) == 0 else { throw ArtifactBackupError.writeFailed }
                let digest = try ArtifactBackupDigest.ofFile(to)
                guard digest.bytes == entry.bytes, digest.digest == entry.sha256 else {
                    throw ArtifactBackupError.damaged
                }
            case .symlink:
                try FileManager.default.createSymbolicLink(atPath: to.path, withDestinationPath: entry.target ?? "")
            }
        }
        // Directory modes last and deepest first: a read-only directory still
        // received its contents.
        for (url, mode) in directories.reversed() {
            guard chmod(url.path, mode_t(mode)) == 0 else { throw ArtifactBackupError.writeFailed }
        }
        try ConfigBackupFiles.synchronizeDirectory(root.url.deletingLastPathComponent())
    }

    /// Everything a same-Mac restore of `sections` moves aside first. Costs
    /// companions are included only when the snapshot carries the database.
    static func checkpointTargets(for sections: Set<ArtifactBackupSection>,
                                  locations: ArtifactBackupLocations) -> [URL] {
        roots(locations).filter { sections.contains($0.section) }.map(\.url)
    }
}
