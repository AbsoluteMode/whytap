import CryptoKit
import Foundation

/// Every on-disk location a complete backup covers. Legacy roots differ per
/// store (`Sidekey/` for meetings, the bundle id for Monitor, Notify and the
/// Case vault, the prod bundle id for history, `whytap/` for the agent
/// workspace) and must not be "tidied up": changing them would orphan the
/// user's existing data.
struct ArtifactBackupLocations: Sendable {
    var applicationSupport: URL
    var bundleRoot: URL
    var legacyMeetingsRoot: URL
    var agentWorkspace: URL
    /// Where `history.sqlite` and `history-assets` actually live.
    /// `HistoryStoreLocation` hardcodes the prod bundle id, so a beta build
    /// shares the prod history files; composing this path from
    /// `BuildConfig.bundleID` would point a beta backup at a directory the
    /// app never writes.
    var historyRoot: URL

    var meetingsCatalog: URL { legacyMeetingsRoot.appendingPathComponent("Meetings", isDirectory: true) }
    var meetingsStaging: URL { legacyMeetingsRoot.appendingPathComponent("meetings-staging", isDirectory: true) }
    var historyDatabase: URL { historyRoot.appendingPathComponent("history.sqlite", isDirectory: false) }
    var historyAssets: URL { historyRoot.appendingPathComponent("history-assets", isDirectory: true) }
    var caseVault: URL { bundleRoot.appendingPathComponent("case-vault.json.enc", isDirectory: false) }
    var monitorRoot: URL { bundleRoot.appendingPathComponent("Monitor", isDirectory: true) }
    var notifyRoot: URL { bundleRoot.appendingPathComponent("notifications", isDirectory: true) }
    var agentMemory: URL { agentWorkspace.appendingPathComponent("AGENTS.md", isDirectory: false) }
    var plannerArchive: URL { legacyMeetingsRoot.appendingPathComponent("Planner/planner-v1.json") }
    var pendingRestoreRoot: URL { bundleRoot.appendingPathComponent("pending-restore", isDirectory: true) }
    var stagingWorkRoot: URL { bundleRoot.appendingPathComponent("backup-work", isDirectory: true) }
    /// Retained checkpoints of data a finished restore replaced.
    var recoveryRoot: URL { pendingRestoreRoot.appendingPathComponent("recovery", isDirectory: true) }

    static var production: Self {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return Self(
            applicationSupport: support,
            bundleRoot: support.appendingPathComponent(BuildConfig.bundleID, isDirectory: true),
            legacyMeetingsRoot: support.appendingPathComponent("Sidekey", isDirectory: true),
            agentWorkspace: support.appendingPathComponent("whytap", isDirectory: true)
                .appendingPathComponent("agent", isDirectory: true),
            historyRoot: HistoryStoreLocation.defaultURL.deletingLastPathComponent()
        )
    }

    /// Isolated tree for tests and clean-profile recovery checks. The same
    /// relative layout, so the production path rules are what get tested.
    static func isolated(root: URL) -> Self {
        Self(
            applicationSupport: root,
            bundleRoot: root.appendingPathComponent(BuildConfig.bundleID, isDirectory: true),
            legacyMeetingsRoot: root.appendingPathComponent("Sidekey", isDirectory: true),
            agentWorkspace: root.appendingPathComponent("whytap", isDirectory: true)
                .appendingPathComponent("agent", isDirectory: true),
            historyRoot: root.appendingPathComponent(BuildConfig.bundleID, isDirectory: true)
        )
    }
}

// MARK: - Store export seams

struct ArtifactExportedFile: Sendable {
    /// Path inside the archive section, e.g. `db/meetings.sqlite`.
    let relativePath: String
    let url: URL
}

/// A coherent export is a store-level responsibility: SQLite's own snapshot
/// mechanism cannot coordinate the sidecar files a row points at.
protocol ArtifactMeetingsExporting: Sendable {
    func exportArtifactGeneration(into directory: URL) async throws -> [ArtifactExportedFile]
}

// MARK: - Staged generation

enum ArtifactStagedSource: Sendable {
    /// A file inside the immutable staged generation.
    case file(URL)
    /// Secrets and small configurations that must never be written to a
    /// plaintext temporary file.
    case inline(Data)
}

