import CryptoKit
import Foundation

/// GitHub receives only an already encrypted archive. Authentication and the
/// recovery credential are separate; no secret enters a URL or process argv.
actor GitHubBackupTransport {
    // New connections create Whytap-Backup; an existing Exodia-Backup keeps
    // being used, and archive markers survive the product rename.
    // WHY: .project-docs/decisions/2026-11-21-whytap-backup-repository.md
    static let repository = "Whytap-Backup"
    static let legacyRepository = "Exodia-Backup"
    /// The defaults key that remembers which of the two this Mac uses. A
    /// connection saved before it existed is an Exodia-Backup connection.
    static let repositoryDefaultsKey = "backup.github-repository.v1"
    static let partBytes = 16 * 1024 * 1024
    // GitHub permits 1,000 assets per release. Reserve one for the index;
    // grow individual parts for large archives while bounding memory.
    static let maximumParts = 999
    static let maximumPartBytes = 128 * 1024 * 1024
    private static let marker = "exodia.encrypted-backup.v1"
    private let session: URLSession
    private let token: String
    private let owner: String
    let repositoryName: String

    enum Failure: Error, LocalizedError, Equatable {
        case authentication, permission, publicRepository, unavailable, invalidResponse, incomplete, noCLI, noLogin
        case rateLimited(until: Date)
        var requiresReconnect: Bool { [.authentication, .permission, .publicRepository].contains(self) }
        var errorDescription: String? {
            switch self {
            case .authentication: return "GitHub could not sign you in. Reconnect with a valid token or GitHub CLI login."
            case .permission: return "GitHub needs access to your backup repository (Whytap-Backup, or Exodia-Backup if you already have one). Give the token Contents read and write access; creating the private repository also requires repository creation permission."
            case .publicRepository: return "Your backup repository is public. Your backups are encrypted, but automatic uploads are paused. Make the repository private, then reconnect."
            case .unavailable, .rateLimited: return "GitHub is unavailable or its request limit was reached. Your local copy is safe; Whytap will retry."
            case .invalidResponse: return "GitHub returned an unexpected response. Reconnect and try again."
            case .incomplete: return "This GitHub backup is incomplete or damaged. Choose another version."
            case .noCLI: return "GitHub CLI was not found. Connect with an access token, or install GitHub CLI and run gh auth login."
            case .noLogin: return "Sign in with gh auth login, or connect with an access token."
            }
        }
    }

    struct Repository: Decodable {
        let name: String
        let isPrivate: Bool
        let permissions: Permissions?
        struct Permissions: Decodable { let push: Bool? }
        enum CodingKeys: String, CodingKey { case name, permissions; case isPrivate = "private" }
    }
    private struct User: Decodable { let login: String }
    private struct Asset: Decodable {
        let id: Int; let name: String; let size: Int64; let state: String
        /// GitHub's "sha256:<hex>" over the stored bytes; absent on older assets.
        let digest: String?
        var sha256: String? {
            guard let digest, digest.hasPrefix("sha256:") else { return nil }
            let hex = digest.dropFirst("sha256:".count).lowercased()
            return hex.count == 64 && hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) ? hex : nil
        }
    }
    private struct Release: Decodable {
        let id: Int
        let draft: Bool
        let body: String?
        let tag_name: String
        let created_at: String
        let assets: [Asset]
    }
    private struct Part: Codable, Equatable { let name: String; let size: Int; let digest: String }
    private struct Index: Codable, Equatable {
        let version: Int
        let snapshotID: UUID
        let byteCount: Int64
        let parts: [Part]
        /// Optional for older archives. Release dates describe GitHub commits
        /// or uploads, not the time the user's snapshot was captured.
        var createdAt: Date?

        func matches(_ other: Self) -> Bool {
            version == other.version && snapshotID == other.snapshotID
                && byteCount == other.byteCount && parts == other.parts
                && (createdAt == nil || createdAt == other.createdAt)
        }
    }

    init(token: String, owner: String, repository: String = GitHubBackupTransport.legacyRepository,
         session: URLSession = GitHubBackupNetwork.session) throws {
        guard Self.validOwner(owner), Self.validToken(token), Self.isBackupRepository(repository) else { throw Failure.authentication }
        self.token = token; self.owner = owner; self.repositoryName = repository; self.session = session
    }

    nonisolated static func isBackupRepository(_ name: String) -> Bool {
        [repository, legacyRepository].contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The repository saved with this Mac's connection.
    nonisolated static func savedRepository(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: repositoryDefaultsKey).flatMap { isBackupRepository($0) ? $0 : nil } ?? legacyRepository
    }

    /// Creating a destination is invoked only by an explicit Connect action.
    static func connect(token: String, session: URLSession = GitHubBackupNetwork.session) async throws -> GitHubBackupTransport {
        guard validToken(token) else { throw Failure.authentication }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try check(response)
        guard let user = try? JSONDecoder().decode(User.self, from: data) else { throw Failure.invalidResponse }
        // An existing Exodia-Backup (or the repository it was renamed to) keeps
        // every earlier backup reachable; only a new user gets Whytap-Backup.
        let legacy = try GitHubBackupTransport(token: token, owner: user.login, repository: legacyRepository, session: session)
        let name = try await legacy.existingRepositoryName() ?? repository
        let transport = try GitHubBackupTransport(token: token, owner: user.login, repository: name, session: session)
        try await transport.ensureRepository()
        return transport
    }

    var destinationName: String { owner + "/" + repositoryName }

    nonisolated static func backupURL(owner: String, repository: String) -> URL? {
        guard validOwner(owner), isBackupRepository(repository) else { return nil }
        return URL(string: "https://github.com/" + owner + "/" + repository + "/releases")
    }

    /// The name GitHub reports for this repository (it follows renames), or
    /// nil when there is none.
    func existingRepositoryName() async throws -> String? {
        let (data, response) = try await session.data(for: request(path: repoPath))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try Self.check(response)
        guard let found = try? JSONDecoder().decode(Repository.self, from: data),
              Self.isBackupRepository(found.name) else { throw Failure.invalidResponse }
        return found.name
    }

    func ensureRepository() async throws {
        let (data, response) = try await session.data(for: request(path: repoPath))
        if (response as? HTTPURLResponse)?.statusCode == 404 {
            _ = try await json(path: "/user/repos", method: "POST", body: [
                "name": repositoryName, "private": true, "auto_init": true,
                "description": "Encrypted Whytap backups. Keep your recovery code in a separate password manager."
            ])
            try await requirePrivateRepository()
        } else {
            try Self.check(response)
            try validateRepository(data)
        }
    }

    func checkConnection() async throws { try await requirePrivateRepository() }

    private func requirePrivateRepository() async throws {
        try validateRepository(try await json(path: repoPath))
    }
    private func validateRepository(_ data: Data) throws {
        guard let repository = try? JSONDecoder().decode(Repository.self, from: data),
              repository.name.lowercased() == repositoryName.lowercased() else { throw Failure.invalidResponse }
        guard repository.isPrivate else { throw Failure.publicRepository }
        if repository.permissions?.push == false { throw Failure.permission }
    }

    /// Upload immutable ciphertext parts into a draft. The authenticated index
    /// is written last; only then is the release published as a complete version.
    /// `onProgress` receives the 1-based part being checked or uploaded and the total.
    func upload(file: URL, summary: ArtifactBackupSummary, key: Data, resumeReleaseID: Int? = nil,
                onDraft: (@Sendable (Int) async throws -> Void)? = nil,
                onProgress: (@Sendable (Int, Int) async -> Void)? = nil) async throws -> Int {
        try await requirePrivateRepository()
        guard key.count == 32 else { throw ConfigBackupError.keyUnavailable }
        let bytes = try Self.fileSize(file)
        let uploadPartSize = try Self.partSize(for: bytes)
        let totalParts = Int((bytes + Int64(uploadPartSize) - 1) / Int64(uploadPartSize))
        let tag = "exodia-backup-" + summary.id.uuidString.lowercased()
        let release: Release
        if let resumeReleaseID {
            guard resumeReleaseID > 0 else { throw Failure.incomplete }
            if let saved = try await savedRelease(id: resumeReleaseID) { release = saved }
            else { release = try await managedRelease(tag: tag) }
        } else {
            release = try await managedRelease(tag: tag)
        }
        guard release.tag_name == tag, release.body == Self.marker else { throw Failure.invalidResponse }
        if let onDraft { try await onDraft(release.id) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var parts: [Part] = []
        while let data = try handle.read(upToCount: uploadPartSize), !data.isEmpty {
            try Task.checkCancellation()
            guard parts.count < Self.maximumParts else { throw ConfigBackupError.tooLarge }
            let name = String(format: "part-%05d.bin", parts.count)
            await onProgress?(parts.count + 1, totalParts)
            let digest = Self.digest(data)
            if try await verifiedExistingAsset(data, digest: digest, name: name, release: release) == nil {
                let asset = try await uploadAsset(data, name: name, releaseID: release.id)
                guard asset.size == data.count, asset.state == "uploaded" else { throw Failure.incomplete }
                // A successful upload response is not proof of durable bytes. Read
                // each new part back before publishing a completed snapshot.
                let returned = try await downloadAsset(asset, maximumBytes: Self.maximumPartBytes)
                guard returned.count == data.count, Self.digest(returned) == digest else { throw Failure.incomplete }
            }
            parts.append(Part(name: name, size: data.count, digest: digest))
        }
        guard parts.reduce(Int64(0), { $0 + Int64($1.size) }) == bytes else { throw Failure.incomplete }
        let index = Index(version: 1, snapshotID: summary.id, byteCount: bytes, parts: parts, createdAt: summary.createdAt)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(index), using: SymmetricKey(data: key),
                                      authenticating: Data(Self.marker.utf8))
        guard let combined = sealed.combined else { throw Failure.incomplete }
        if let existing = release.assets.first(where: { $0.name == "complete.exodia-index" && $0.state == "uploaded" }) {
            let data = try await downloadAsset(existing, maximumBytes: 2_000_000)
            let opened: Data
            do {
                opened = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key),
                                          authenticating: Data(Self.marker.utf8))
            } catch { throw Failure.incomplete }
            guard try JSONDecoder().decode(Index.self, from: opened).matches(index) else { throw Failure.incomplete }
        } else {
            guard release.draft else { throw Failure.incomplete }
            if let starter = release.assets.first(where: { $0.name == "complete.exodia-index" }) {
                _ = try await json(path: repoPath + "/releases/assets/\(starter.id)", method: "DELETE")
            }
            let indexAsset = try await uploadAsset(combined, name: "complete.exodia-index", releaseID: release.id)
            guard try await downloadAsset(indexAsset, maximumBytes: 2_000_000) == combined else { throw Failure.incomplete }
        }
        try await requirePrivateRepository()
        if release.draft {
            _ = try await json(path: repoPath + "/releases/\(release.id)", method: "PATCH", body: ["draft": false])
        }
        return release.id
    }

    func versions(key: Data? = nil) async throws -> [BackupVersion] {
        var versions: [BackupVersion] = []
        // Bounded pagination; older versions remain on GitHub and are never
        // automatically deleted by a second Mac.
        for page in 1...20 {
            let data = try await json(path: repoPath + "/releases?per_page=100&page=\(page)")
            guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { throw Failure.invalidResponse }
            for release in releases where !release.draft && release.body == Self.marker {
                guard let uuid = Self.snapshotID(release.tag_name),
                      release.assets.contains(where: { $0.name == "complete.exodia-index" && $0.state == "uploaded" }) else { continue }
                let date: Date
                if let key {
                    let index: Index
                    do { index = try await authenticatedIndex(release, key: key) }
                    catch ConfigBackupError.cannotUnlock { continue }
                    if let createdAt = index.createdAt { date = createdAt }
                    else { date = try await legacySnapshotDate(index, release: release, key: key) }
                } else { date = Self.date(release.created_at) }
                versions.append(BackupVersion(id: uuid.uuidString, createdAt: date,
                    size: release.assets.filter { $0.name.hasPrefix("part-") }.reduce(0, { $0 + $1.size }),
                    localURL: nil, remoteID: release.id, location: .github))
            }
            if releases.count < 100 { break }
        }
        return versions.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }

    /// Explicitly requested cleanup includes unfinished drafts. It remains
    /// available if the repository became public: that is when deletion matters
    /// most. Never delete the repository, unrelated releases or source history.
    func deleteBackups(except keptID: UUID? = nil) async throws {
        let data = try await json(path: repoPath)
        guard let repository = try? JSONDecoder().decode(Repository.self, from: data),
              repository.name.lowercased() == repositoryName.lowercased() else { throw Failure.invalidResponse }
        if repository.permissions?.push == false { throw Failure.permission }
        let releases = try await managedReleases()
        for release in releases where Self.snapshotID(release.tag_name) != keptID {
            try Task.checkCancellation()
            let path = repoPath + "/releases/\(release.id)"
            let (_, response) = try await session.data(for: request(path: path, method: "DELETE"))
            if (response as? HTTPURLResponse)?.statusCode != 404 { try Self.check(response) }
            let (_, readback) = try await session.data(for: request(path: path))
            guard (readback as? HTTPURLResponse)?.statusCode == 404 else { throw Failure.incomplete }
        }
        // Do not claim success if another Mac uploaded during the operation.
        guard try await managedReleases().allSatisfy({ Self.snapshotID($0.tag_name) == keptID }) else { throw Failure.incomplete }
    }

    private func managedReleases() async throws -> [Release] {
        var result: [Release] = []
        for page in 1...100 {
            let data = try await json(path: repoPath + "/releases?per_page=100&page=\(page)")
            guard let releases = try? JSONDecoder().decode([Release].self, from: data),
                  releases.allSatisfy({ $0.id > 0 }) else { throw Failure.invalidResponse }
            result += releases.filter { $0.body == Self.marker && Self.snapshotID($0.tag_name) != nil }
            if releases.count < 100 { return result }
        }
        // Exhaustion is an error, never a silently incomplete deletion.
        throw Failure.incomplete
    }

    func version(id: UUID) async throws -> BackupVersion {
        let data = try await json(path: repoPath + "/releases/tags/exodia-backup-" + id.uuidString.lowercased())
        guard let release = try? JSONDecoder().decode(Release.self, from: data), !release.draft,
              release.body == Self.marker, Self.snapshotID(release.tag_name) == id,
              release.assets.contains(where: { $0.name == "complete.exodia-index" && $0.state == "uploaded" }) else { throw Failure.incomplete }
        return BackupVersion(id: id.uuidString, createdAt: Self.date(release.created_at),
            size: release.assets.filter { $0.name.hasPrefix("part-") }.reduce(0, { $0 + $1.size }), remoteID: release.id, location: .github)
    }

    func download(version: BackupVersion, to file: URL, key: Data) async throws {
        guard let id = version.remoteID, id > 0, key.count == 32 else { throw Failure.incomplete }
        let releaseData = try await json(path: repoPath + "/releases/\(id)")
        guard let release = try? JSONDecoder().decode(Release.self, from: releaseData), !release.draft,
              release.body == Self.marker, Self.snapshotID(release.tag_name)?.uuidString == version.id else { throw Failure.incomplete }
        let index = try await authenticatedIndex(release, key: key)
        try ConfigBackupFiles.ensurePrivateDirectory(file.deletingLastPathComponent())
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".download-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigBackupError.saveFailed
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        for part in index.parts {
            try Task.checkCancellation()
            let bytes = try await verifiedPart(part, release: release)
            try handle.write(contentsOf: bytes)
        }
        try handle.synchronize(); try handle.close()
        guard rename(temporary.path, file.path) == 0 else { throw ConfigBackupError.saveFailed }
    }

    private func authenticatedIndex(_ release: Release, key: Data) async throws -> Index {
        guard key.count == 32,
              let marker = release.assets.first(where: { $0.name == "complete.exodia-index" && $0.state == "uploaded" }) else {
            throw Failure.incomplete
        }
        let data = try await downloadAsset(marker, maximumBytes: 2_000_000)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key),
                                         authenticating: Data(Self.marker.utf8))
        } catch { throw ConfigBackupError.cannotUnlock }
        guard let index = try? JSONDecoder().decode(Index.self, from: plaintext), index.version == 1,
              index.snapshotID == Self.snapshotID(release.tag_name), !index.parts.isEmpty,
              index.parts.count <= Self.maximumParts, index.byteCount > 0,
              index.parts.allSatisfy({ $0.size > 0 && $0.size <= Self.maximumPartBytes && $0.digest.utf8.count == 64 }),
              index.parts.reduce(Int64(0), { $0 + Int64($1.size) }) == index.byteCount,
              Set(index.parts.map(\.name)).count == index.parts.count,
              index.parts.enumerated().allSatisfy({ $0.element.name == String(format: "part-%05d.bin", $0.offset) }),
              index.createdAt?.timeIntervalSinceReferenceDate.isFinite != false else { throw Failure.incomplete }
        return index
    }

    private func verifiedPart(_ part: Part, release: Release) async throws -> Data {
        guard let asset = release.assets.first(where: { $0.name == part.name && $0.state == "uploaded" }),
              asset.size == part.size else { throw Failure.incomplete }
        let bytes = try await downloadAsset(asset, maximumBytes: Self.maximumPartBytes)
        guard bytes.count == part.size, Self.digest(bytes) == part.digest else { throw Failure.incomplete }
        return bytes
    }

    /// Old indexes lack a timestamp. Authenticate the bounded archive head to
    /// read its manifest; full and delta manifests retain the snapshot date.
    /// Full verification still precedes restore. Temporary bytes stay encrypted.
    private func legacySnapshotDate(_ index: Index, release: Release, key: Data) async throws -> Date {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backup-date-" + UUID().uuidString)
        try ConfigBackupFiles.ensurePrivateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("head.enc")
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigBackupError.saveFailed
        }
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        var received = 0
        for part in index.parts {
            let bytes = try await verifiedPart(part, release: release)
            try writer.write(contentsOf: bytes)
            received += bytes.count
            do {
                let reader = try ArtifactArchiveReader(url: file, archiveKey: key)
                defer { reader.close() }
                let manifest = try ArtifactRestoreTransaction.readManifest(reader)
                guard manifest.id == index.snapshotID else { throw Failure.incomplete }
                return manifest.createdAt
            } catch ArtifactBackupError.truncated {
                guard received < ArtifactBackupManifest.maxBytes + ArtifactArchiveHeader.maxChunkSize + 1_048_576 else {
                    throw Failure.incomplete
                }
            }
        }
        throw Failure.incomplete
    }

    // MARK: HTTP. Only GitHub-owned fixed API origins receive the token.
    private var repoPath: String { "/repos/" + owner + "/" + repositoryName }
    private func request(path: String, method: String = "GET", upload: Bool = false) -> URLRequest {
        var request = URLRequest(url: URL(string: (upload ? "https://uploads.github.com" : "https://api.github.com") + path)!)
        request.httpMethod = method; request.timeoutInterval = 120
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }
    private func json(path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        try Task.checkCancellation()
        var req = request(path: path, method: method)
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: req)
        try Self.check(response)
        guard data.count <= 8_000_000 else { throw Failure.invalidResponse }
        return data
    }
    /// The part's existing asset when it already holds these bytes; nil when the
    /// caller must upload it, after removing a mismatched asset from the draft.
    private func verifiedExistingAsset(_ data: Data, digest: String, name: String, release: Release) async throws -> Asset? {
        guard let existing = release.assets.first(where: { $0.name == name }) else {
            guard release.draft else { throw Failure.incomplete }
            return nil
        }
        if existing.state == "uploaded", existing.size == data.count, try await holds(existing, data: data, digest: digest) { return existing }
        // GitHub documents empty starter assets after an upstream failure.
        // Only this unfinished draft's reserved asset may be replaced.
        guard release.draft, !release.assets.contains(where: { $0.name == "complete.exodia-index" && $0.state == "uploaded" }) else { throw Failure.incomplete }
        _ = try await json(path: repoPath + "/releases/assets/\(existing.id)", method: "DELETE")
        return nil
    }
    /// GitHub reports the SHA-256 it computed for the stored asset; a match proves
    /// those bytes without downloading them, so a restart costs metadata only.
    /// Older assets without a usable digest keep the download comparison.
    // WHY: .project-docs/decisions/2026-10-21-backup-resume-digest.md
    private func holds(_ asset: Asset, data: Data, digest: String) async throws -> Bool {
        if let stored = asset.sha256 { return stored == digest }
        return try await downloadAsset(asset, maximumBytes: Self.maximumPartBytes) == data
    }
    /// A saved draft ID is only a resume hint. `upload` has just verified the
    /// repository as private and writable, so a 404 for this one release means
    /// the draft no longer exists (for example, deleted on GitHub): the caller
    /// falls back to the snapshot's own tag instead of treating it as a
    /// permission failure that reconnecting can never fix. Every other status
    /// keeps its normal meaning.
    private func savedRelease(id: Int) async throws -> Release? {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request(path: repoPath + "/releases/\(id)"))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try Self.check(response)
        guard data.count <= 8_000_000, let existing = try? JSONDecoder().decode(Release.self, from: data) else {
            throw Failure.invalidResponse
        }
        return existing
    }

    /// The snapshot's published release, its existing draft, or a new draft.
    private func managedRelease(tag: String) async throws -> Release {
        let lookup = try await session.data(for: request(path: repoPath + "/releases/tags/" + tag))
        if (lookup.1 as? HTTPURLResponse)?.statusCode == 404 {
            // The tag endpoint returns published releases only. Drafts
            // are discovered through the authenticated release listing.
            if let existing = try await findDraft(tag: tag) { return existing }
            let data = try await json(path: repoPath + "/releases", method: "POST", body: [
                "tag_name": tag, "name": "Encrypted backup", "body": Self.marker,
                "draft": true, "prerelease": true, "make_latest": "false"
            ])
            guard let created = try? JSONDecoder().decode(Release.self, from: data) else { throw Failure.invalidResponse }
            return created
        }
        try Self.check(lookup.1)
        guard let existing = try? JSONDecoder().decode(Release.self, from: lookup.0) else { throw Failure.invalidResponse }
        return existing
    }

    private func findDraft(tag: String) async throws -> Release? {
        for page in 1...20 {
            let data = try await json(path: repoPath + "/releases?per_page=100&page=\(page)")
            guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { throw Failure.invalidResponse }
            if let draft = releases.first(where: { $0.tag_name == tag && $0.draft && $0.body == Self.marker }) { return draft }
            if releases.count < 100 { return nil }
        }
        return nil
    }
    static func partSize(for bytes: Int64) throws -> Int {
        guard bytes > 0, bytes <= Int64(maximumPartBytes) * Int64(maximumParts) else { throw ConfigBackupError.tooLarge }
        let required = (bytes + Int64(maximumParts - 1)) / Int64(maximumParts)
        let mib: Int64 = 1_048_576
        return max(partBytes, Int(((required + mib - 1) / mib) * mib))
    }
    private func uploadAsset(_ data: Data, name: String, releaseID: Int) async throws -> Asset {
        var req = request(path: repoPath + "/releases/\(releaseID)/assets?name=" + name, method: "POST", upload: true)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await session.upload(for: req, from: data)
        try Self.check(response)
        guard let asset = try? JSONDecoder().decode(Asset.self, from: responseData), asset.name == name else { throw Failure.invalidResponse }
        return asset
    }
    private func downloadAsset(_ asset: Asset, maximumBytes: Int) async throws -> Data {
        guard asset.id > 0, asset.state == "uploaded", asset.size > 0, asset.size <= maximumBytes else { throw Failure.incomplete }
        var req = request(path: repoPath + "/releases/assets/\(asset.id)")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (url, response) = try await session.download(for: req)
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.check(response)
        guard try Self.fileSize(url) == asset.size else { throw Failure.incomplete }
        return try Data(contentsOf: url)
    }
    private static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        switch response.statusCode {
        case 200..<300: return
        case 401: throw Failure.authentication
        case 403, 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            let exhausted = response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init)
            if retry != nil || exhausted {
                let now = Date()
                var until = now.addingTimeInterval(60)
                if let retry, retry.isFinite, retry >= 0 { until = max(until, now.addingTimeInterval(retry)) }
                if exhausted, let reset, reset.isFinite { until = max(until, Date(timeIntervalSince1970: reset)) }
                throw Failure.rateLimited(until: until)
            }
            if response.statusCode == 403 { throw Failure.permission }
            throw Failure.unavailable
        case 404: throw Failure.permission
        case 500...599: throw Failure.unavailable
        default: throw Failure.invalidResponse
        }
    }
    nonisolated private static func validOwner(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", options: .regularExpression) != nil
    }
    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 2048 && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let count = values.fileSize else { throw ConfigBackupError.unsafePath }
        return Int64(count)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func snapshotID(_ tag: String) -> UUID? {
        let prefix = "exodia-backup-"
        guard tag.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(tag.dropFirst(prefix.count)))
    }
    private static func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string) ?? .distantPast }
}