struct ArtifactStagedEntry: Sendable {
    var path: String
    var section: ArtifactBackupSection
    var bytes: Int64
    var sha256: String
    var source: ArtifactStagedSource
}

struct ArtifactInlinePayload: Sendable {
    var path: String
    var section: ArtifactBackupSection
    var data: Data
}

struct ArtifactBackupStageRequest: Sendable {
    var sections: Set<ArtifactBackupSection>
    var locations: ArtifactBackupLocations
    var inline: [ArtifactInlinePayload]
    var includeCaseVaultFile: Bool
    /// The exported vault key, used to prove the staged ciphertext copy opens
    /// with exactly the key the archive carries.
    var caseVaultKey: Data?
    var meetings: ArtifactMeetingsExporting?
    var usage: ArtifactUsageExporting? = nil
}

struct ArtifactBackupGeneration: Sendable {
    var directory: URL
    var entries: [ArtifactStagedEntry]
    var warnings: [String]
    var contentBytes: Int64
}

/// An explicit cache tag, rather than a directory-name guess, identifies
/// disposable worker dependencies such as uv-created Python environments.
/// Only workspace trees honor it.
/// WHY: .project-docs/decisions/2026-10-21-backup-tagged-caches.md
enum ArtifactBackupCache {
    private static let signature = Data("Signature: 8a477f597d28d172789f06886806bc55".utf8)

    static func isTaggedDirectory(_ directory: URL) throws -> Bool {
        let tag = directory.appendingPathComponent("CACHEDIR.TAG", isDirectory: false)
        let descriptor = open(tag.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            if errno == ELOOP { throw ArtifactBackupError.unsafeContent }
            throw ArtifactBackupError.readFailed
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw ArtifactBackupError.readFailed }
        guard metadata.st_mode & S_IFMT == S_IFREG else { return false }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do { return try file.read(upToCount: signature.count) == signature }
        catch { throw ArtifactBackupError.readFailed }
    }
}

/// Off-main worker. Staging, hashing and the encrypted write all happen on
/// this actor's executor, so a large backup never blocks the UI.
///
/// Coverage rule: an application-owned file that exists but cannot be included
/// fails the backup. Only bytes the app does not own (scripts and credentials
/// living outside our roots) are reported as warnings.
/// WHY: .project-docs/decisions/2026-10-19-config-backup.md
actor ArtifactBackupStager {
    private let fileManager = FileManager.default

    /// Sanity ceilings. Hitting one fails the backup instead of trimming it.
    private enum Limit {
        static let caseVault: Int64 = 8 * 1024 * 1024
        static let workspaceFile: Int64 = 8 * 1024 * 1024
        static let workspaceFiles = 2048
        static let workspaceTotal: Int64 = 512 * 1024 * 1024
        /// Relative directory depth the archive paths can carry. A deeper
        /// owned tree fails the backup, naming the path, instead of being
        /// trimmed out of a "complete" snapshot.
        static let workspaceDepth = 5
        static let agentMemory: Int64 = 8 * 1024 * 1024
    }

    /// Older archives carried retained recordings. Their provider job state is
    /// still refused on restore: a restored copy must not resume a
    /// transcription job that belongs to the original Mac.
    static func isRecordingRuntimeFile(_ relative: String) -> Bool {
        guard !relative.contains("/") else { return false }
        let name = relative.lowercased()
        return name == "soniox-transcription.json" || (name.hasPrefix("soniox-upload-") && name.hasSuffix(".tmp"))
    }

    /// Finder and the OS drop these into any directory the user browses. They
    /// are not application data, so they are skipped rather than failing a
    /// backup — every other unexpected name still fails, by name.
    private static let systemMetadataNames: Set<String> = [".DS_Store", ".localized", "Icon\r"]

    func stage(_ request: ArtifactBackupStageRequest) async throws -> ArtifactBackupGeneration {
        guard !request.sections.isEmpty else { throw ArtifactBackupError.nothingSelected }
        let directory = request.locations.stagingWorkRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createPrivateDirectory(request.locations.stagingWorkRoot)
        try createPrivateDirectory(directory)
        do {
            var entries: [ArtifactStagedEntry] = []
            var warnings: [String] = []
            for payload in request.inline {
                try ArtifactBackupPath.validate(payload.path)
                guard request.sections.contains(payload.section) else { throw ArtifactBackupError.damaged }
                guard Int64(payload.data.count) <= ArtifactBackupManifest.maxInlineBytes else {
                    throw ArtifactBackupError.tooLarge
                }
                entries.append(ArtifactStagedEntry(
                    path: payload.path, section: payload.section,
                    bytes: Int64(payload.data.count), sha256: ArtifactBackupDigest.of(payload.data),
                    source: .inline(payload.data)))
            }
            if request.sections.contains(.caseVault), request.includeCaseVaultFile {
                entries.append(try stageCaseVault(request, into: directory))
            }
            // Check worker paths before copying large meeting generations.
            if request.sections.contains(.workspace) {
                entries.append(contentsOf: try stageWorkspace(request, into: directory,
                                                              warnings: &warnings))
            }
            if request.sections.contains(.meetings) {
                entries.append(contentsOf: try await stageMeetings(request, into: directory))
            }
            if request.sections.contains(.history) {
                entries.append(contentsOf: try await stageHistory(request, into: directory))
            }
            if request.sections.contains(.planner), fileManager.fileExists(atPath: request.locations.plannerArchive.path) {
                let copy = directory.appendingPathComponent("planner-v1.json")
                _ = try copyStable(request.locations.plannerArchive, to: copy,
                                   limit: ArtifactBackupManifest.maxInlineBytes, required: true)
                _ = try PlannerStore.decodeArchive(Data(contentsOf: copy))
                entries.append(try entry(for: copy, path: "planner/planner-v1.json", section: .planner))
            }
            entries = try Self.ordered(entries)
            let total = entries.reduce(Int64(0)) { $0 + $1.bytes }
            guard total <= ArtifactBackupManifest.maxTotalBytes else { throw ArtifactBackupError.tooLarge }
            return ArtifactBackupGeneration(directory: directory, entries: entries,
                                            warnings: warnings, contentBytes: total)
        } catch {
            discard(directory)
            throw error
        }
    }

    func discard(_ directory: URL) {
        guard directory.lastPathComponent.count == 36 else { return }
        try? fileManager.removeItem(at: directory)
    }

    func cleanupAbandonedWork(at root: URL) throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        try validateOwnedRoot(root)
        for item in try listDirectory(root) where UUID(uuidString: item.lastPathComponent) != nil {
            let values = try resourceValues(item)
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try Task.checkCancellation()
            try fileManager.removeItem(at: item)
        }
        try ConfigBackupFiles.synchronizeDirectory(root)
    }

    /// Inline entries first, then files; both deterministic. The restore path
    /// validates every inline payload before it moves a single target, and a
    /// stable prefix lets it do that by reading only the head of the archive.
    /// Logical paths must also not collide when compared case-insensitively:
    /// APFS is case-insensitive by default, so two such entries would be one
    /// file on the restored Mac.
    static func ordered(_ entries: [ArtifactStagedEntry]) throws -> [ArtifactStagedEntry] {
        var seen = Set<String>()
        for entry in entries {
            // Never write an archive that our own restore cannot consume.
            do { _ = try ArtifactRestoreDestination.resolve(entry.path, in: .production) }
            catch ArtifactBackupError.unsafeContent { throw ArtifactBackupError.unsupportedFile(entry.path) }
            guard seen.insert(entry.path.lowercased()).inserted else {
                throw ArtifactBackupError.unsafeContent
            }
        }
        let inline = entries.filter { ArtifactRestoreDestination.isInlinePath($0.path) }
        let files = entries.filter { !ArtifactRestoreDestination.isInlinePath($0.path) }
        return inline.sorted { $0.path < $1.path } + files.sorted { $0.path < $1.path }
    }

    // MARK: Validation and transaction staging (off the main thread)

    /// The verification generation always lives in our own private work root,
    /// never next to a user-chosen archive file.
    func verifyArchive(at url: URL, archiveKey: Data,
                       sections: Set<ArtifactBackupSection>? = nil,
                       scratchRoot: URL) throws -> ArtifactArchiveVerification {
        let directory = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createPrivateDirectory(scratchRoot)
        try createPrivateDirectory(directory)
        defer { discard(directory) }
        return try ArtifactArchiveVerifier.verify(archiveAt: url, key: archiveKey,
                                                  sections: sections, scratch: directory)
    }

    func stageArchiveCopy(from source: URL, to destination: URL, archiveKey: Data,
                          manifestID: UUID) throws -> (digest: String, bytes: Int64) {
        try ArtifactRestoreTransaction.stageArchiveCopy(from: source, to: destination,
                                                        key: archiveKey, manifestID: manifestID)
    }

    // MARK: Archive writing

    /// Streams the manifest and every entry into one authenticated archive.
    /// Returns the archive's size on disk, which is what a transport uploads.
    func writeArchive(to url: URL, archiveKey: Data, manifest: ArtifactBackupManifest,
                      entries: [ArtifactStagedEntry]) throws -> Int64 {
        let manifestData = try manifest.encoded()
        let index = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let writer = try ArtifactArchiveWriter(url: url, archiveKey: archiveKey)
        do {
            try writer.append(Data(ArtifactArchiveHeader.bigEndian32(UInt32(manifestData.count))))
            try writer.append(manifestData)
            for entry in manifest.entries {
                guard let staged = index[entry.path] else { throw ArtifactBackupError.readFailed }
                switch staged.source {
                case .inline(let data):
                    guard Int64(data.count) == entry.bytes else { throw ArtifactBackupError.readFailed }
                    try writer.append(data)
                case .file(let file):
                    // The staged generation is immutable; a size or digest
                    // change here means something is still writing and the
                    // archive would not match its manifest.
                    let check = try? ArtifactBackupDigest.ofFile(file)
                    guard let check, check.bytes == entry.bytes, check.digest == entry.sha256 else {
                        throw ArtifactBackupError.contentChanged(file.lastPathComponent)
                    }
                    try writer.append(contentsOf: file)
                }
            }
            try writer.finish()
        } catch {
            writer.cancel()
            throw error
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(size)
    }

    // MARK: Sections

    /// Case travels as its own ciphertext plus its key, and the staged copy is
    /// proven to open with that exact key: a vault reset or key rotation that
    /// lands between the pre-check and the copy would otherwise produce a
    /// successful backup nobody can open.
    private func stageCaseVault(_ request: ArtifactBackupStageRequest, into directory: URL) throws -> ArtifactStagedEntry {
        guard let keyData = request.caseVaultKey, keyData.count == 32 else {
            throw ArtifactBackupError.caseUnreadable
        }
        let staged = directory.appendingPathComponent("case", isDirectory: true)
        try createPrivateDirectory(staged)
        let copy = staged.appendingPathComponent("vault.enc", isDirectory: false)
        _ = try copyStable(request.locations.caseVault, to: copy, limit: Limit.caseVault, required: true)
        let payload: CaseVaultPayload
        do { payload = try CaseVaultStore.decode(envelope: try Data(contentsOf: copy),
                                                 using: SymmetricKey(data: keyData)) }
        catch { throw ArtifactBackupError.caseUnreadable }
        guard payload.schemaVersion <= CaseVaultPayload.currentSchemaVersion else {
            throw ArtifactBackupError.caseUnreadable
        }
        return try entry(for: copy, path: "case/vault.enc", section: .caseVault)
    }

    /// Meeting notes, transcripts and the catalog only. Audio never travels:
    /// a retained recording is debugging material, and gigabytes of it made
    /// every snapshot huge. The history database (clipboard, recent dictations
    /// and agent answers) is left out too; the history section carries Costs.
    /// WHY: .project-docs/decisions/2026-10-21-backup-essentials-only.md
    private func stageMeetings(_ request: ArtifactBackupStageRequest, into directory: URL) async throws -> [ArtifactStagedEntry] {
        guard let exporter = request.meetings else { throw ArtifactBackupError.missingSection }
        let staged = directory.appendingPathComponent("meetings", isDirectory: true)
        try createPrivateDirectory(staged)
        return try await exporter.exportArtifactGeneration(into: staged).map {
            try entry(for: $0.url, path: "meetings/" + $0.relativePath, section: .meetings)
        }
    }

    private func stageHistory(_ request: ArtifactBackupStageRequest, into directory: URL) async throws -> [ArtifactStagedEntry] {
        let staged = directory.appendingPathComponent("history", isDirectory: true)
        try createPrivateDirectory(staged)
        guard let file = try await request.usage?.exportArtifactGeneration(into: staged.appendingPathComponent("db")) else {
            return []
        }
        return [try entry(for: file, path: ArtifactUsageBackup.archivePath, section: .history)]
    }

    /// Monitor and Notify own whole private directories: dashboards, server
    /// configuration, source manifests, logos, worker scripts (nested) and the
    /// cursors/session files those scripts keep. Everything app-owned travels;
    /// executables referenced outside these roots do not, and say so.
    private func stageWorkspace(_ request: ArtifactBackupStageRequest, into directory: URL,
                                warnings: inout [String]) throws -> [ArtifactStagedEntry] {
        let staged = directory.appendingPathComponent("workspace", isDirectory: true)
        try createPrivateDirectory(staged)
        var entries: [ArtifactStagedEntry] = []
        entries.append(contentsOf: try stageOwnedTree(request.locations.monitorRoot, into: staged,
                                                      prefix: "monitor", warnings: &warnings))
        entries.append(contentsOf: try stageOwnedTree(request.locations.notifyRoot, into: staged,
                                                      prefix: "notify", warnings: &warnings))
        // Only the real AGENTS.md. `CLAUDE.md` is a symlink alias and the
        // `.opencode-runtime` directory, caches and session state are runtime,
        // not user content.
        let memory = request.locations.agentMemory
        if fileManager.fileExists(atPath: memory.path) {
            let copy = staged.appendingPathComponent("agent", isDirectory: true)
                .appendingPathComponent("AGENTS.md", isDirectory: false)
            try createPrivateDirectory(copy.deletingLastPathComponent())
            _ = try copyStable(memory, to: copy, limit: Limit.agentMemory, required: true)
            entries.append(try entry(for: copy, path: "workspace/agent/AGENTS.md", section: .workspace))
        }
        warnings.append(contentsOf: workspaceNotes(for: entries, staged: staged))
        return entries
    }

    /// What a restore of this section will and will not do. These are
    /// statements about unowned bytes and deliberate inertness, never a
    /// substitute for including something we do own.
    private func workspaceNotes(for entries: [ArtifactStagedEntry], staged: URL) -> [String] {
        var notes: [String] = []
        let paths = Set(entries.map(\.path))
        if paths.contains("workspace/monitor/servers.json") {
            notes.append("Restored server monitoring arrives switched off until you turn it back on, and it uses this Mac's SSH keys and credential tool — those are never inside a backup.")
        }
        let sources = paths.filter { $0.hasPrefix("workspace/notify/sources/") && $0.hasSuffix(".json") }
        if !sources.isEmpty {
            notes.append("Restored notification sources arrive switched off. Turn the ones you want back on in Settings → Features → Notify.")
            var external = 0
            for path in sources.sorted() {
                let file = staged.appendingPathComponent(String(path.dropFirst("workspace/".count)))
                guard let data = try? Data(contentsOf: file),
                      let script = try? JSONDecoder().decode(NotifyScript.self, from: data),
                      let executable = script.command.first else { continue }
                if !executable.hasPrefix(staged.path), !isInsideNotifyRoot(executable) { external += 1 }
            }
            if external > 0 {
                notes.append("\(external) notification source(s) run a program from outside Whytap's own folder. That program is not inside this backup.")
            }
        }
        if paths.contains(where: { $0.hasPrefix("workspace/notify/workers/") }) {
            notes.append("Notification scripts are restored as read-only files. If a source starts a script directly, make it executable again on the new Mac.")
        }
        return notes
    }

    private func isInsideNotifyRoot(_ executable: String) -> Bool {
        executable.contains("/notifications/")
    }

    private func stageOwnedTree(_ root: URL, into staged: URL, prefix: String,
                                warnings: inout [String]) throws -> [ArtifactStagedEntry] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        do { try validateOwnedRoot(root) }
        catch ArtifactBackupError.unsafeContent { throw ArtifactBackupError.unsupportedFile(prefix == "notify" ? "Notifications" : "Monitor") }
        var entries: [ArtifactStagedEntry] = []
        var total: Int64 = 0
        var excludedCaches = 0
        var retainedConfigurations = 0
        var retentionIndex = 0
        while fileManager.fileExists(atPath: root.appendingPathComponent("restored-files-retained-\(retentionIndex)").path) {
            retentionIndex += 1
        }
        let retentionFolder = "restored-files-retained-\(retentionIndex)"
        try walk(root, relative: "", depth: 1, maxDepth: Limit.workspaceDepth,
                 pathLabel: prefix == "notify" ? "Notifications" : "Monitor", skipDirectory: { directory in
            guard try ArtifactBackupCache.isTaggedDirectory(directory) else { return false }
            excludedCaches += 1
            return true
        }) { file, relative in
            guard entries.count < Limit.workspaceFiles else { throw ArtifactBackupError.tooLarge }
            let pairedOriginal: String?
            if prefix == "monitor", relative == "servers.json" + ArtifactRestoreDestination.parkedSuffix {
                pairedOriginal = "servers.json"
            } else if prefix == "notify", relative.hasPrefix("sources/"), relative.split(separator: "/").count == 2,
                      relative.hasSuffix(ArtifactRestoreDestination.invalidSuffix) {
                pairedOriginal = String(relative.dropLast(ArtifactRestoreDestination.invalidSuffix.count))
            } else { pairedOriginal = nil }
            let archivedRelative: String
            if let original = pairedOriginal, self.fileManager.fileExists(atPath: root.appendingPathComponent(original).path) {
                // Preserve both generations without making them resolve to the
                // same inactive destination. Runtime loaders ignore this folder.
                archivedRelative = retentionFolder + "/" + file.lastPathComponent
                retainedConfigurations += 1
            } else { archivedRelative = relative }
            let copy = staged.appendingPathComponent(prefix + "/" + archivedRelative, isDirectory: false)
            try self.createPrivateDirectory(copy.deletingLastPathComponent())
            let bytes = try self.copyStable(file, to: copy, limit: Limit.workspaceFile, required: true)
            total += bytes
            guard total <= Limit.workspaceTotal else { throw ArtifactBackupError.tooLarge }
            entries.append(try self.entry(for: copy, path: "workspace/" + prefix + "/" + archivedRelative,
                                          section: .workspace))
        }
        if excludedCaches > 0 {
            warnings.append("\(excludedCaches) explicitly tagged cache folder(s) are not included. Recreate cached dependencies before enabling restored notification or monitoring scripts.")
        }
        if retainedConfigurations > 0 {
            warnings.append("Earlier inactive configurations are kept separately in restored-files folders. They remain inactive after recovery.")
        }
        return entries
    }

    // MARK: File helpers

    /// Depth-limited walk of an application-owned directory. Nothing is
    /// skipped quietly: callers may explicitly exclude tagged caches. A link,
    /// an unexpected file type, an unusable name, a directory deeper than the
    /// format supports or an unreadable directory all fail the backup.
    private func walk(_ directory: URL, relative: String, depth: Int, maxDepth: Int,
                      pathLabel: String,
                      skipDirectory: (URL) throws -> Bool = { _ in false },
                      visit: (URL, String) throws -> Void) throws {
        for item in try listDirectory(directory).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = item.lastPathComponent
            if Self.systemMetadataNames.contains(name) { continue }
            let values = try resourceValues(item)
            let child = relative.isEmpty ? name : relative + "/" + name
            let displayedPath = pathLabel + "/" + child
            guard values.isSymbolicLink != true else { throw ArtifactBackupError.unsupportedFile(displayedPath) }
            if values.isDirectory == true {
                do { if try skipDirectory(item) { continue } }
                catch ArtifactBackupError.unsafeContent { throw ArtifactBackupError.unsupportedFile(displayedPath + "/CACHEDIR.TAG") }
                guard depth < maxDepth else { throw ArtifactBackupError.invalidContent(child) }
                guard Self.isUsableName(name) else { throw ArtifactBackupError.unsupportedFile(displayedPath) }
                try walk(item, relative: child, depth: depth + 1, maxDepth: maxDepth,
                         pathLabel: pathLabel, skipDirectory: skipDirectory, visit: visit)
                continue
            }
            guard values.isRegularFile == true, Self.isUsableName(name) else {
                throw ArtifactBackupError.unsupportedFile(displayedPath)
            }
            try visit(item, child)
        }
    }

    private func listDirectory(_ directory: URL) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                             .fileSizeKey, .contentModificationDateKey],
                // No `skipsHiddenFiles`: an unexpected hidden entry must be
                // reported by name, not quietly left out of a "complete" backup.
                options: [])
        } catch { throw ArtifactBackupError.readFailed }
    }

    private func resourceValues(_ url: URL) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                                    .fileSizeKey, .contentModificationDateKey])
        } catch { throw ArtifactBackupError.readFailed }
    }

    /// Archive paths are ASCII by construction, so a name the format cannot
    /// carry fails rather than disappearing from a "complete" backup.
    static func isUsableName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 120 && name != "." && name != ".."
            && !name.hasPrefix(".") && !name.contains("/")
            && name.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && $0 != ":" }
    }

    private func entry(for file: URL, path: String, section: ArtifactBackupSection) throws -> ArtifactStagedEntry {
        try ArtifactBackupPath.validate(path)
        let digest = try ArtifactBackupDigest.ofFile(file)
        return ArtifactStagedEntry(path: path, section: section, bytes: digest.bytes,
                                   sha256: digest.digest, source: .file(file))
    }

    /// Copies an owned file and proves the source did not change underneath:
    /// a chunk that grew while being read would archive a torn file.
    @discardableResult
    private func copyStable(_ source: URL, to destination: URL, limit: Int64, required: Bool) throws -> Int64 {
        let before = try resourceValues(source)
        guard before.isRegularFile == true, before.isSymbolicLink != true else {
            if required { throw ArtifactBackupError.requiredFileMissing(source.lastPathComponent) }
            return 0
        }
        let size = Int64(before.fileSize ?? 0)
        guard size <= limit else { throw ArtifactBackupError.tooLarge }
        if fileManager.fileExists(atPath: destination.path) { try? fileManager.removeItem(at: destination) }
        do { try fileManager.copyItem(at: source, to: destination) }
        catch { throw ArtifactBackupError.requiredFileMissing(source.lastPathComponent) }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let after = try resourceValues(source)
        let copied = try resourceValues(destination)
        guard after.fileSize == before.fileSize,
              after.contentModificationDate == before.contentModificationDate,
              copied.fileSize == before.fileSize else {
            throw ArtifactBackupError.contentChanged(source.lastPathComponent)
        }
        return size
    }

    /// An owned root and every existing ancestor must be a real directory.
    /// A symlinked root would let a same-user attacker redirect the backup at
    /// files the app does not own.
    private func validateOwnedRoot(_ directory: URL) throws {
        let values = try resourceValues(directory)
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ArtifactBackupError.unsafeContent
        }
        try Self.validateAncestors(of: directory)
    }

    static func validateAncestors(of directory: URL) throws {
        var existing = directory.standardizedFileURL
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            existing.deleteLastPathComponent()
        }
        // Reuses the hardened semantics already used for settings archives:
        // real directories only, apart from Darwin's own /var and /tmp
        // aliases, and never a user-created link.
        do { try ConfigBackupFiles.checkDirectory(existing) }
        catch { throw ArtifactBackupError.unsafeContent }
    }

    @discardableResult
    private func createPrivateDirectory(_ directory: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let values = try resourceValues(directory)
            guard isDirectory.boolValue, values.isSymbolicLink != true else {
                throw ArtifactBackupError.unsafeContent
            }
            return true
        }
        try Self.validateAncestors(of: directory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch { throw ArtifactBackupError.writeFailed }
        return true
    }
}