// MARK: Settings sync file
// One small encrypted file in the same private repository, read and written
// through the Contents API. The blob SHA makes every write conditional, so two
// Macs never overwrite each other's change: the loser re-reads and merges.
// WHY: .project-docs/decisions/2026-11-20-settings-sync.md
extension GitHubBackupTransport: SettingsSyncRemote {
    private struct ContentsFile: Decodable { let sha: String; let content: String?; let encoding: String?; let size: Int }
    private struct ContentsWrite: Decodable { struct Content: Decodable { let sha: String }; let content: Content }

    func fetchSyncFile(path: String, etag: String?) async throws -> SettingsSyncFetch {
        try Task.checkCancellation()
        var req = request(path: repoPath + "/contents/" + path)
        req.timeoutInterval = 30
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 304 { return .notModified }
        if status == 404 { return .missing }
        try Self.check(response)
        guard data.count <= 4_000_000, let file = try? JSONDecoder().decode(ContentsFile.self, from: data),
              file.encoding == "base64", let content = file.content,
              let bytes = Data(base64Encoded: content, options: .ignoreUnknownCharacters), bytes.count == file.size
        else { throw Failure.invalidResponse }
        return .found(data: bytes, sha: file.sha, etag: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
    }

    func putSyncFile(path: String, data: Data, sha: String?) async throws -> String {
        try Task.checkCancellation()
        // Ciphertext still never goes to a repository that became public.
        try await requirePrivateRepository()
        var body: [String: Any] = ["message": "Whytap settings sync", "content": data.base64EncodedString()]
        if let sha { body["sha"] = sha }
        var req = request(path: repoPath + "/contents/" + path, method: "PUT")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await session.data(for: req)
        // 409: the file changed since it was read. 422: it was created meanwhile.
        if let status = (response as? HTTPURLResponse)?.statusCode, status == 409 || status == 422 {
            throw SettingsSyncFailure.conflict
        }
        try Self.check(response)
        guard let written = try? JSONDecoder().decode(ContentsWrite.self, from: responseData) else { throw Failure.invalidResponse }
        return written.content.sha
    }
}

/// Uses an explicit existing GitHub CLI login only when the user chooses it.
/// The credential is returned over a pipe and later stored in the local Keychain.
enum BackupGitHubLogin {
    static func existingToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let paths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
                    guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                        throw GitHubBackupTransport.Failure.noCLI
                    }
                    let process = Process(); let output = Pipe()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = ["auth", "token", "--hostname", "github.com"]
                    process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "GH_PROMPT_DISABLED": "1"]
                    process.standardOutput = output; process.standardError = FileHandle.nullDevice
                    try process.run()
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit(); timeout.cancel()
                    guard process.terminationStatus == 0, data.count <= 4096,
                          let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                        throw GitHubBackupTransport.Failure.noLogin
                    }
                    continuation.resume(returning: token)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Tokens are never cached, sent to a redirected object-storage host or
/// downgraded to HTTP. GitHub serves private release assets through signed
/// redirects; those downloads do not need the API credential.
enum GitHubBackupNetwork {
    private static let delegate = RedirectPolicy()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()
    static func redirectedRequest(_ request: URLRequest, from response: HTTPURLResponse) -> URLRequest? {
        guard let url = request.url, url.scheme == "https", let host = url.host?.lowercased(),
              host == "api.github.com" || host == "uploads.github.com" || host.hasSuffix(".githubusercontent.com") else { return nil }
        var safe = request
        if host != response.url?.host?.lowercased() {
            safe.setValue(nil, forHTTPHeaderField: "Authorization")
            safe.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return safe
    }
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(GitHubBackupNetwork.redirectedRequest(request, from: response))
        }
    }
}
